// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Gateway failover coverage for an external-PostgreSQL HA deployment.
//!
//! This test deletes a gateway pod, so it runs only with
//! `OPENSHELL_ODH_HA_FAILOVER=1`. The test keeps the client's local endpoint
//! stable while switching its pod port-forward from the deleted replica to a
//! surviving replica, then verifies that the original client reconnects.

use std::net::TcpListener;
use std::panic::AssertUnwindSafe;
use std::process::{Output, Stdio};
use std::time::Duration;

use base64::Engine as _;
use futures_util::FutureExt as _;
use openshell_e2e::harness::binary::openshell_cmd;
use openshell_e2e::harness::sandbox::E2E_WORKLOAD_IMAGE;
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::process::{Child, ChildStdout};
use tokio::time::{Instant, sleep, timeout};

use crate::odh_harness::oc::{
    gateway_namespace, is_openshift, oc_command, oc_json, oc_with_timeout, pod_is_ready, release,
    sandbox_namespace,
};
use crate::odh_harness::sandbox::sandbox_pod_selector;

// constants
const ENABLE_ENV: &str = "OPENSHELL_ODH_HA_FAILOVER";
const GATEWAY_SELECTOR_ENV: &str = "OPENSHELL_ODH_HA_GATEWAY_SELECTOR";
const GATEWAY_NAME_ENV: &str = "OPENSHELL_ODH_HA_GATEWAY_NAME";
const GATEWAY_PORT: u16 = 8080;
const POD_READY_TIMEOUT: Duration = Duration::from_secs(120); // sets timeouts
const SESSION_TIMEOUT: Duration = Duration::from_secs(60);
const CREATE_TIMEOUT: Duration = Duration::from_secs(300);
const CREATE_RECOVERY_TIMEOUT: Duration = Duration::from_secs(120);
const CLI_COMMAND_TIMEOUT: Duration = Duration::from_secs(120);
const SANDBOX_DELETION_TIMEOUT: Duration = Duration::from_secs(300);
const SESSION_START_ATTEMPTS: usize = 3;
// The CLI only opens its reconnect window after an attachment has survived
// two seconds. Keep a one-second margin so pod deletion cannot race that
// threshold on a slow runner.
const SESSION_ESTABLISHED_DURATION: Duration = Duration::from_secs(3);
const POLL_INTERVAL: Duration = Duration::from_secs(2);
const SENTINEL: &str = "odh-ha-workspace-sentinel"; // marker written to disk to test file persistence
const OUTPUT_MARKER: &str = "odh-ha-session-alive"; // prefix for a process-specific heartbeat used to detect workload restarts

struct GatewayPod {
    name: String,
    ready: bool,
} // tracks pod readiness

struct ActiveSession {
    child: Child,
    stdout: tokio::io::Lines<BufReader<ChildStdout>>,
} // handles running terminal command streams

struct PodPortForward {
    endpoint: String,
    port: u16,
    child: Child,
} // tracks a local tunnel directly to a single pod

struct SessionMarker {
    process_id: String,
    emitted_at: u64,
}

struct ManagedSandbox {
    name: String,
    cleaned_up: bool,
}

impl ManagedSandbox {
    fn new(name: String) -> Self {
        Self {
            name,
            cleaned_up: false,
        }
    }

    async fn cleanup(&mut self, endpoint: &str) -> Result<(), String> {
        if self.cleaned_up {
            return Ok(());
        }

        let mut command = direct_gateway_command(endpoint);
        command
            .args(["sandbox", "delete", &self.name])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let output = timeout(CLI_COMMAND_TIMEOUT, command.output())
            .await
            .map_err(|_| {
                format!(
                    "delete sandbox {} through {endpoint} timed out after {CLI_COMMAND_TIMEOUT:?}",
                    self.name
                )
            })?
            .map_err(|error| {
                format!(
                    "failed to delete sandbox {} through {endpoint}: {error}",
                    self.name
                )
            })?;
        if !output.status.success() {
            return Err(format!(
                "delete sandbox {} through {endpoint} failed with exit {:?}",
                self.name,
                output.status.code(),
            ));
        }

        self.cleaned_up = true;
        Ok(())
    }
}

fn gateway_selector(release: &str) -> String {
    std::env::var(GATEWAY_SELECTOR_ENV).unwrap_or_else(|_| {
        format!("app.kubernetes.io/name=openshell,app.kubernetes.io/instance={release}")
    })
}

async fn gateway_pods(namespace: &str, selector: &str) -> Vec<GatewayPod> {
    let pods = oc_json(&["get", "pods", "-n", namespace, "-l", selector, "-o", "json"]).await;
    pods["items"]
        .as_array()
        .expect("gateway pod list should contain items")
        .iter()
        .filter_map(|pod| {
            pod["metadata"]["name"].as_str().map(|name| GatewayPod {
                name: name.to_string(),
                ready: pod_is_ready(pod),
            })
        })
        .collect()
} // uses pod_is_ready() on the array of gateway pods

async fn wait_for_gateway_pod_ready(namespace: &str, selector: &str, pod_name: &str) {
    let result = timeout(POD_READY_TIMEOUT, async {
        loop {
            if gateway_pods(namespace, selector)
                .await
                .iter()
                .any(|pod| pod.name == pod_name && pod.ready)
            {
                return;
            }
            sleep(POLL_INTERVAL).await;
        }
    })
    .await;
    assert!(
        result.is_ok(),
        "gateway pod {pod_name} did not become Ready within {POD_READY_TIMEOUT:?}"
    );
} // continuously polls OpenShift until a specific pre-existing gateway is ready

fn direct_gateway_command(endpoint: &str) -> tokio::process::Command {
    let gateway_name = std::env::var("OPENSHELL_GATEWAY")
        .or_else(|_| std::env::var(GATEWAY_NAME_ENV))
        .unwrap_or_else(|_| {
            panic!(
                "set OPENSHELL_GATEWAY or {GATEWAY_NAME_ENV} to the configured mTLS gateway name"
            )
        });
    let mut command = openshell_cmd();
    // The port-forward reaches the gateway directly, so use TLS rather than
    // plaintext HTTP. Keep the configured gateway name so the CLI finds its
    // mTLS client certificate instead of looking under a port-forward URL.
    command
        .args(["--gateway", &gateway_name])
        .arg("--gateway-endpoint")
        .arg(endpoint);
    command
}

async fn assert_ha_deployment(namespace: &str, selector: &str) {
    let deployments = oc_json(&[
        "get",
        "deployments",
        "-n",
        namespace,
        "-l",
        selector,
        "-o",
        "json",
    ])
    .await;
    let items = deployments["items"]
        .as_array()
        .expect("gateway deployment list should contain items");
    assert_eq!(
        items.len(),
        1,
        "HA test requires exactly one gateway Deployment selected by '{selector}'"
    );
    let deployment = &items[0];
    assert!(
        deployment["spec"]["replicas"]
            .as_u64()
            .is_some_and(|n| n >= 2),
        "HA test requires a gateway Deployment configured for at least two replicas"
    );
    let containers = deployment["spec"]["template"]["spec"]["containers"]
        .as_array()
        .expect("gateway Deployment should contain containers");
    let secret_name = containers
        .iter()
        .find_map(|container| {
            container["env"].as_array().and_then(|env| {
                env.iter().find_map(|entry| {
                    (entry["name"].as_str() == Some("OPENSHELL_DB_URL")
                        && entry["valueFrom"]["secretKeyRef"]["key"].as_str() == Some("uri"))
                    .then(|| entry["valueFrom"]["secretKeyRef"]["name"].as_str())
                    .flatten()
                    .filter(|name| !name.is_empty())
                })
            })
        })
        .expect("HA test requires OPENSHELL_DB_URL to reference a nonempty uri key in a Secret");
    let secret = oc_json(&["get", "secret", secret_name, "-n", namespace, "-o", "json"]).await;
    let encoded_url = secret["data"]["uri"]
        .as_str()
        .expect("HA test requires the referenced Secret to contain data.uri");
    let url = base64::engine::general_purpose::STANDARD
        .decode(encoded_url)
        .expect("HA test requires the referenced Secret data.uri to be valid base64");
    let url = std::str::from_utf8(&url)
        .expect("HA test requires the referenced Secret data.uri to be valid UTF-8");
    assert!(
        url.starts_with("postgres://") || url.starts_with("postgresql://"),
        "HA test requires the referenced Secret data.uri to contain a PostgreSQL URL"
    );
}

fn reserve_loopback_port() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").expect("reserve a loopback port");
    listener.local_addr().expect("read reserved port").port()
}

async fn port_forward_gateway_pod(namespace: &str, pod: &str, port: u16) -> PodPortForward {
    let target = format!("{port}:{GATEWAY_PORT}");
    let mut command = oc_command();
    command
        .args([
            "port-forward",
            "-n",
            namespace,
            &format!("pod/{pod}"),
            &target,
            "--address=127.0.0.1",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = command.spawn().expect("start gateway pod port-forward");
    let result = timeout(SESSION_TIMEOUT, async {
        loop {
            if tokio::net::TcpStream::connect(("127.0.0.1", port))
                .await
                .is_ok()
            {
                return;
            }
            if let Some(status) = child.try_wait().expect("poll gateway pod port-forward") {
                panic!("gateway pod port-forward exited before becoming ready: {status}");
            }
            sleep(POLL_INTERVAL).await;
        }
    })
    .await;
    assert!(
        result.is_ok(),
        "gateway pod port-forward did not become reachable within {SESSION_TIMEOUT:?}"
    );
    PodPortForward {
        // The test deployment includes localhost in the server certificate
        // SANs. `localhost` therefore keeps certificate validation intact
        // while the port-forward still targets exactly one gateway pod.
        endpoint: format!("https://localhost:{port}"),
        port,
        child,
    }
} // bypasses the default load balancer and targets one gateway pod

async fn stop_port_forward(forward: &mut PodPortForward) {
    let _ = forward.child.kill().await;
    let _ = forward.child.wait().await;
}

async fn wait_for_created_sandbox(name: &str, endpoint: &str) -> Result<(), String> {
    timeout(CREATE_RECOVERY_TIMEOUT, async {
        loop {
            let mut command = direct_gateway_command(endpoint);
            command
                .args(["sandbox", "get", name, "--output", "json"])
                .stdout(Stdio::piped())
                .stderr(Stdio::piped());
            let output = command
                .output()
                .await
                .map_err(|error| format!("failed to check sandbox {name} after create: {error}"))?;
            if output.status.success() {
                let sandbox: Value = serde_json::from_slice(&output.stdout).map_err(|error| {
                    format!("sandbox get {name} returned invalid JSON after create: {error}")
                })?;
                match sandbox["phase"].as_str() {
                    Some("Ready") => return Ok(()),
                    Some("Error") => {
                        return Err(format!(
                            "sandbox {name} entered Error after the create connection dropped"
                        ));
                    }
                    _ => {}
                }
            }
            sleep(POLL_INTERVAL).await;
        }
    })
    .await
    .map_err(|_| {
        format!("sandbox {name} did not become Ready within {CREATE_RECOVERY_TIMEOUT:?}")
    })?
}

async fn create_on_initial_gateway(endpoint: &str, script: &str) -> ManagedSandbox {
    // Six random hex characters, together with the hexadecimal process ID,
    // keep this below the 19-character sandbox-name limit while separating
    // independent CI runs that happen to reuse a process ID.
    let name = format!(
        "ha-{:x}-{:06x}",
        std::process::id(),
        rand::random::<u32>() & 0x00ff_ffff
    );
    let mut command = direct_gateway_command(endpoint);
    // A failed create may still leave a retained sandbox behind. Register its
    // cleanup before running the CLI so failure paths attempt to remove it.
    let mut sandbox = ManagedSandbox::new(name.clone());
    command
        .args([
            "sandbox",
            "create",
            "--detach",
            "--name",
            &name,
            "--from",
            E2E_WORKLOAD_IMAGE,
            "--",
        ])
        .args(["sh", "-lc", script])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = command.spawn().expect("spawn sandbox create");
    let mut stdout = child
        .stdout
        .take()
        .expect("sandbox create stdout must be piped");
    let mut stderr = child
        .stderr
        .take()
        .expect("sandbox create stderr must be piped");
    let stdout_reader = tokio::spawn(async move {
        let mut output = Vec::new();
        stdout.read_to_end(&mut output).await.map(|_| output)
    });
    let stderr_reader = tokio::spawn(async move {
        let mut output = Vec::new();
        stderr.read_to_end(&mut output).await.map(|_| output)
    });
    let status = match timeout(CREATE_TIMEOUT, child.wait()).await {
        Ok(Ok(status)) => status,
        Ok(Err(error)) => {
            let _ = stdout_reader.await;
            let _ = stderr_reader.await;
            if let Err(cleanup_error) = sandbox.cleanup(endpoint).await {
                eprintln!("{cleanup_error}");
            }
            panic!("failed to run sandbox create through the initial gateway: {error}");
        }
        Err(_) => {
            // Retain the child handle through timeout so it is explicitly
            // killed and reaped before cleanup can race a still-running CLI.
            let _ = child.kill().await;
            let _ = child.wait().await;
            let _ = stdout_reader.await;
            let _ = stderr_reader.await;
            if let Err(cleanup_error) = sandbox.cleanup(endpoint).await {
                eprintln!("{cleanup_error}");
            }
            panic!("sandbox create timed out after {CREATE_TIMEOUT:?}; failover was not exercised");
        }
    };
    let output = Output {
        status,
        stdout: stdout_reader
            .await
            .expect("sandbox create stdout reader should not panic")
            .expect("read sandbox create stdout"),
        stderr: stderr_reader
            .await
            .expect("sandbox create stderr reader should not panic")
            .expect("read sandbox create stderr"),
    };
    if !output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stdout.contains(&format!("Created sandbox: {name}"))
            && stderr.contains("peer closed connection without sending TLS close_notify")
        {
            match wait_for_created_sandbox(&name, endpoint).await {
                Ok(()) => {
                    eprintln!(
                        "create watch through pod port-forward disconnected; sandbox {name} became Ready through the initial gateway pod"
                    );
                    return sandbox;
                }
                Err(error) => {
                    if let Err(cleanup_error) = sandbox.cleanup(endpoint).await {
                        eprintln!("{cleanup_error}");
                    }
                    panic!("sandbox create through the initial gateway failed to recover: {error}");
                }
            }
        }
        if let Err(cleanup_error) = sandbox.cleanup(endpoint).await {
            eprintln!("{cleanup_error}");
        }
        panic!(
            "create sandbox through initial gateway failed with exit {:?}",
            output.status.code()
        );
    }
    sandbox
} // create a sandbox via replica-0 direct endpoint, execute a background script that writes sentinel text to /sandbox/.odh-ha-sentinel
// and enters an infinite loop printing OUTPUT_MARKER every second

async fn start_session(sandbox_name: &str, gateway_endpoint: Option<&str>) -> ActiveSession {
    let mut command = gateway_endpoint.map_or_else(openshell_cmd, direct_gateway_command);
    command
        .args(["sandbox", "connect", sandbox_name])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = command.spawn().expect("spawn sandbox connect");
    let stdout = child
        .stdout
        .take()
        .expect("sandbox connect stdout must be piped");
    ActiveSession {
        child,
        stdout: BufReader::new(stdout).lines(),
    }
} // opens a streaming terminal session (openshell sandbox connect)

async fn exec_on_gateway(
    endpoint: &str,
    sandbox_name: &str,
    argv: &[&str],
) -> Result<String, String> {
    let mut command = direct_gateway_command(endpoint);
    command
        .args(["sandbox", "exec", "--name", sandbox_name, "--no-tty", "--"])
        .args(argv)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let output = timeout(CLI_COMMAND_TIMEOUT, command.output())
        .await
        .map_err(|_| {
            format!("sandbox exec through {endpoint} timed out after {CLI_COMMAND_TIMEOUT:?}")
        })?
        .map_err(|error| format!("failed to run sandbox exec through {endpoint}: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "sandbox exec through {endpoint} failed with exit {:?}",
            output.status.code()
        ));
    }
    String::from_utf8(output.stdout)
        .map_err(|error| format!("sandbox exec through {endpoint} returned invalid UTF-8: {error}"))
}

fn session_marker(line: &str) -> Option<SessionMarker> {
    let (prefix_and_process_id, emitted_at) = line.rsplit_once(':')?;
    let process_id = prefix_and_process_id.strip_prefix(&format!("{OUTPUT_MARKER}:"))?;
    Some(SessionMarker {
        process_id: process_id.to_string(),
        emitted_at: emitted_at.parse().ok()?,
    })
}

async fn session_marker_after(
    session: &mut ActiveSession,
    strictly_after: Option<u64>,
) -> Result<SessionMarker, String> {
    timeout(SESSION_TIMEOUT, async {
        loop {
            let line = session
                .stdout
                .next_line()
                .await
                .map_err(|error| format!("cannot read sandbox connect output: {error}"))?
                .ok_or_else(|| {
                    "sandbox connect exited before receiving session output".to_string()
                })?;
            if let Some(marker) = session_marker(&line)
                && strictly_after.is_none_or(|minimum| marker.emitted_at > minimum)
            {
                return Ok(marker);
            }
        }
    })
    .await
    .map_err(|_| format!("did not receive '{OUTPUT_MARKER}' within {SESSION_TIMEOUT:?}"))?
} // returns a heartbeat emitted after the requested time, excluding buffered output

async fn session_marker_after_elapsed(
    session: &mut ActiveSession,
    minimum_elapsed: Instant,
) -> Result<SessionMarker, String> {
    timeout(SESSION_TIMEOUT, async {
        loop {
            let line = session
                .stdout
                .next_line()
                .await
                .map_err(|error| format!("cannot read sandbox connect output: {error}"))?
                .ok_or_else(|| {
                    "sandbox connect exited before receiving session output".to_string()
                })?;
            if let Some(marker) = session_marker(&line)
                && Instant::now() > minimum_elapsed
            {
                return Ok(marker);
            }
        }
    })
    .await
    .map_err(|_| format!("did not receive '{OUTPUT_MARKER}' within {SESSION_TIMEOUT:?}"))?
}

async fn start_initial_session(
    namespace: &str,
    initial_pod: &str,
    forward: &mut PodPortForward,
    sandbox_name: &str,
) -> (ActiveSession, SessionMarker) {
    let mut failures = Vec::new();
    for attempt in 1..=SESSION_START_ATTEMPTS {
        let mut session = start_session(sandbox_name, Some(&forward.endpoint)).await;
        match session_marker_after(&mut session, None).await {
            Ok(_) => match session_marker_after_elapsed(
                &mut session,
                Instant::now() + SESSION_ESTABLISHED_DURATION,
            )
            .await
            {
                Ok(marker) => return (session, marker),
                Err(error) => {
                    failures.push(format!(
                        "attempt {attempt}: session did not remain attached for longer than {SESSION_ESTABLISHED_DURATION:?}: {error}"
                    ));
                    stop_session(&mut session).await;
                    if attempt < SESSION_START_ATTEMPTS {
                        stop_port_forward(forward).await;
                        *forward =
                            port_forward_gateway_pod(namespace, initial_pod, forward.port).await;
                    }
                }
            },
            Err(error) => {
                failures.push(format!("attempt {attempt}: {error}"));
                stop_session(&mut session).await;
                if attempt < SESSION_START_ATTEMPTS {
                    // `oc port-forward` can accept TCP connections while its
                    // SSH stream is stalled. Recreate the tunnel before
                    // retrying so this remains a transport preflight, before
                    // the destructive failover action.
                    stop_port_forward(forward).await;
                    *forward = port_forward_gateway_pod(namespace, initial_pod, forward.port).await;
                }
            }
        }
    }
    panic!(
        "initial session through pod port-forward could not produce a heartbeat after {SESSION_START_ATTEMPTS} attempts; failover was not exercised:\n{}",
        failures.join("\n")
    );
}

async fn stop_session(session: &mut ActiveSession) {
    let _ = session.child.kill().await;
    let _ = session.child.wait().await;
}

async fn assert_sandbox_workload_is_live(namespace: &str, sandbox_name: &str) -> String {
    let selector = sandbox_pod_selector(namespace, sandbox_name)
        .await
        .expect("sandbox CR should retain its workload selector after failover");
    let pods = oc_json(&[
        "get", "pods", "-n", namespace, "-l", &selector, "-o", "json",
    ])
    .await;
    let items = pods["items"]
        .as_array()
        .expect("sandbox pod list should contain items");
    assert!(
        !items.is_empty() && items.iter().all(pod_is_ready),
        "sandbox workload is orphaned or not ready after gateway failover: {:?}",
        items
            .iter()
            .map(|pod| (
                pod["metadata"]["name"].as_str().unwrap_or("<unnamed>"),
                pod_is_ready(pod),
            ))
            .collect::<Vec<_>>(),
    );
    selector
} // checks k8s to make sure the underlying container running the workload didn't crash or get orphaned during failover

async fn assert_sandbox_deleted(endpoint: &str, namespace: &str, name: &str, pod_selector: &str) {
    let cr_selector = format!("openshell.ai/sandbox-name={name}");
    let mut last_observation = None;
    let result = timeout(SANDBOX_DELETION_TIMEOUT, async {
        loop {
            let mut command = direct_gateway_command(endpoint);
            command.args(["sandbox", "list", "--names"]);
            let output = command
                .output()
                .await
                .expect("list sandboxes after cleanup");
            assert!(
                output.status.success(),
                "could not verify sandbox deletion through the gateway"
            );
            let still_listed = String::from_utf8_lossy(&output.stdout)
                .lines()
                .any(|line| line.trim() == name);
            let crs = oc_json(&[
                "get",
                "sandboxes.agents.x-k8s.io",
                "-n",
                namespace,
                "-l",
                &cr_selector,
                "-o",
                "json",
            ])
            .await;
            let pods = oc_json(&[
                "get",
                "pods",
                "-n",
                namespace,
                "-l",
                pod_selector,
                "-o",
                "json",
            ])
            .await;
            let cr_count = crs["items"]
                .as_array()
                .expect("Sandbox CR list items")
                .len();
            let pod_count = pods["items"]
                .as_array()
                .expect("sandbox pod list items")
                .len();
            last_observation = Some(format!(
                "sandbox listed: {still_listed}, custom resources: {cr_count}, workload pods: {pod_count}"
            ));
            if !still_listed && cr_count == 0 && pod_count == 0 {
                return;
            }
            sleep(POLL_INTERVAL).await;
        }
    })
    .await;
    assert!(
        result.is_ok(),
        "sandbox {name}, its custom resource, or its pod remained after cleanup for {SANDBOX_DELETION_TIMEOUT:?}; last observation: {}",
        last_observation.unwrap_or_else(|| "no deletion state observed".to_string())
    );
}

async fn wait_for_gateway_pod_deleted(namespace: &str, selector: &str, pod_name: &str) {
    let result = timeout(POD_READY_TIMEOUT, async {
        loop {
            if gateway_pods(namespace, selector)
                .await
                .iter()
                .all(|pod| pod.name != pod_name)
            {
                return;
            }
            sleep(POLL_INTERVAL).await;
        }
    })
    .await;
    assert!(
        result.is_ok(),
        "gateway pod {pod_name} was not deleted within {POD_READY_TIMEOUT:?}"
    );
}

async fn run_failover_scenario(
    gateway_namespace: &str,
    sandbox_namespace: &str,
    selector: &str,
    initial_pod: &str,
    surviving_pod: &str,
    initial_forward: &mut PodPortForward,
    sandbox: &ManagedSandbox,
) -> String {
    let (mut initial_session, initial_marker) = start_initial_session(
        gateway_namespace,
        initial_pod,
        initial_forward,
        &sandbox.name,
    )
    .await;

    // Ensure the surviving replica is ready before dropping the client's
    // transport, then submit deletion without spending its reconnect window
    // waiting for Kubernetes to finish terminating the initial pod.
    wait_for_gateway_pod_ready(gateway_namespace, selector, surviving_pod).await;
    let deleted = oc_with_timeout(
        &[
            "delete",
            "pod",
            initial_pod,
            "-n",
            gateway_namespace,
            "--wait=false",
            "--timeout=150s",
        ],
        None,
        Duration::from_secs(180),
    )
    .await;
    assert!(
        deleted.success,
        "delete gateway pod {initial_pod} failed ({})",
        deleted.status_summary()
    );

    // Keep the endpoint stable while replacing its direct backend. This lets
    // the original client exercise its bounded reconnect behavior.
    stop_port_forward(initial_forward).await;
    let mut reconnect_forward =
        port_forward_gateway_pod(gateway_namespace, surviving_pod, initial_forward.port).await;
    // Read the baseline from the sandbox clock. Heartbeat timestamps use the
    // same clock, so buffered pre-failover lines cannot satisfy the filter.
    let reconnect_started_at: u64 =
        exec_on_gateway(&reconnect_forward.endpoint, &sandbox.name, &["date", "+%s"])
            .await
            .expect("read sandbox clock after failover")
            .trim()
            .parse()
            .expect("sandbox date +%s should be an integer");
    let reconnected_marker = session_marker_after(&mut initial_session, Some(reconnect_started_at))
        .await
        .unwrap_or_else(|error| {
            panic!("session did not reconnect through the surviving gateway pod: {error}")
        });
    wait_for_gateway_pod_deleted(gateway_namespace, selector, initial_pod).await;
    assert!(
        reconnected_marker.process_id == initial_marker.process_id,
        "sandbox workload process changed while the original client reconnected after gateway failover"
    );
    stop_session(&mut initial_session).await;

    let sentinel = exec_on_gateway(
        &reconnect_forward.endpoint,
        &sandbox.name,
        &["cat", "/sandbox/.odh-ha-sentinel"],
    )
    .await
    .expect("sandbox should remain executable after gateway failover");
    assert!(
        sentinel.contains(SENTINEL),
        "workspace sentinel was lost after gateway failover: {sentinel}"
    );
    stop_port_forward(&mut reconnect_forward).await;
    assert_sandbox_workload_is_live(sandbox_namespace, &sandbox.name).await
}

#[tokio::test]
async fn gateway_pod_failover_preserves_sandbox_session_and_workspace() {
    // preflight checks
    if std::env::var(ENABLE_ENV).as_deref() != Ok("1") {
        eprintln!("skipping destructive HA failover test; set {ENABLE_ENV}=1 to enable it");
        return;
    }
    if !is_openshift().await.unwrap_or_else(|error| {
        panic!("cannot determine whether the active cluster is OpenShift: {error}")
    }) {
        eprintln!("skipping HA failover test; the active cluster is not OpenShift");
        return;
    }

    // replica discovery
    let gateway_namespace = gateway_namespace();
    let sandbox_namespace = sandbox_namespace();
    let release = release();
    let selector = gateway_selector(&release);
    assert_ha_deployment(&gateway_namespace, &selector).await;
    let pods = gateway_pods(&gateway_namespace, &selector).await; // scan for running gateways
    assert!(
        pods.len() >= 2 && pods.iter().filter(|pod| pod.ready).count() >= 2,
        "HA test requires two ready gateway pods selected by '{selector}', found: {:?}",
        pods.iter()
            .map(|pod| (&pod.name, pod.ready))
            .collect::<Vec<_>>(),
    ); // asserts at least 2 ready replicas exist
    let initial_pod = pods
        .iter()
        .find(|pod| pod.ready)
        .expect("one ready gateway pod")
        .name
        .clone(); // pick an initial_pod
    let surviving_pod = pods
        .iter()
        .find(|pod| pod.ready && pod.name != initial_pod)
        .expect("a second pre-existing ready gateway pod")
        .name
        .clone();
    let port = reserve_loopback_port();
    let mut initial_forward =
        port_forward_gateway_pod(&gateway_namespace, &initial_pod, port).await;
    // Retain an independent connection to the replica that will survive the
    // failure. It is deliberately separate from the stable client endpoint so
    // cleanup and its verification never fall back to a Service or Route.
    let cleanup_port = reserve_loopback_port();
    let mut surviving_forward =
        port_forward_gateway_pod(&gateway_namespace, &surviving_pod, cleanup_port).await;

    let script = format!(
        "printf '%s\\n' '{SENTINEL}' > /sandbox/.odh-ha-sentinel; session_id=$(cat /proc/sys/kernel/random/uuid); while :; do printf '%s:%s:%s\\n' '{OUTPUT_MARKER}' \"$session_id\" \"$(date +%s)\"; sleep 1; done"
    ); // persist a workspace sentinel and stream a process-specific heartbeat
    let mut sandbox = create_on_initial_gateway(&initial_forward.endpoint, &script).await; // make sandbox w/sentinel file
    // Keep ownership of the sandbox here so every assertion failure still
    // reaches awaited cleanup before the test unwinds.
    let scenario = AssertUnwindSafe(run_failover_scenario(
        &gateway_namespace,
        &sandbox_namespace,
        &selector,
        &initial_pod,
        &surviving_pod,
        &mut initial_forward,
        &sandbox,
    ))
    .catch_unwind()
    .await;

    // Do not reuse the tunnel that sat idle during failover: `oc port-forward`
    // can exit or stall without affecting the session path. Keep it alive
    // while creating a fresh tunnel on a separate local port, so it remains a
    // best-effort cleanup path if the replacement cannot be established.
    let refreshed = AssertUnwindSafe(port_forward_gateway_pod(
        &gateway_namespace,
        &surviving_pod,
        reserve_loopback_port(),
    ))
    .catch_unwind()
    .await;
    let cleanup = match refreshed {
        Ok(forward) => {
            stop_port_forward(&mut surviving_forward).await;
            surviving_forward = forward;
            sandbox.cleanup(&surviving_forward.endpoint).await
        }
        Err(_) => {
            eprintln!(
                "could not establish a fresh port-forward to {surviving_pod} for cleanup; \
                 attempting cleanup through the original tunnel"
            );
            match sandbox.cleanup(&surviving_forward.endpoint).await {
                Ok(()) => Err(format!(
                    "could not establish a fresh port-forward to {surviving_pod} for cleanup; \
                     sandbox was deleted through the original tunnel"
                )),
                Err(error) => Err(format!(
                    "could not establish a fresh port-forward to {surviving_pod} for cleanup; \
                     cleanup through the original tunnel also failed: {error}"
                )),
            }
        }
    };
    match scenario {
        Ok(pod_selector) => {
            cleanup.expect("delete sandbox through the surviving gateway pod");
            assert_sandbox_deleted(
                &surviving_forward.endpoint,
                &sandbox_namespace,
                &sandbox.name,
                &pod_selector,
            )
            .await;
        }
        Err(failure) => {
            if let Err(cleanup_error) = cleanup {
                eprintln!("{cleanup_error}");
            }
            stop_port_forward(&mut surviving_forward).await;
            std::panic::resume_unwind(failure);
        }
    }
    stop_port_forward(&mut surviving_forward).await;
}

// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! OCP `NetworkPolicy` interaction with the Kubernetes proxy-pod boundary.
//!
//! Workload connections are intercepted locally and relayed over the private
//! boundary to a separate supervisor pod. The fixture is addressed by pod IP
//! so Service DNAT cannot hide which OVN flow the supervisor uses.

use std::io::Write as _;
use std::net::IpAddr;
use std::process::Stdio;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::odh_harness::oc::{
    OC_COMMAND_TIMEOUT, OcOutput, is_openshift, oc, oc_json, oc_std_command, oc_with_timeout,
};
use crate::odh_harness::sandbox::sandbox_pod_selector;
use base64::Engine as _;
use openshell_e2e::harness::binary::openshell_cmd;
use openshell_e2e::harness::sandbox::SandboxGuard;
use serde_json::{Value, json};
use tempfile::NamedTempFile;

const FIXTURE_IMAGE_ENV: &str = "OPENSHELL_ODH_NETWORK_POLICY_FIXTURE_IMAGE";
const DEFAULT_FIXTURE_IMAGE: &str = "registry.access.redhat.com/ubi9/python-311@sha256:a0bdb55576fc5b8d6704279307817828ef027e1065533ceba133fe9516003a6c";
const PORT: u16 = 8080;
const FIXTURE_LABEL: &str = "openshell.ai/odh-network-policy-fixture";
const BOUNDARY_PAIR_LABEL: &str = "openshell.ai/boundary-pair";
const BOUNDARY_ROLE_LABEL: &str = "openshell.ai/boundary-role";
const WORKLOAD_ROLE: &str = "workload";
const SUPERVISOR_ROLE: &str = "supervisor";
const WORKLOAD_POLICY_NAME: &str = "openshell-sandbox-workloads";
const SUPERVISOR_POLICY_NAME: &str = "openshell-sandbox-supervisors";
const NETWORK_POLICY_TIMEOUT: Duration = Duration::from_secs(30);
const NETWORK_POLICY_POLL_INTERVAL: Duration = Duration::from_secs(2);
const CLEANUP_COMMAND_TIMEOUT: Duration = Duration::from_secs(30);
/// Must exceed `oc wait --timeout=120s` so the harness does not preempt it.
const POD_READINESS_COMMAND_TIMEOUT: Duration = Duration::from_secs(150);
const REQUEST_ALLOWED_MARKER: &str = "ODH_NETWORK_POLICY_REQUEST_ALLOWED";
const REQUEST_DENIED_MARKER: &str = "ODH_NETWORK_POLICY_REQUEST_DENIED";
const BOUNDARY_VERIFIED_MARKER: &str = "ODH_BOUNDARY_TLS_VERIFIED";
const BOUNDARY_REJECTED_MARKER: &str = "ODH_BOUNDARY_TLS_REJECTED";

/// A disposable fixture and the `NetworkPolicy` resources it owns.
///
/// The explicit cleanup makes successful runs deterministic. The `Drop`
/// fallback: assertions abort a test immediately, so a policy cannot be
/// left selecting a sandbox after a failed test.
struct NetworkPolicyFixture {
    namespace: String,
    name: String,
    selector_value: String,
    ip: String,
    cidr: String,
    policies: Vec<String>,
    cleaned_up: bool,
}

struct SandboxBoundary {
    pair: String,
    workload: Value,
    supervisor: Value,
}

struct DirectEgressProbe {
    namespace: String,
    name: String,
    cleaned_up: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RequestOutcome {
    Allowed,
    Denied,
}

async fn sandbox_exec(sandbox: &SandboxGuard, argv: &[&str]) -> OcOutput {
    let mut cmd = openshell_cmd();
    cmd.args(["sandbox", "exec", "--name", &sandbox.name, "--no-tty", "--"])
        .args(argv)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let output = tokio::time::timeout(OC_COMMAND_TIMEOUT, cmd.output())
        .await
        .unwrap_or_else(|_| {
            panic!(
                "sandbox exec {:?} for {} timed out after {} seconds",
                argv,
                sandbox.name,
                OC_COMMAND_TIMEOUT.as_secs()
            )
        })
        .expect("run sandbox exec");
    OcOutput::from_output(&output)
}

fn namespace() -> String {
    std::env::var("SANDBOX_NAMESPACE")
        .or_else(|_| std::env::var("NAMESPACE"))
        .unwrap_or_else(|_| "openshell".to_string())
}

fn fixture_image() -> String {
    let image =
        std::env::var(FIXTURE_IMAGE_ENV).unwrap_or_else(|_| DEFAULT_FIXTURE_IMAGE.to_string());
    let valid_digest = image
        .split_once("@sha256:")
        .is_some_and(|(repository, digest)| {
            !repository.is_empty()
                && !repository.contains('@')
                && digest.len() == 64
                && digest
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
        });
    assert!(
        valid_digest,
        "{FIXTURE_IMAGE_ENV} must be an image pinned to a lowercase SHA-256 digest, got {image:?}"
    );
    image
}

fn fixture_manifest(image: &str, selector_value: &str) -> String {
    json!({"apiVersion":"v1","kind":"Pod","metadata":{"generateName":"odh-network-policy-fixture-","labels":{FIXTURE_LABEL:selector_value}},"spec":{"automountServiceAccountToken":false,"restartPolicy":"Never","containers":[{"name":"http","image":image,"env":[{"name":"POD_IP","valueFrom":{"fieldRef":{"fieldPath":"status.podIP"}}}],"command":["python3","-c",format!("import os,socket\nfrom http.server import BaseHTTPRequestHandler,HTTPServer\npod_ip=os.environ['POD_IP']\nclass H(BaseHTTPRequestHandler):\n def do_GET(self):\n  b=b'ok';self.send_response(200);self.send_header('Content-Length',str(len(b)));self.end_headers();self.wfile.write(b)\n def log_message(self,*args):pass\nclass S(HTTPServer):\n address_family=socket.AF_INET6 if ':' in pod_ip else socket.AF_INET\nS(('::' if ':' in pod_ip else '0.0.0.0',{PORT}),H).serve_forever()")],"ports":[{"containerPort":PORT}]}]}}).to_string()
}

fn policy(host: &str, cidr: &str) -> NamedTempFile {
    let mut file = NamedTempFile::new().expect("create policy file");
    write!(
        file,
        r#"version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /proc, /dev/urandom, /app, /etc, /var/log]
  read_write: [/sandbox, /tmp, /dev/null]
landlock: {{ compatibility: best_effort }}
process: {{ run_as_user: sandbox, run_as_group: sandbox }}
network_policies:
  fixture:
    name: fixture
    endpoints:
      - host: {host}
        port: {PORT}
        path: /health
        protocol: rest
        enforcement: enforce
        allowed_ips: ["{cidr}"]
        rules:
          - allow: {{ method: GET, path: /health }}
    binaries:
      - path: "/**"
"#
    )
    .expect("write policy");
    file.flush().expect("flush policy");
    file
}

async fn sandbox_pod(namespace: &str, sandbox: &SandboxGuard) -> Value {
    let pod_selector = sandbox_pod_selector(namespace, &sandbox.name)
        .await
        .expect("sandbox CR pod selector");
    let pods = oc_json(&[
        "get",
        "pods",
        "-n",
        namespace,
        "-l",
        &pod_selector,
        "-o",
        "json",
    ])
    .await;
    pods["items"]
        .as_array()
        .and_then(|items| items.first())
        .cloned()
        .expect("sandbox pod")
}

async fn apply_network_policy(namespace: &str, name: &str, spec: Value) {
    let manifest = json!({"apiVersion":"networking.k8s.io/v1","kind":"NetworkPolicy","metadata":{"name":name},"spec":spec}).to_string();
    let output = oc(&["apply", "-n", namespace, "-f", "-"], Some(&manifest)).await;
    assert!(
        output.success,
        "apply NetworkPolicy {name} failed:\n{}",
        output.status_summary()
    );
}

fn fixture_ingress_deny(fixture: &NetworkPolicyFixture) -> Value {
    json!({
        "podSelector": {"matchLabels": {FIXTURE_LABEL: fixture.selector_value}},
        "policyTypes": ["Ingress"],
        "ingress": []
    })
}

async fn delete(namespace: &str, kind: &str, name: &str) -> bool {
    oc(
        &[
            "delete",
            kind,
            name,
            "-n",
            namespace,
            "--ignore-not-found",
            "--wait=false",
        ],
        None,
    )
    .await
    .success
}

/// Deletes a resource during synchronous `Drop` cleanup without allowing a
/// stalled `oc` process to block the test binary indefinitely.
fn delete_sync(namespace: &str, kind: &str, name: &str) {
    let Ok(mut child) = oc_std_command()
        .args([
            "delete",
            kind,
            name,
            "-n",
            namespace,
            "--ignore-not-found",
            "--wait=false",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    else {
        return;
    };

    let deadline = Instant::now() + CLEANUP_COMMAND_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) | Err(_) => return,
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(100)),
        }
    }
}

impl NetworkPolicyFixture {
    async fn create(namespace: String) -> Self {
        let image = fixture_image();
        let selector_value = format!(
            "{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system time after Unix epoch")
                .as_nanos()
        );
        let output = oc(
            &["create", "-n", &namespace, "-f", "-", "-o", "json"],
            Some(&fixture_manifest(&image, &selector_value)),
        )
        .await;
        assert!(
            output.success,
            "create fixture pod failed:\n{}",
            output.status_summary()
        );
        let fixture = output.json().expect("fixture JSON");
        let name = fixture["metadata"]["name"]
            .as_str()
            .expect("fixture name")
            .to_string();
        // Construct the guard before waiting or inspecting the pod: either
        // operation can panic, and the successfully-created pod must still be
        // removed in that case.
        let mut fixture = Self {
            namespace,
            name,
            selector_value,
            ip: String::new(),
            cidr: String::new(),
            policies: Vec::new(),
            cleaned_up: false,
        };
        let ready = oc_with_timeout(
            &[
                "wait",
                "--for=condition=Ready",
                "pod",
                &fixture.name,
                "-n",
                &fixture.namespace,
                "--timeout=120s",
            ],
            None,
            POD_READINESS_COMMAND_TIMEOUT,
        )
        .await;
        assert!(
            ready.success,
            "fixture did not become ready:\n{}",
            ready.status_summary()
        );
        let pod = oc_json(&[
            "get",
            "pod",
            &fixture.name,
            "-n",
            &fixture.namespace,
            "-o",
            "json",
        ])
        .await;
        let ip = pod["status"]["podIP"]
            .as_str()
            .expect("fixture pod IP")
            .to_string();
        let prefix = match ip.parse::<IpAddr>().expect("valid fixture pod IP") {
            IpAddr::V4(_) => 32,
            IpAddr::V6(_) => 128,
        };

        fixture.cidr = format!("{ip}/{prefix}");
        fixture.ip = ip;
        fixture
    }

    async fn apply_policy(&mut self, name: String, spec: Value) {
        apply_network_policy(&self.namespace, &name, spec).await;
        if !self.policies.contains(&name) {
            self.policies.push(name);
        }
    }

    async fn cleanup(&mut self) {
        if self.cleaned_up {
            return;
        }
        let mut failed_policies = Vec::new();
        for name in self.policies.drain(..).rev() {
            if !delete(&self.namespace, "networkpolicy", &name).await {
                failed_policies.push(name);
            }
        }
        failed_policies.reverse();
        self.policies = failed_policies;
        let pod_deleted = delete(&self.namespace, "pod", &self.name).await;
        self.cleaned_up = self.policies.is_empty() && pod_deleted;
    }
}

impl Drop for NetworkPolicyFixture {
    fn drop(&mut self) {
        if self.cleaned_up {
            return;
        }

        let namespace = self.namespace.clone();
        let name = self.name.clone();
        let policies = std::mem::take(&mut self.policies);
        let cleanup = std::thread::spawn(move || {
            for policy in policies.into_iter().rev() {
                delete_sync(&namespace, "networkpolicy", &policy);
            }
            delete_sync(&namespace, "pod", &name);
        });
        let _ = cleanup.join();
    }
}

impl DirectEgressProbe {
    async fn create(namespace: String) -> Self {
        let image = fixture_image();
        let name = format!(
            "odh-network-policy-probe-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system time after Unix epoch")
                .as_nanos()
        );
        // Keep the explicit name under cleanup ownership before invoking oc:
        // create may succeed even if its response is lost or unusable.
        let probe = Self {
            namespace,
            name,
            cleaned_up: false,
        };
        let manifest = json!({
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {"name": probe.name},
            "spec": {
                "automountServiceAccountToken": false,
                "restartPolicy": "Never",
                "containers": [{
                    "name": "probe",
                    "image": image,
                    "command": ["python3", "-c", "import time; time.sleep(3600)"]
                }]
            }
        })
        .to_string();
        let output = oc(
            &["create", "-n", &probe.namespace, "-f", "-", "-o", "json"],
            Some(&manifest),
        )
        .await;
        assert!(
            output.success,
            "create direct-egress probe failed:\n{}",
            output.status_summary()
        );
        let ready = oc_with_timeout(
            &[
                "wait",
                "--for=condition=Ready",
                "pod",
                &probe.name,
                "-n",
                &probe.namespace,
                "--timeout=120s",
            ],
            None,
            POD_READINESS_COMMAND_TIMEOUT,
        )
        .await;
        assert!(
            ready.success,
            "direct-egress probe did not become ready:\n{}",
            ready.status_summary()
        );
        probe
    }

    async fn select_as_role(&self, pair: &str, role: &str) {
        let role_label = format!("{BOUNDARY_ROLE_LABEL}={role}");
        let pair_label = format!("{BOUNDARY_PAIR_LABEL}={pair}");
        let output = oc(
            &[
                "label",
                "pod",
                &self.name,
                "-n",
                &self.namespace,
                &role_label,
                &pair_label,
                "--overwrite",
            ],
            None,
        )
        .await;
        assert!(
            output.success,
            "label direct-egress probe as {role} failed:\n{}",
            output.status_summary()
        );
    }

    async fn verify_boundary_tls(
        &self,
        ip: &str,
        port: i64,
        server_name: &str,
        trust_anchor: &str,
    ) -> OcOutput {
        let script = format!(
            r"import socket,ssl,sys
context=ssl.create_default_context(cadata=sys.argv[4])
try:
 with socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=10) as conn:
  with context.wrap_socket(conn,server_hostname=sys.argv[3]) as tls:
   print('{BOUNDARY_VERIFIED_MARKER}')
except ssl.SSLCertVerificationError:
 print('{BOUNDARY_REJECTED_MARKER}')"
        );
        oc(
            &[
                "exec",
                "-n",
                &self.namespace,
                &self.name,
                "--",
                "python3",
                "-c",
                &script,
                ip,
                &port.to_string(),
                server_name,
                trust_anchor,
            ],
            None,
        )
        .await
    }

    async fn request(&self, ip: &str) -> OcOutput {
        oc(
            &[
                "exec",
                "-n",
                &self.namespace,
                &self.name,
                "--",
                "python3",
                "-c",
                &request(ip),
            ],
            None,
        )
        .await
    }

    async fn cleanup(&mut self) {
        if self.cleaned_up {
            return;
        }
        self.cleaned_up = delete(&self.namespace, "pod", &self.name).await;
    }
}

impl Drop for DirectEgressProbe {
    fn drop(&mut self) {
        if self.cleaned_up {
            return;
        }
        let namespace = self.namespace.clone();
        let name = self.name.clone();
        let cleanup = std::thread::spawn(move || {
            delete_sync(&namespace, "pod", &name);
        });
        let _ = cleanup.join();
    }
}

async fn sandbox_boundary(namespace: &str, sandbox: &SandboxGuard) -> SandboxBoundary {
    let workload = sandbox_pod(namespace, sandbox).await;
    assert_eq!(
        workload["metadata"]["labels"][BOUNDARY_ROLE_LABEL].as_str(),
        Some(WORKLOAD_ROLE),
        "Sandbox CR must select proxy-pod workload"
    );
    let pair = workload["metadata"]["labels"][BOUNDARY_PAIR_LABEL]
        .as_str()
        .expect("workload boundary-pair label")
        .to_string();
    let selector = format!("{BOUNDARY_ROLE_LABEL}={SUPERVISOR_ROLE},{BOUNDARY_PAIR_LABEL}={pair}");
    let pods = oc_json(&[
        "get", "pods", "-n", namespace, "-l", &selector, "-o", "json",
    ])
    .await;
    let supervisors = pods["items"].as_array().expect("supervisor pod list");
    assert_eq!(
        supervisors.len(),
        1,
        "one supervisor pod must match workload boundary pair {pair}"
    );
    let supervisor = supervisors[0].clone();
    assert_ne!(
        workload["metadata"]["uid"], supervisor["metadata"]["uid"],
        "workload and supervisor must be separate pods"
    );
    SandboxBoundary {
        pair,
        workload,
        supervisor,
    }
}

async fn assert_managed_network_fence(namespace: &str, boundary: &SandboxBoundary) {
    let service_name = format!("os-boundary-{}", boundary.pair);
    let service = oc_json(&[
        "get",
        "service",
        &service_name,
        "-n",
        namespace,
        "-o",
        "json",
    ])
    .await;
    assert_eq!(
        service["spec"]["selector"],
        json!({
            BOUNDARY_PAIR_LABEL: boundary.pair,
            BOUNDARY_ROLE_LABEL: WORKLOAD_ROLE
        }),
        "boundary Service must select only its paired workload"
    );
    let boundary_port = boundary_port(&service);

    let workload_policy = oc_json(&[
        "get",
        "networkpolicy",
        WORKLOAD_POLICY_NAME,
        "-n",
        namespace,
        "-o",
        "json",
    ])
    .await;
    assert_eq!(
        workload_policy["spec"]["podSelector"]["matchLabels"],
        json!({BOUNDARY_ROLE_LABEL: WORKLOAD_ROLE}),
        "managed workload policy must select proxy-pod workloads"
    );
    assert_eq!(
        workload_policy["spec"]["policyTypes"],
        json!(["Ingress", "Egress"]),
        "managed workload policy must isolate both ingress and egress"
    );
    let egress = &workload_policy["spec"]["egress"];
    assert!(
        egress.is_null() || egress == &json!([]),
        "managed workload policy must deny direct workload egress; expected an omitted or empty egress list, got {egress}"
    );
    assert_eq!(
        workload_policy["spec"]["ingress"],
        json!([{
            "from": [{
                "podSelector": {
                    "matchLabels": {BOUNDARY_ROLE_LABEL: SUPERVISOR_ROLE}
                }
            }],
            "ports": [{"protocol": "TCP", "port": boundary_port}]
        }]),
        "managed workload policy must allow only supervisor ingress on the boundary port"
    );

    let supervisor_policy = oc_json(&[
        "get",
        "networkpolicy",
        SUPERVISOR_POLICY_NAME,
        "-n",
        namespace,
        "-o",
        "json",
    ])
    .await;
    assert_eq!(
        supervisor_policy["spec"]["podSelector"]["matchLabels"],
        json!({BOUNDARY_ROLE_LABEL: SUPERVISOR_ROLE}),
        "managed supervisor policy must select proxy-pod supervisors"
    );
    assert_eq!(
        supervisor_policy["spec"]["policyTypes"],
        json!(["Egress"]),
        "managed supervisor policy must select egress traffic"
    );
    assert_eq!(
        supervisor_policy["spec"]["egress"],
        json!([{}]),
        "managed supervisor egress rule must allow gateway, DNS, and upstream traffic"
    );
    assert_eq!(
        boundary.workload["metadata"]["labels"][BOUNDARY_PAIR_LABEL],
        boundary.supervisor["metadata"]["labels"][BOUNDARY_PAIR_LABEL],
        "workload and supervisor must share one authenticated boundary pair"
    );
}

fn boundary_port(service: &Value) -> i64 {
    service["spec"]["ports"][0]["port"]
        .as_i64()
        .expect("boundary Service port")
}

async fn boundary_service(namespace: &str, boundary: &SandboxBoundary) -> Value {
    let service_name = format!("os-boundary-{}", boundary.pair);
    oc_json(&[
        "get",
        "service",
        &service_name,
        "-n",
        namespace,
        "-o",
        "json",
    ])
    .await
}

async fn assert_distinct_boundary_pairs(
    namespace: &str,
    first: &SandboxBoundary,
    second: &SandboxBoundary,
) {
    assert_ne!(
        first.pair, second.pair,
        "independent sandboxes must receive distinct boundary-pair labels"
    );
    assert_ne!(
        first.workload["metadata"]["uid"], second.workload["metadata"]["uid"],
        "independent sandboxes must have distinct workload pods"
    );
    assert_ne!(
        first.supervisor["metadata"]["uid"], second.supervisor["metadata"]["uid"],
        "independent sandboxes must have distinct supervisor pods"
    );

    let first_service = boundary_service(namespace, first).await;
    let second_service = boundary_service(namespace, second).await;
    assert_ne!(
        first_service["spec"]["selector"], second_service["spec"]["selector"],
        "boundary Services for independent sandboxes must not select the same workload"
    );
}

async fn supervisor_trust_anchor(namespace: &str, boundary: &SandboxBoundary) -> (String, String) {
    let volumes = boundary.supervisor["spec"]["volumes"]
        .as_array()
        .expect("supervisor volumes");
    let secret_name = volumes
        .iter()
        .find(|volume| volume["name"] == "bootstrap")
        .and_then(|volume| volume["secret"]["secretName"].as_str())
        .expect("supervisor bootstrap Secret name");
    let secret = oc_json(&["get", "secret", secret_name, "-n", namespace, "-o", "json"]).await;
    let encoded = secret["data"]["runtime-descriptor.json"]
        .as_str()
        .expect("supervisor runtime descriptor");
    let descriptor = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .expect("base64 supervisor runtime descriptor");
    let descriptor: Value =
        serde_json::from_slice(&descriptor).expect("supervisor runtime descriptor JSON");
    assert_eq!(
        descriptor["boundary_id"].as_str(),
        Some(boundary.pair.as_str()),
        "supervisor descriptor must belong to the selected boundary pair"
    );
    let server_name = descriptor["tls"]["server_name"]
        .as_str()
        .expect("boundary TLS server name")
        .to_string();
    let trust_anchor = descriptor["tls"]["trust_anchor_pem"]
        .as_str()
        .expect("boundary TLS trust anchor")
        .to_string();
    (server_name, trust_anchor)
}

async fn assert_peer_boundary_rejected(
    probe: &DirectEgressProbe,
    namespace: &str,
    own: &SandboxBoundary,
    peer: &SandboxBoundary,
) {
    let (server_name, trust_anchor) = supervisor_trust_anchor(namespace, own).await;
    let own_service = boundary_service(namespace, own).await;
    let peer_service = boundary_service(namespace, peer).await;
    let own_ip = own_service["spec"]["clusterIP"]
        .as_str()
        .expect("own boundary Service IP");
    let peer_ip = peer_service["spec"]["clusterIP"]
        .as_str()
        .expect("peer boundary Service IP");
    let started = Instant::now();
    let own_output = loop {
        let output = probe
            .verify_boundary_tls(
                own_ip,
                boundary_port(&own_service),
                &server_name,
                &trust_anchor,
            )
            .await;
        if (output.success && output.has_stdout_line(BOUNDARY_VERIFIED_MARKER))
            || started.elapsed() >= NETWORK_POLICY_TIMEOUT
        {
            break output;
        }
        tokio::time::sleep(NETWORK_POLICY_POLL_INTERVAL).await;
    };
    assert!(
        own_output.success && own_output.has_stdout_line(BOUNDARY_VERIFIED_MARKER),
        "own boundary TLS handshake must succeed through its Service ({})",
        own_output.status_summary()
    );
    let peer_output = probe
        .verify_boundary_tls(
            peer_ip,
            boundary_port(&peer_service),
            &server_name,
            &trust_anchor,
        )
        .await;
    assert!(
        peer_output.success && peer_output.has_stdout_line(BOUNDARY_REJECTED_MARKER),
        "peer boundary must fail this pair's pinned TLS verification through its Service ({})",
        peer_output.status_summary()
    );
}

fn request(ip: &str) -> String {
    let host = if ip.contains(':') {
        format!("[{ip}]")
    } else {
        ip.to_string()
    };
    format!(
        "import urllib.error,urllib.request\ntry:\n response=urllib.request.urlopen('http://{host}:{PORT}/health',timeout=10)\n if response.status != 200: raise RuntimeError(f'unexpected HTTP status {{response.status}}')\nexcept urllib.error.HTTPError:\n print('{REQUEST_DENIED_MARKER}')\nexcept (urllib.error.URLError,TimeoutError,OSError):\n print('{REQUEST_DENIED_MARKER}')\nelse:\n print('{REQUEST_ALLOWED_MARKER}')"
    )
}

fn request_outcome(output: &OcOutput, source: &str) -> RequestOutcome {
    assert!(
        output.success,
        "{source} command failed ({})",
        output.status_summary()
    );
    if output.has_stdout_line(REQUEST_ALLOWED_MARKER) {
        RequestOutcome::Allowed
    } else if output.has_stdout_line(REQUEST_DENIED_MARKER) {
        RequestOutcome::Denied
    } else {
        panic!("{source} command returned no recognized request outcome")
    }
}

async fn wait_for_request(
    sandbox: &SandboxGuard,
    ip: &str,
    expected: RequestOutcome,
) -> RequestOutcome {
    let started = Instant::now();
    loop {
        let outcome = request_outcome(
            &sandbox_exec(sandbox, &["python3", "-c", &request(ip)]).await,
            "sandbox exec",
        );
        if outcome == expected || started.elapsed() >= NETWORK_POLICY_TIMEOUT {
            return outcome;
        }
        tokio::time::sleep(NETWORK_POLICY_POLL_INTERVAL).await;
    }
}

async fn wait_for_probe_request(
    probe: &DirectEgressProbe,
    ip: &str,
    expected: RequestOutcome,
) -> RequestOutcome {
    let started = Instant::now();
    loop {
        let outcome = request_outcome(&probe.request(ip).await, "oc exec probe");
        if outcome == expected || started.elapsed() >= NETWORK_POLICY_TIMEOUT {
            return outcome;
        }
        tokio::time::sleep(NETWORK_POLICY_POLL_INTERVAL).await;
    }
}

#[tokio::test]
async fn supervisor_deny_is_stricter_than_available_ocp_path() {
    if !is_openshift()
        .await
        .unwrap_or_else(|error| panic!("{error}"))
    {
        eprintln!("skipping NetworkPolicy test: active cluster is not OpenShift");
        return;
    }
    let mut fixture = NetworkPolicyFixture::create(namespace()).await;
    let policy = policy(&fixture.ip, &fixture.cidr);
    let policy_path = policy
        .path()
        .to_str()
        .expect("UTF-8 policy path")
        .to_string();
    let mut allowed_sandbox = SandboxGuard::create(&["--policy", &policy_path])
        .await
        .unwrap_or_else(|_| panic!("failed to create allowed sandbox"));
    let mut denied_sandbox = SandboxGuard::create(&[])
        .await
        .unwrap_or_else(|_| panic!("failed to create denied sandbox"));
    let _allowed_boundary = sandbox_boundary(&fixture.namespace, &allowed_sandbox).await;
    let _denied_boundary = sandbox_boundary(&fixture.namespace, &denied_sandbox).await;

    // Positive controls on both sides of the denied request prove that the
    // driver-managed supervisor egress path remains available while the
    // OpenShell policy independently rejects the denied sandbox's request.
    let allowed_before = request_outcome(
        &sandbox_exec(&allowed_sandbox, &["python3", "-c", &request(&fixture.ip)]).await,
        "allowed sandbox exec before denial",
    );
    let blocked = request_outcome(
        &sandbox_exec(&denied_sandbox, &["python3", "-c", &request(&fixture.ip)]).await,
        "denied sandbox exec",
    );
    let allowed_after = request_outcome(
        &sandbox_exec(&allowed_sandbox, &["python3", "-c", &request(&fixture.ip)]).await,
        "allowed sandbox exec after denial",
    );
    denied_sandbox.cleanup().await;
    allowed_sandbox.cleanup().await;
    fixture.cleanup().await;
    assert!(
        allowed_before == RequestOutcome::Allowed,
        "OpenShift networking must provide the supervisor upstream path before the deny check"
    );
    assert!(
        blocked == RequestOutcome::Denied,
        "supervisor deny must reject the request even when the OpenShift path is available; \
         the denial may be enforced by the supervisor (403) or locally before relay \
         (Permission denied)"
    );
    assert!(
        allowed_after == RequestOutcome::Allowed,
        "OpenShift networking must still provide the supervisor upstream path after the deny check"
    );
}

#[tokio::test]
async fn ocp_ingress_deny_blocks_supervisor_l7_allow() {
    if !is_openshift()
        .await
        .unwrap_or_else(|error| panic!("{error}"))
    {
        eprintln!("skipping NetworkPolicy test: active cluster is not OpenShift");
        return;
    }
    let mut fixture = NetworkPolicyFixture::create(namespace()).await;
    let policy = policy(&fixture.ip, &fixture.cidr);
    let policy_path = policy
        .path()
        .to_str()
        .expect("UTF-8 policy path")
        .to_string();
    let mut sandbox = SandboxGuard::create(&["--policy", &policy_path])
        .await
        .unwrap_or_else(|_| panic!("failed to create allowed sandbox"));
    let _boundary = sandbox_boundary(&fixture.namespace, &sandbox).await;
    let baseline = request_outcome(
        &sandbox_exec(&sandbox, &["python3", "-c", &request(&fixture.ip)]).await,
        "baseline sandbox exec",
    );
    assert!(
        baseline == RequestOutcome::Allowed,
        "supervisor L7 allow must reach fixture before applying NetworkPolicy"
    );

    let policy_name = format!("odh-ingress-deny-{}", sandbox.name);
    fixture
        // Ordinary Kubernetes NetworkPolicies are additive. The driver-owned
        // supervisor policy already allows all supervisor egress, so another
        // egress deny-all policy cannot revoke it. Deny ingress at the unique
        // fixture instead to prove OVN can still block supervisor-allowed
        // traffic without breaking the supervisor control channel.
        .apply_policy(policy_name, fixture_ingress_deny(&fixture))
        .await;
    let blocked = wait_for_request(&sandbox, &fixture.ip, RequestOutcome::Denied).await;
    sandbox.cleanup().await;
    fixture.cleanup().await;
    assert!(
        blocked == RequestOutcome::Denied,
        "OCP fixture deny must block a supervisor-allowed request after the workload starts"
    );
}

#[tokio::test]
async fn proxy_pod_network_fence_blocks_workload_egress_and_allows_supervisor_mediation() {
    if !is_openshift()
        .await
        .unwrap_or_else(|error| panic!("{error}"))
    {
        eprintln!("skipping NetworkPolicy test: active cluster is not OpenShift");
        return;
    }
    let mut fixture = NetworkPolicyFixture::create(namespace()).await;
    let policy = policy(&fixture.ip, &fixture.cidr);
    let policy_path = policy
        .path()
        .to_str()
        .expect("UTF-8 policy path")
        .to_string();
    let mut first_sandbox = SandboxGuard::create(&["--policy", &policy_path])
        .await
        .unwrap_or_else(|_| panic!("failed to create first allowed sandbox"));
    let mut second_sandbox = SandboxGuard::create(&["--policy", &policy_path])
        .await
        .unwrap_or_else(|_| panic!("failed to create second allowed sandbox"));
    let first_boundary = sandbox_boundary(&fixture.namespace, &first_sandbox).await;
    let second_boundary = sandbox_boundary(&fixture.namespace, &second_sandbox).await;
    assert_managed_network_fence(&fixture.namespace, &first_boundary).await;
    assert_managed_network_fence(&fixture.namespace, &second_boundary).await;
    assert_distinct_boundary_pairs(&fixture.namespace, &first_boundary, &second_boundary).await;

    // The same pod can reach the fixture before it carries the workload label.
    // Adding that label selects the driver-managed policy, so the subsequent
    // failure actively proves that OVN enforces the empty workload egress list.
    let mut probe = DirectEgressProbe::create(fixture.namespace.clone()).await;
    let direct_before = request_outcome(
        &probe.request(&fixture.ip).await,
        "direct probe before fence",
    );
    // Give the probe the same NetworkPolicy path as a supervisor. Its own
    // boundary accepts the pinned TLS identity; the peer Service is reachable
    // over that path but presents a different per-session certificate.
    probe
        .select_as_role(&first_boundary.pair, SUPERVISOR_ROLE)
        .await;
    assert_peer_boundary_rejected(
        &probe,
        &fixture.namespace,
        &first_boundary,
        &second_boundary,
    )
    .await;
    // The workload policy selects on role only, but each boundary Service
    // selects on both role and pair. Use a probe-only pair here so the probe
    // can exercise the workload policy without becoming an endpoint of either
    // sandbox boundary Service.
    let probe_pair = format!("probe-{}", probe.name);
    probe.select_as_role(&probe_pair, WORKLOAD_ROLE).await;
    let direct_blocked = wait_for_probe_request(&probe, &fixture.ip, RequestOutcome::Denied).await;
    let first_allowed =
        wait_for_request(&first_sandbox, &fixture.ip, RequestOutcome::Allowed).await;
    let second_allowed =
        wait_for_request(&second_sandbox, &fixture.ip, RequestOutcome::Allowed).await;
    probe.cleanup().await;
    second_sandbox.cleanup().await;
    first_sandbox.cleanup().await;
    fixture.cleanup().await;
    assert!(
        direct_before == RequestOutcome::Allowed,
        "unselected probe must reach the fixture before testing the workload fence"
    );
    assert!(
        direct_blocked == RequestOutcome::Denied,
        "OVN must block direct egress after the probe is selected as a workload"
    );
    assert!(
        first_allowed == RequestOutcome::Allowed && second_allowed == RequestOutcome::Allowed,
        "each independently paired supervisor must mediate its own workload's allowed request"
    );
}

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

use crate::odh_harness::oc::{OcOutput, is_openshift, oc, oc_json, oc_std_command};
use crate::odh_harness::sandbox::sandbox_pod_selector;
use openshell_e2e::harness::binary::openshell_cmd;
use openshell_e2e::harness::sandbox::SandboxGuard;
use serde_json::{Value, json};
use tempfile::NamedTempFile;

const FIXTURE_IMAGE_ENV: &str = "OPENSHELL_ODH_NETWORK_POLICY_FIXTURE_IMAGE";
const DEFAULT_FIXTURE_IMAGE: &str = "registry.access.redhat.com/ubi9/python-311:latest";
const PORT: u16 = 8080;
const MARKER: &str = "odh-network-policy-fixture";
const REQUEST_STARTED_MARKER: &str = "odh-network-policy-request-started";
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

/// A disposable fixture and the `NetworkPolicy` resources it owns.
///
/// The explicit cleanup makes successful runs deterministic. The `Drop`
/// fallback matters just as much: assertions abort a test immediately, so a
/// policy cannot be left selecting a sandbox after a failed test.
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

async fn sandbox_exec(sandbox: &SandboxGuard, argv: &[&str]) -> OcOutput {
    let mut cmd = openshell_cmd();
    cmd.args(["sandbox", "exec", "--name", &sandbox.name, "--no-tty", "--"])
        .args(argv)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let output = cmd.output().await.expect("run sandbox exec");
    OcOutput {
        success: output.status.success(),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    }
}

fn namespace() -> String {
    std::env::var("SANDBOX_NAMESPACE")
        .or_else(|_| std::env::var("NAMESPACE"))
        .unwrap_or_else(|_| "openshell".to_string())
}

fn fixture_manifest(image: &str, selector_value: &str) -> String {
    json!({"apiVersion":"v1","kind":"Pod","metadata":{"generateName":"odh-network-policy-fixture-","labels":{FIXTURE_LABEL:selector_value}},"spec":{"restartPolicy":"Never","containers":[{"name":"http","image":image,"env":[{"name":"POD_IP","valueFrom":{"fieldRef":{"fieldPath":"status.podIP"}}}],"command":["python3","-c",format!("import os,socket\nfrom http.server import BaseHTTPRequestHandler,HTTPServer\npod_ip=os.environ['POD_IP']\nclass H(BaseHTTPRequestHandler):\n def do_GET(self):\n  b=b'{MARKER}';self.send_response(200);self.send_header('Content-Length',str(len(b)));self.end_headers();self.wfile.write(b)\n def log_message(self,*args):pass\nclass S(HTTPServer):\n address_family=socket.AF_INET6 if ':' in pod_ip else socket.AF_INET\nS(('::' if ':' in pod_ip else '0.0.0.0',{PORT}),H).serve_forever()")],"ports":[{"containerPort":PORT}]}]}}).to_string()
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
        output.diagnostics()
    );
}

fn fixture_ingress_deny(fixture: &NetworkPolicyFixture) -> Value {
    json!({
        "podSelector": {"matchLabels": {FIXTURE_LABEL: fixture.selector_value}},
        "policyTypes": ["Ingress"],
        "ingress": []
    })
}

async fn delete(namespace: &str, kind: &str, name: &str) {
    let _ = oc(
        &["delete", kind, name, "-n", namespace, "--ignore-not-found"],
        None,
    )
    .await;
}

/// Deletes a resource during synchronous `Drop` cleanup without allowing a
/// stalled `oc` process to block the test binary indefinitely.
fn delete_sync(namespace: &str, kind: &str, name: &str) {
    let Ok(mut child) = oc_std_command()
        .args(["delete", kind, name, "-n", namespace, "--ignore-not-found"])
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
        let image =
            std::env::var(FIXTURE_IMAGE_ENV).unwrap_or_else(|_| DEFAULT_FIXTURE_IMAGE.to_string());
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
            output.diagnostics()
        );
        let fixture: Value = serde_json::from_str(&output.stdout).expect("fixture JSON");
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
        let ready = oc(
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
        )
        .await;
        assert!(
            ready.success,
            "fixture did not become ready:\n{}",
            ready.diagnostics()
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
        self.cleaned_up = true;
        for name in self.policies.drain(..).rev() {
            delete(&self.namespace, "networkpolicy", &name).await;
        }
        delete(&self.namespace, "pod", &self.name).await;
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
        let image =
            std::env::var(FIXTURE_IMAGE_ENV).unwrap_or_else(|_| DEFAULT_FIXTURE_IMAGE.to_string());
        let manifest = json!({
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {"generateName": "odh-network-policy-probe-"},
            "spec": {
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
            &["create", "-n", &namespace, "-f", "-", "-o", "json"],
            Some(&manifest),
        )
        .await;
        assert!(
            output.success,
            "create direct-egress probe failed:\n{}",
            output.diagnostics()
        );
        let pod: Value = serde_json::from_str(&output.stdout).expect("probe JSON");
        let name = pod["metadata"]["name"]
            .as_str()
            .expect("probe name")
            .to_string();
        let probe = Self {
            namespace,
            name,
            cleaned_up: false,
        };
        let ready = oc(
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
        )
        .await;
        assert!(
            ready.success,
            "direct-egress probe did not become ready:\n{}",
            ready.diagnostics()
        );
        probe
    }

    async fn select_as_workload(&self) {
        let label = format!("{BOUNDARY_ROLE_LABEL}={WORKLOAD_ROLE}");
        let output = oc(
            &[
                "label",
                "pod",
                &self.name,
                "-n",
                &self.namespace,
                &label,
                "--overwrite",
            ],
            None,
        )
        .await;
        assert!(
            output.success,
            "label direct-egress probe as workload failed:\n{}",
            output.diagnostics()
        );
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
        self.cleaned_up = true;
        delete(&self.namespace, "pod", &self.name).await;
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
    let boundary_port = service["spec"]["ports"][0]["port"]
        .as_i64()
        .expect("boundary Service port");

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
    assert_eq!(
        workload_policy["spec"]["egress"],
        json!([]),
        "managed workload policy must deny direct workload egress"
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

fn request(ip: &str) -> String {
    let host = if ip.contains(':') {
        format!("[{ip}]")
    } else {
        ip.to_string()
    };
    format!(
        "import urllib.request;print('{REQUEST_STARTED_MARKER}',flush=True);print(urllib.request.urlopen('http://{host}:{PORT}/health',timeout=10).read().decode())"
    )
}

async fn wait_for_request(sandbox: &SandboxGuard, ip: &str, expected_success: bool) -> OcOutput {
    let started = Instant::now();
    loop {
        let output = sandbox_exec(sandbox, &["python3", "-c", &request(ip)]).await;
        if output.success == expected_success || started.elapsed() >= NETWORK_POLICY_TIMEOUT {
            return output;
        }
        tokio::time::sleep(NETWORK_POLICY_POLL_INTERVAL).await;
    }
}

async fn wait_for_probe_request(
    probe: &DirectEgressProbe,
    ip: &str,
    expected_success: bool,
) -> OcOutput {
    let started = Instant::now();
    loop {
        let output = probe.request(ip).await;
        if output.success == expected_success || started.elapsed() >= NETWORK_POLICY_TIMEOUT {
            return output;
        }
        tokio::time::sleep(NETWORK_POLICY_POLL_INTERVAL).await;
    }
}

#[tokio::test]
async fn supervisor_deny_is_stricter_than_available_ocp_path() {
    if !is_openshift().await {
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
        .expect("create allowed sandbox");
    let mut denied_sandbox = SandboxGuard::create(&[])
        .await
        .expect("create denied sandbox");
    let _allowed_boundary = sandbox_boundary(&fixture.namespace, &allowed_sandbox).await;
    let _denied_boundary = sandbox_boundary(&fixture.namespace, &denied_sandbox).await;

    // Positive controls on both sides of the denied request prove that the
    // driver-managed supervisor egress path remains available while the
    // OpenShell policy independently rejects the denied sandbox's request.
    let allowed_before =
        sandbox_exec(&allowed_sandbox, &["python3", "-c", &request(&fixture.ip)]).await;
    let blocked = sandbox_exec(&denied_sandbox, &["python3", "-c", &request(&fixture.ip)]).await;
    let allowed_after =
        sandbox_exec(&allowed_sandbox, &["python3", "-c", &request(&fixture.ip)]).await;
    denied_sandbox.cleanup().await;
    allowed_sandbox.cleanup().await;
    fixture.cleanup().await;
    assert!(
        allowed_before.success && allowed_before.contains(MARKER),
        "OpenShift networking must provide the supervisor upstream path before the deny check:\n{}",
        allowed_before.diagnostics()
    );
    assert!(
        !blocked.success && blocked.contains("403"),
        "supervisor deny must be stricter than the available OpenShift network path:\n{}",
        blocked.diagnostics()
    );
    assert!(
        allowed_after.success && allowed_after.contains(MARKER),
        "OpenShift networking must still provide the supervisor upstream path after the deny check:\n{}",
        allowed_after.diagnostics()
    );
}

#[tokio::test]
async fn ocp_ingress_deny_blocks_supervisor_l7_allow() {
    if !is_openshift().await {
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
        .expect("create allowed sandbox");
    let _boundary = sandbox_boundary(&fixture.namespace, &sandbox).await;
    let baseline = sandbox_exec(&sandbox, &["python3", "-c", &request(&fixture.ip)]).await;
    assert!(
        baseline.success && baseline.contains(MARKER),
        "supervisor L7 allow must reach fixture before applying NetworkPolicy:\n{}",
        baseline.diagnostics()
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
    let blocked = wait_for_request(&sandbox, &fixture.ip, false).await;
    sandbox.cleanup().await;
    fixture.cleanup().await;
    assert!(
        !blocked.success && blocked.contains(REQUEST_STARTED_MARKER) && !blocked.contains("403"),
        "OCP fixture deny must block a supervisor-allowed request after the workload starts:\n{}",
        blocked.diagnostics()
    );
}

#[tokio::test]
async fn proxy_pod_network_fence_allows_supervisor_mediation() {
    if !is_openshift().await {
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
        .expect("create allowed sandbox");
    let boundary = sandbox_boundary(&fixture.namespace, &sandbox).await;
    assert_managed_network_fence(&fixture.namespace, &boundary).await;

    // The same pod can reach the fixture before it carries the workload label.
    // Adding that label selects the driver-managed policy, so the subsequent
    // failure actively proves that OVN enforces the empty workload egress list.
    let mut probe = DirectEgressProbe::create(fixture.namespace.clone()).await;
    let direct_before = probe.request(&fixture.ip).await;
    probe.select_as_workload().await;
    let direct_blocked = wait_for_probe_request(&probe, &fixture.ip, false).await;

    let allowed = wait_for_request(&sandbox, &fixture.ip, true).await;
    probe.cleanup().await;
    sandbox.cleanup().await;
    fixture.cleanup().await;
    assert!(
        direct_before.success && direct_before.contains(MARKER),
        "unselected probe must reach the fixture before testing the workload fence:\n{}",
        direct_before.diagnostics()
    );
    assert!(
        !direct_blocked.success
            && direct_blocked.contains(REQUEST_STARTED_MARKER)
            && !direct_blocked.contains("403"),
        "OVN must block direct egress after the probe is selected as a workload:\n{}",
        direct_blocked.diagnostics()
    );
    assert!(
        allowed.success && allowed.contains(MARKER),
        "supervisor mediation must coexist with the OVN workload egress fence:\n{}",
        allowed.diagnostics()
    );
}

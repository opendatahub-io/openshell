// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! SELinux process-label coverage for downstream OpenShift runs.

use openshell_e2e::harness::sandbox::SandboxGuard;

/// OCP's container SELinux type. The complete label includes per-pod MLS/MCS
/// categories, which vary and must not be hard-coded.
const CONTAINER_TYPE: &str = ":container_t:";

// The sidecar topology shares a PID namespace with the workload. Its process
// supervisor is mounted at /opt, while its network supervisor runs from the
// supervisor image at /openshell-sandbox. Check every expected component,
// rather than assuming a PID or inspecting /proc/<pid>/exe.
const SUPERVISOR_LABEL_SCRIPT: &str = r#"
case "${1:?missing supervisor topology}" in
  combined) expected_modes='combined' ;;
  sidecar) expected_modes='process network' ;;
  *) exit 2 ;;
esac
found_modes=''
for process in /proc/[0-9]*; do
  executable=$(tr '\0' '\n' < "$process/cmdline" 2>/dev/null | head -n 1)
  case "$executable" in
    /opt/openshell/bin/openshell-sandbox|/openshell-sandbox) ;;
    *) continue ;;
  esac
  mode=$(tr '\0' '\n' < "$process/cmdline" 2>/dev/null | sed -n 's/^--mode=//p' | head -n 1)
  [ -n "$mode" ] || mode=combined
  case " $expected_modes " in
    *" $mode "*) ;;
    *) continue ;;
  esac
  label=$(cat "$process/attr/current" 2>/dev/null) || exit 1
  printf '%s %s\n' "$mode" "$label"
  found_modes="$found_modes $mode"
done
for mode in $expected_modes; do
  case " $found_modes " in
    *" $mode "*) ;;
    *) exit 1 ;;
  esac
done
"#;

#[tokio::test]
async fn supervisor_runs_in_container_selinux_domain() {
    if std::env::var("ODH_SELINUX_ENFORCING_VERIFIED").as_deref() != Ok("1") {
        eprintln!("skipping SELinux-only test outside the qualification lane");
        return;
    }

    let mut sandbox = SandboxGuard::create(&[])
        .await
        .expect("sandbox create should succeed on OpenShift");
    let topology = std::env::var("ODH_SELINUX_SUPERVISOR_TOPOLOGY")
        .expect("SELinux qualification runner must set supervisor topology");

    let label = sandbox
        .exec(&["sh", "-ec", SUPERVISOR_LABEL_SCRIPT, "sh", &topology])
        .await
        .expect("read the supervisor SELinux process label");
    for line in label.lines() {
        assert!(
            line.contains(CONTAINER_TYPE),
            "expected supervisor {line:?} to run in container_t",
        );
    }

    sandbox.cleanup().await;
}

#[test]
fn supervisor_discovery_requires_all_topology_supervisors() {
    let proc = tempfile::tempdir().unwrap();
    let process = proc.path().join("42");
    std::fs::create_dir_all(process.join("attr")).unwrap();
    std::fs::write(
        process.join("attr/current"),
        "system_u:system_r:container_t:s0",
    )
    .unwrap();
    let script = SUPERVISOR_LABEL_SCRIPT.replace("/proc/", &format!("{}/", proc.path().display()));

    let run = |topology: &str, processes: &[(&str, &str)]| {
        for entry in std::fs::read_dir(proc.path()).unwrap() {
            let entry = entry.unwrap();
            if entry.file_name() != "42" {
                std::fs::remove_dir_all(entry.path()).unwrap();
            }
        }
        for (pid, args) in processes {
            let process = proc.path().join(pid);
            std::fs::create_dir_all(process.join("attr")).unwrap();
            std::fs::write(
                process.join("attr/current"),
                "system_u:system_r:container_t:s0",
            )
            .unwrap();
            std::fs::write(process.join("cmdline"), args).unwrap();
        }
        let output = std::process::Command::new("sh")
            .args(["-ec", &script, "sh", topology])
            .output()
            .unwrap();
        output
    };

    assert!(
        run(
            "combined",
            &[("42", "/opt/openshell/bin/openshell-sandbox\0--\0sleep\0")],
        )
        .status
        .success()
    );
    assert!(
        run(
            "sidecar",
            &[
                (
                    "42",
                    "/opt/openshell/bin/openshell-sandbox\0--mode=process\0"
                ),
                ("43", "/openshell-sandbox\0--mode=network\0"),
            ],
        )
        .status
        .success()
    );
    assert!(
        !run(
            "sidecar",
            &[(
                "42",
                "/opt/openshell/bin/openshell-sandbox\0--mode=process\0"
            )],
        )
        .status
        .success()
    );
}

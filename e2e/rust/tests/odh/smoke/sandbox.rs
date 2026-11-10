// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Basic sandbox create/exec/delete on an ODH/RHOAI `OpenShift` deployment.

use openshell_e2e::harness::sandbox::SandboxGuard;

#[tokio::test]
async fn test_create_delete() {
    // A bare `echo` exits before the gateway's create-time readiness
    // handshake completes, racing it into reporting "sandbox is not ready"
    // even though the pod itself finishes successfully. A brief sleep avoids
    // the race without depending on a fix to that handshake.
    let mut sb = SandboxGuard::create(&["--", "sh", "-c", "sleep 1 && echo odh-smoke-ok"])
        .await
        .expect("sandbox create should succeed");

    assert!(
        sb.create_output.contains("odh-smoke-ok"),
        "expected 'odh-smoke-ok' in sandbox output:\n{}",
        sb.create_output,
    );

    // Exercise a distinct relay request after sandbox creation. This is valid
    // for both supervisor topologies: sidecar pods share a process namespace,
    // so PID 1 belongs to Kubernetes pod infrastructure rather than the
    // process supervisor.
    let output = sb
        .exec(&["sh", "-c", "printf odh-exec-ok"])
        .await
        .expect("exec into sandbox should succeed");
    assert!(
        output.contains("odh-exec-ok"),
        "expected 'odh-exec-ok' in exec output:\n{output}",
    );

    sb.cleanup().await;
}

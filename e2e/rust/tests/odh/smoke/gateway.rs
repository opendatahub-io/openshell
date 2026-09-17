// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Gateway reachability and health checks (ODH/RHOAI-specific).

use std::process::Stdio;
use std::time::Duration;

use openshell_e2e::harness::binary::openshell_cmd;
use openshell_e2e::harness::output::strip_ansi;

const STATUS_TIMEOUT: Duration = Duration::from_secs(15);

fn status_summary(status: &str) -> &'static str {
    if status.contains("Connected") {
        "connected"
    } else if status.contains("Disconnected") {
        "disconnected"
    } else if status.contains("Error") {
        "error"
    } else {
        "unrecognized output"
    }
}

#[tokio::test]
async fn test_reachable() {
    let mut status_ok = false;
    let mut final_status = "no status output";
    for _ in 0..15 {
        let mut status_cmd = openshell_cmd();
        status_cmd
            .arg("status")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        let status_out = tokio::time::timeout(STATUS_TIMEOUT, status_cmd.output())
            .await
            .expect("openshell status timed out")
            .expect("failed to run openshell status");

        let status_text = format!(
            "{}{}",
            String::from_utf8_lossy(&status_out.stdout),
            String::from_utf8_lossy(&status_out.stderr),
        );
        let clean_status = strip_ansi(&status_text);
        final_status = status_summary(&clean_status);

        if status_out.status.success() && clean_status.contains("Connected") {
            status_ok = true;
            break;
        }

        tokio::time::sleep(Duration::from_secs(2)).await;
    }

    assert!(
        status_ok,
        "openshell status never became healthy after 15 attempts (last status: {final_status})",
    );
}

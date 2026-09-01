// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Gateway reachability and health checks (ODH/RHOAI-specific).

use std::process::Stdio;
use std::time::Duration;

use openshell_e2e::harness::binary::openshell_cmd;
use openshell_e2e::harness::output::strip_ansi;

#[tokio::test]
async fn test_reachable() {
    let mut clean_status = String::new();
    let mut status_ok = false;
    for _ in 0..15 {
        let mut status_cmd = openshell_cmd();
        status_cmd
            .arg("status")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        let status_out = status_cmd
            .output()
            .await
            .expect("failed to run openshell status");

        let status_text = format!(
            "{}{}",
            String::from_utf8_lossy(&status_out.stdout),
            String::from_utf8_lossy(&status_out.stderr),
        );
        clean_status = strip_ansi(&status_text);

        if status_out.status.success() && clean_status.contains("Connected") {
            status_ok = true;
            break;
        }

        tokio::time::sleep(Duration::from_secs(2)).await;
    }

    assert!(
        status_ok,
        "openshell status never became healthy:\n{clean_status}",
    );
}

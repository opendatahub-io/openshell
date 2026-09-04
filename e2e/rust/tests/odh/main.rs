// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! ODH/RHOAI downstream integration tests.
//!
//! This binary is complementary to the upstream e2e suite: it exercises
//! behavior specific to running OpenShell on OpenShift with ODH/RHOAI
//! workloads. See TESTING-odh.md for tiering and how to run these tests.
//!
//! Test names include the full module path (e.g. `smoke::gateway::test_reachable`),
//! enabling tier-based filtering with `-- smoke::`, `-- tier1::`, etc.

#![cfg(feature = "e2e-odh")]

mod smoke;
mod tier1;
mod tier2;
mod tier3;

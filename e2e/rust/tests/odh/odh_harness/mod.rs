// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Fork-local shared helpers for ODH downstream e2e tests.
//!
//! Compiled into the single `odh` test binary and used as
//! `crate::odh_harness::...` from any tier module. Kept separate from the
//! upstream `openshell_e2e::harness` library so this fork-only code stays
//! rebase-safe against `NVIDIA/OpenShell`, and so `use` statements never
//! collide with the upstream `harness` module.

pub mod oc;
pub mod sandbox;
pub mod selinux;

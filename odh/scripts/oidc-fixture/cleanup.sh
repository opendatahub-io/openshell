#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Delete the resources this run created. Sourced by odh-oidc-fixture.sh with
# STATE_DIR set; expects the caller to have already sourced common.sh.

[[ -f "$(fixture_internal_state_path "${STATE_DIR}")" ]] \
	|| fixture_fail "no state.env in ${STATE_DIR}; nothing recorded for this run"
if ! fixture_delete_owned_resources "${STATE_DIR}"; then
	echo "ERROR: OIDC fixture cleanup failed for run ${OPENSHELL_E2E_RUN_ID}" >&2
	exit 1
fi
echo ">> OIDC fixture cleanup complete for run ${OPENSHELL_E2E_RUN_ID}"
exit 0

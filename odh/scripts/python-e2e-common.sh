#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Shared Python E2E interpreter and environment setup for the preflight and runner.

resolve_python_test_bin() {
	local root="$1" python_test_bin parent_dir
	if [[ -n "${OPENSHELL_E2E_PYTHON:-}" ]]; then
		python_test_bin="${OPENSHELL_E2E_PYTHON}"
		if [[ "${python_test_bin}" != */* ]]; then
			python_test_bin="$(command -v -- "${python_test_bin}" 2>/dev/null || true)"
		elif [[ "${python_test_bin}" != /* ]]; then
			parent_dir="$(cd -- "$(dirname -- "${python_test_bin}")" 2>/dev/null && pwd -P || true)"
			if [[ -n "${parent_dir}" ]]; then
				python_test_bin="${parent_dir}/$(basename -- "${python_test_bin}")"
			fi
		fi
	elif [[ -n "${UV_PROJECT_ENVIRONMENT:-}" ]]; then
		python_test_bin="${UV_PROJECT_ENVIRONMENT}/bin/python"
		[[ "${python_test_bin}" == /* ]] || python_test_bin="${root}/${python_test_bin}"
	else
		python_test_bin="${root}/.venv/bin/python"
	fi
	if [[ -z "${python_test_bin}" || ! -x "${python_test_bin}" ]]; then
		echo "ERROR: Python E2E interpreter not found (OPENSHELL_E2E_PYTHON=${OPENSHELL_E2E_PYTHON:-<unset>}, resolved='${python_test_bin:-<none>}')" >&2
		return 2
	fi
	printf '%s\n' "${python_test_bin}"
}

prepare_python_e2e_environment() {
	local root="$1" script_dir="$2"
	export PYTHONPATH="${root}/python:${script_dir}${PYTHONPATH:+:${PYTHONPATH}}"
	export OPENSHELL_ODH_PYTHON_GATES="${root}/odh/python-gates.toml"
}

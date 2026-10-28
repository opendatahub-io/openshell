#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=e2e/support/route-auth.sh
source "${ROOT}/e2e/support/route-auth.sh"

test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

# Simulate HTTP/2 success trailers and trailers-only authentication errors.
curl() {
  local authenticated=0 headers="" request=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --cert) authenticated=1; shift ;;
      --dump-header) headers=$2; shift ;;
      --data-binary) request=${2#@}; shift ;;
    esac
    shift
  done
  if [ "$(od -An -tx1 "${request}" | tr -d ' \n')" != "0000000000" ]; then
    echo "Invalid empty gRPC request frame" >&2
    return 1
  fi
  if [ "${authenticated}" = 1 ]; then
    [ "${auth_transport}" = 0 ] || return "${auth_transport}"
    printf 'HTTP/2 %s\r\ncontent-type: application/grpc\r\n\r\ngrpc-status: %s\r\n' \
      "${auth_http}" "${auth_grpc}" >"${headers}"
    printf '%s' "${auth_http}"
  else
    [ "${certless_transport}" = 0 ] || return "${certless_transport}"
    printf 'HTTP/2 %s\r\ncontent-type: application/grpc\r\nGrpc-Status: %s\r\n\r\n' \
      "${certless_http}" "${certless_grpc}" >"${headers}"
    printf '%s' "${certless_http}"
  fi
}

check() {
  local description=$1 expected=$2 actual=0
  if e2e_verify_route_mtls https://gateway.example "${test_dir}" >"${test_dir}/output" 2>&1; then
    actual=1
  fi
  if [ "${actual}" != "${expected}" ]; then
    echo "FAIL: ${description}" >&2
    cat "${test_dir}/output" >&2
    exit 1
  fi
  echo "PASS: ${description}"
}

auth_transport=0 auth_http=200 auth_grpc=0
certless_transport=0 certless_http=200 certless_grpc=16
check 'certificate authenticates; certless RPC is UNAUTHENTICATED' 1

certless_grpc=0
check 'rejects anonymous RPC success' 0
certless_grpc=7
check 'rejects PERMISSION_DENIED instead of UNAUTHENTICATED' 0
certless_grpc=""
check 'rejects missing gRPC status' 0
certless_grpc=16 certless_http=404
check 'rejects HTTP 404 even with an authentication status' 0
certless_http=200
for certless_transport in 6 28 35 56 60; do
  check "rejects certless transport failure ${certless_transport}" 0
done
certless_transport=0 auth_grpc=16
check 'rejects a certificate that fails authentication' 0
auth_grpc=0 auth_transport=60
check 'rejects authenticated server certificate verification failure' 0

echo 'All Route authentication checks passed.'

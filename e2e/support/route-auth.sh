#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Probe a protected unary RPC with an empty protobuf request. Curl records both
# HTTP/2 headers and trailers, including trailers-only authentication failures.
# Print HTTP:gRPC status; transport errors must never count as an auth rejection.
e2e_route_auth_probe() {
  local endpoint=$1 ca_file=$2 probe_dir=$3 method=$4
  shift 4
  local http_status grpc_status curl_status=0
  printf '\000\000\000\000\000' >"${probe_dir}/auth-request.bin"
  http_status="$(curl -q -sS --http2 --max-time 10 \
    --cacert "${ca_file}" \
    -H 'Content-Type: application/grpc' -H 'TE: trailers' \
    --data-binary "@${probe_dir}/auth-request.bin" \
    --dump-header "${probe_dir}/auth-response.headers" \
    --output /dev/null --write-out '%{http_code}' \
    "$@" "${endpoint%/}/${method#/}")" || curl_status=$?
  # Preserve transport exit codes so callers can distinguish retryable errors.
  if [[ "${curl_status}" != 0 ]]; then return "${curl_status}"; fi
  grpc_status="$(awk 'tolower($1) == "grpc-status:" {gsub("\r", "", $2); status = $2} END {print status}' \
    "${probe_dir}/auth-response.headers")"
  printf '%s:%s' "${http_status}" "${grpc_status}"
}

# TLS permits certificate-free supervisor bearer authentication. Check user
# authentication at the RPC boundary instead of requiring a TLS handshake abort.
e2e_verify_route_mtls() {
  local endpoint=$1 pki_dir=$2
  local authenticated_status certless_status
  if ! authenticated_status="$(e2e_route_auth_probe "${endpoint}" "${pki_dir}/ca.crt" "${pki_dir}" \
    openshell.v1.OpenShell/GetCurrentUser \
    --cert "${pki_dir}/client/tls.crt" --key "${pki_dir}/client/tls.key")"; then
    echo "ERROR: authenticated Route RPC failed at the transport layer" >&2
    return 1
  fi
  if [ "${authenticated_status}" != "200:0" ]; then
    echo "ERROR: authenticated Route RPC expected HTTP 200 / gRPC OK, got ${authenticated_status}" >&2
    return 1
  fi
  if ! certless_status="$(e2e_route_auth_probe "${endpoint}" "${pki_dir}/ca.crt" "${pki_dir}" \
    openshell.v1.OpenShell/GetCurrentUser)"; then
    echo "ERROR: certless Route RPC failed at the transport layer; cannot verify authentication" >&2
    return 1
  fi
  if [ "${certless_status}" != "200:16" ]; then
    echo "ERROR: certless Route RPC expected HTTP 200 / gRPC UNAUTHENTICATED, got ${certless_status}" >&2
    return 1
  fi
  echo "OK: Route RPC accepts the client certificate and rejects certless callers as UNAUTHENTICATED."
}

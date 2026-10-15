#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

if [[ "$#" -ne 2 ]]; then
	echo "Usage: $0 <output-directory> <server-hostname>" >&2
	exit 2
fi

output_dir="$1"
server_hostname="$2"
if [[ ! "${server_hostname}" =~ ^[A-Za-z0-9.-]+$ ]]; then
	echo "ERROR: invalid Keycloak server hostname" >&2
	exit 2
fi

mkdir -p "${output_dir}"
run_openssl() {
	local error_file="${output_dir}/openssl.err"
	if "$@" >/dev/null 2>"${error_file}"; then
		rm -f "${error_file}"
	else
		cat "${error_file}" >&2
		rm -f "${error_file}"
		return 1
	fi
}

run_openssl openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
	-keyout "${output_dir}/ca.key" -out "${output_dir}/keycloak-ca.crt" \
	-subj '/CN=OpenShell OIDC Fixture CA' \
	-addext 'basicConstraints=critical,CA:TRUE' \
	-addext 'keyUsage=critical,keyCertSign,cRLSign' \
	-addext 'subjectKeyIdentifier=hash'

# Keep the subject short: OpenShift Route hostnames belong in the SAN and may
# exceed OpenSSL's 64-byte CN limit.
run_openssl openssl req -newkey rsa:2048 -nodes \
	-keyout "${output_dir}/tls.key" -out "${output_dir}/tls.csr" \
	-subj '/CN=OpenShell OIDC Fixture Keycloak'

run_openssl openssl x509 -req -days 1 \
	-in "${output_dir}/tls.csr" \
	-CA "${output_dir}/keycloak-ca.crt" \
	-CAkey "${output_dir}/ca.key" \
	-CAcreateserial \
	-out "${output_dir}/tls.crt" \
	-extensions server_cert \
	-extfile <(printf '[server_cert]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\nsubjectAltName=DNS:%s\n' "${server_hostname}")

chmod 600 "${output_dir}/ca.key" "${output_dir}/tls.key"

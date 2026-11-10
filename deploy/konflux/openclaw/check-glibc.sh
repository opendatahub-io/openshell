#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

usage() {
  echo "Usage: check-glibc.sh <dir> [max=2.34]" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

dir=$1
max=${2:-2.34}

elf_count=0
offending=0

while IFS= read -r -d '' file; do
  magic=$(head -c4 "$file" | od -An -tx1)
  if [[ "$magic" != " 7f 45 4c 46" ]]; then
    continue
  fi
  elf_count=$((elf_count + 1))

  # grep returns 1 (no match) for a file with no GLIBC_* symbol versions at
  # all, e.g. a musl-linked .node/.so; under pipefail that would otherwise
  # abort the script here instead of falling through to the empty-need skip.
  need=$(grep -aoE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' "$file" | sed 's/^GLIBC_//' | sort -uV | tail -n1) || true
  if [[ -z "$need" ]]; then
    continue
  fi

  highest=$(printf '%s\n%s\n' "$max" "$need" | sort -V | tail -n1)
  if [[ "$highest" == "$need" && "$need" != "$max" ]]; then
    echo "check-glibc: ${file} needs GLIBC_${need} > ${max}"
    offending=$((offending + 1))
  fi
done < <(find "$dir" -type f \( -name '*.node' -o -name '*.so' -o -name '*.so.*' \) -print0)

if [[ ${offending} -gt 0 ]]; then
  exit 1
fi

echo "check-glibc: ok (${elf_count} ELF files, max ${max})"

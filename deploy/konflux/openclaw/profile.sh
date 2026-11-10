# shellcheck shell=sh

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# OpenClaw defaults for login shells (sandbox exec/connect). Sourced by
# openclaw-start and installed as /etc/profile.d/openclaw.sh.

case ":${PATH:-}:" in
  *:/usr/local/bin:*) ;;
  *) PATH="/usr/local/bin${PATH:+:${PATH}}"; export PATH ;;
esac

: "${TMPDIR:=/tmp}"; export TMPDIR
: "${OPENCLAW_NO_AUTO_UPDATE:=1}"; export OPENCLAW_NO_AUTO_UPDATE
: "${DO_NOT_TRACK:=1}"; export DO_NOT_TRACK
: "${OPENCLAW_DISABLE_BONJOUR:=1}"; export OPENCLAW_DISABLE_BONJOUR
: "${OPENCLAW_OFFLINE:=1}"; export OPENCLAW_OFFLINE

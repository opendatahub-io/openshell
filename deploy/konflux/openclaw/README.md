# OpenClaw reference harness image

`odh-openshell-sandbox-openclaw` runs the [OpenClaw](https://github.com/openclaw/openclaw) agent harness inside an OpenShell sandbox. It is built from `deploy/docker/Dockerfile.konflux.openclaw` and the files in this directory.

## Status

This image is an unsupported reference composition. It is published only on quay.io/opendatahub, it is not RHOAI product content, and it is not the default sandbox workload image. It targets midstream main 4f6b3ad8 (v0.1.2-rhaiv.8 plus 18 commits). Read [Verified vs not verified](#verified-vs-not-verified) before relying on it.

## What's inside

- Base: `registry.access.redhat.com/ubi9/nodejs-24-minimal:9.8`, pinned by digest (Node 24.19.0, npm 11.17.0), for amd64 and arm64.
- OpenClaw 2026.9.5, installed world-readable under `/usr/local/lib/openclaw`, plus `/usr/local/bin/openclaw` and the `openclaw-start` wrapper. The npm closure is the same one Red Hat's internal AIPCC agentic OpenClaw image uses; that image runs it on Node 26.
- User 1000:1000 (`sandbox`), `HOME=/sandbox`, `WORKDIR /`, no `/sandbox` directory, no ENTRYPOINT and no baked sandbox policy. OpenShell creates and owns the workspace.
- The `DEFAULT:PQ` system crypto policy, so Node's TLS 1.3 prefers X25519MLKEM768. `python3` is present as a dependency of `crypto-policies-scripts`.
- OpenClaw defaults `OPENCLAW_NO_AUTO_UPDATE=1`, `DO_NOT_TRACK=1`, `OPENCLAW_DISABLE_BONJOUR=1` and `OPENCLAW_OFFLINE=1`, set in the image env and again in `/etc/profile.d/openclaw.sh` for login shells. Inherited base env such as `APP_ROOT` or `NPM_RUN` is harmless.
- `TMPDIR=/tmp`, also set in both places. Without it, SQLite picks `/var/tmp`, which the sandbox filesystem policy does not grant, and OpenClaw fails with `unable to open database file`.
- Not included: git, gzip, ps, Chromium and chat-channel plugins.

## Build locally

`build-local.sh` fetches the npm and rpm closure with Hermeto, builds with `--network none`, restores `package.json` and `package-lock.json` after Hermeto rewrites them, and runs `smoke-test.sh`. The smoke test needs `openssl` on the host.

```shell
./deploy/konflux/build-local.sh openclaw
PLATFORM=linux/arm64 ./deploy/konflux/build-local.sh openclaw
```

`PLATFORM` accepts `linux/amd64`, `linux/x86_64`, `linux/arm64` and `linux/aarch64`.

Without a Hermeto install, put a `hermeto` shim on `PATH` that runs `uvx --from git+https://github.com/hermetoproject/hermeto.git hermeto "$@"`. Hosts whose EDR agent kills OpenClaw can't run this build (see [Known limitations](#known-limitations)).

## Run with OpenShell

Copy `model-provider-profile.yaml`, set `host` and `port` to your model Service, then lint and import it and create the provider:

```shell
openshell profile lint -f model-provider-profile.yaml
openshell profile import -f model-provider-profile.yaml --global
openshell provider create --name model --type openclaw-model --credential CUSTOM_API_KEY=<token>
```

Create an interactive sandbox. On first run, `openclaw-start` onboards OpenClaw from the environment and then opens the TUI:

```shell
openshell sandbox create --name openclaw \
  --from quay.io/opendatahub/odh-openshell-sandbox-openclaw@sha256:<digest> \
  --provider model \
  --env MODEL_BASE_URL=http://<svc>.<ns>.svc.cluster.local:8000/v1 \
  --env MODEL_ID=<model-id> \
  --tty -- openclaw-start
```

For headless use, onboard in a detached sandbox and run one-shot turns with `agent exec`:

```shell
openshell sandbox create --name openclaw \
  --from quay.io/opendatahub/odh-openshell-sandbox-openclaw@sha256:<digest> \
  --provider model \
  --env MODEL_BASE_URL=http://<svc>.<ns>.svc.cluster.local:8000/v1 \
  --env MODEL_ID=<model-id> \
  --detach -- bash -lc 'openclaw-start --version && exec sleep infinity'
openshell sandbox exec --name openclaw -- openclaw-start agent exec "Summarize README.md"
```

| Variable | Purpose |
| --- | --- |
| `MODEL_BASE_URL` | OpenAI-compatible base URL. It must use exactly the host and port from the provider profile. |
| `MODEL_ID` | Model name served at that URL. |
| `CUSTOM_API_KEY` | Injected by the provider as a placeholder. For an endpoint without auth, create the provider with `--credential CUSTOM_API_KEY=unused`; the provider also supplies the egress rule for the model endpoint. |
| `MODEL_MAX_TOKENS` | Optional output token limit for the model. Onboarding defaults to 4096. |
| `MODEL_CONTEXT_WINDOW` | Optional context window for the model. |
| `MODEL_REASONING` | Optional `true` or `false`. Onboarding defaults to `false`. |
| `OPENCLAW_*`, `DO_NOT_TRACK` | Update, telemetry, Bonjour and download defaults. Override them with `--env`. |

- `openclaw-start` onboards only when `~/.openclaw/openclaw.json` is missing. Delete that file and its `.bak` to onboard again. Deleting `~/.openclaw` resets all OpenClaw state.
- Start OpenClaw through `openclaw-start` or a login-shell exec. `sandbox exec --no-login-shell` skips the profile.d defaults.
- With no arguments, `openclaw-start` runs `openclaw tui --local`, which needs a TTY, so don't combine it with `--detach`. When the TUI exits, the sandbox is Completed. `openshell sandbox start openclaw` restarts it with its state intact.
- `MODEL_MAX_TOKENS`, `MODEL_CONTEXT_WINDOW` and `MODEL_REASONING` apply only at onboarding, like the other `MODEL_*` variables. For a reasoning model, set `MODEL_REASONING=true` and raise `MODEL_MAX_TOKENS` (for example to 32768), or the model can spend the default 4096 tokens thinking and OpenClaw reports `Agent couldn't generate a response`. To change them after onboarding, use `openclaw config set 'models.providers.openshell-model.models[0].maxTokens' <n>`.
- On every start, `openclaw-start` clears the setgid bit on directories under `~/.openclaw` and `~/.openclaw-worker`. The Kubernetes driver's pod `fsGroup` makes the workspace volume setgid, and OpenClaw rejects private directories that inherit the bit (`insecure permissions 2700`). Run OpenClaw through `openclaw-start` at least once per sandbox start so this repair happens.

## Policy

The attached provider profile is all the image needs: it allows `/usr/bin/node` to reach the model endpoint, and the default filesystem policy already covers `/usr` and `/etc`. Without the provider, add the model host:port yourself with `openshell policy update <sandbox> --add-endpoint <host>:<port>:read-write:rest:enforce --binary /usr/bin/node`, or every model request is denied. Add other egress per sandbox with `openshell policy update`. Don't bake `/etc/openshell/policy.yaml` into a derived image unless it is schema-valid. Exec tools in pty mode need `/dev/ptmx`, which the default Landlock set does not grant.

## Control UI

Best effort, not validated. Onboarding configures OpenClaw's gateway on loopback port 18789 with token auth. Run `openclaw-start gateway` as the sandbox command instead of the TUI, expose it with `openshell service expose openclaw 18789`, add the service URL's origin to `gateway.controlUi.allowedOrigins`, and approve the browser with `openclaw devices approve`.

## Known limitations

- OpenShell sandboxes need OCP 4.19 or later (Landlock ABI 3 or newer).
- On RHCOS 9 the sandbox runs in legacy read-only mode. OpenClaw's gateway then treats every client as remote, so the Control UI always needs device approval, and Python or Go servers in the sandbox fail at `accept()`. OpenClaw's embedded MCP loopback server should still work.
- EDR agents such as CrowdStrike Falcon may kill OpenClaw entirely, not only its sqlite workers. That includes image builds, where any step touching the OpenClaw package path can be killed. Build on sanctioned infrastructure without such a policy, such as Konflux, and run `smoke-test.sh` on a host or CI runner without it. Nodes running such an agent may kill OpenClaw inside sandboxes too.
- OpenClaw calls `os.userInfo()` unguarded in several paths. Onboarding, `agent exec` and the TUI work as a UID with no passwd entry; `status` and session commands under an SCC-assigned UID are unverified.
- `web_fetch` rejects OpenShell's synthetic DNS answers (198.18.0.0/15, fc00::/7) unless `tools.web.fetch.ssrfPolicy.allowRfc2544BenchmarkRange` and `tools.web.fetch.ssrfPolicy.allowIpv6UniqueLocalRange` are set, per OpenClaw's `docs/tools/web.md`. This is unverified.
- Updating the image never touches OpenClaw state on the sandbox's persistent volume.

## Verified vs not verified

Verified:

- [x] `build-local.sh openclaw` on GitHub-hosted Ubuntu 24.04 runners (podman 4.9.3), amd64 and native arm64: the hermetic build succeeds, and every `smoke-test.sh` check that existed then passes on both arches. That covers arch, config, labels, `openclaw --version`, layout, `DEFAULT:PQ` with Node negotiating X25519MLKEM768, first-run onboarding and its idempotence as UID 51234 with no passwd entry on a read-only rootfs, the login-shell env, and the missing-env exit. The later `setgid-home`, `model-overrides` and `tmpdir` checks, and the `TMPDIR` assertion in `login-shell`, have only run on linux/amd64 with podman 5.8.7.
- [x] Host unit tests for `openclaw-start` (with a fake OpenClaw CLI), `profile.sh` and `check-glibc.sh`.
- [x] `build-local.sh`: a stub trace shows the four existing components build unchanged, and the npm files are restored even when the build fails.
- [x] The glibc ceiling lint fails the build at 2.33 (`@openclaw/fs-safe-linux-x64-gnu` needs 2.34).
- [x] Trivy config scan of the Dockerfile is clean, and the license check adds only `rpms.lock.yaml`.
- [x] On kind (Kubernetes 1.37, rootless podman) with the midstream gateway and Kubernetes driver from the commit in [Status](#status), and a workspace volume that honors `fsGroup` (setgid `/sandbox`), running as UID 10001 with no passwd entry: `openshell profile lint` and import of the example profile, provider credential injection and egress through the profile alone, first-run onboarding, a headless `agent exec` turn and an interactive TUI turn against a llama.cpp model and against a stub reasoning model. The private agent directory is 0700 and no directory under `~/.openclaw` keeps setgid.

Not verified:

- [ ] OpenShift (SCC arbitrary UID, CSI-backed workspace volumes) and RHCOS 9 legacy mode.
- [ ] The Control UI.
- [ ] `os.userInfo()` in `status` and session commands without a passwd entry.

Once the component is onboarded, the Konflux PR pipeline is the first full build of this Dockerfile on both arches. It runs the in-build checks (the hermetic npm and rpm install, the OpenClaw version pin check, which only reads `package.json`, the glibc ceiling lint and the permissions check) plus Konflux's scans. It does not run `smoke-test.sh`, so after each OpenClaw or base bump, re-run `build-local.sh openclaw` on a host or CI runner without such an EDR policy, or add a Konflux IntegrationTestScenario that runs `smoke-test.sh` against the built image.

## Disconnected

Mirror the image by digest with oc-mirror, then point `MODEL_BASE_URL` at an in-cluster model server:

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  additionalImages:
    - name: quay.io/opendatahub/odh-openshell-sandbox-openclaw@sha256:<digest>
```

## Build your own on UBI

There is no branded OpenShell base image for RHOAI 3.6. To package another harness, start from stock UBI and keep the same contract:

```dockerfile
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.8@sha256:7fbeae18dc9476399f565e68255f602a3374ea8614ba3d14843565131a13ff93
USER 0
RUN microdnf install -y --nodocs shadow-utils <your-packages> && microdnf clean all && \
    groupadd -g 1000 sandbox && useradd -u 1000 -g 1000 -M -d /sandbox -s /bin/bash sandbox
COPY --chmod=0755 my-harness /usr/local/bin/my-harness
WORKDIR /
USER 1000:1000
```

- Use the registry.redhat.io digest your mirror carries if you don't pull from registry.access.redhat.com.
- Install tools world-readable under `/usr` or `/usr/local`, and put nothing under `/sandbox`, which OpenShell owns.
- Keep bash. OpenShell runs exec sessions through a bash login shell.
- Optionally install `crypto-policies-scripts` and run `update-crypto-policies --set DEFAULT:PQ`.
- Don't ship `/etc/openshell/policy.yaml` unless it is schema-valid.

## Updating OpenClaw

The npm inputs come from AIPCC agentic commit dc756bc3 (OpenClaw 2026.9.5). AIPCC has since moved to 2026.9.6, and a follow-up bump is expected.

1. Copy `package.json` and `package-lock.json` byte-identically from the AIPCC agentic repo (Red Hat internal), and record the source commit.
2. Review the version-pinned `allowScripts` entries in `package.json`.
3. Bump `ARG OPENCLAW_VERSION` at the top of the Dockerfile.
4. Leave the base alone: MintMaker (Renovate) bumps the `ARG NODEJS_IMAGE` digest through a regex manager in `renovate.json` and refreshes `rpms.lock.yaml`. It deliberately does not track the npm inputs, which follow AIPCC.
5. Rebuild both arches. The glibc lint fails the build if a native addon needs more than GLIBC 2.34, and x86_64 has no headroom today.

## Konflux

odh-konflux-central owns the Tekton pipelines. Its onboarder sync opens a PR here that copies `pipelineruns/openshell/odh-openshell-sandbox-openclaw-*.yaml` over `.tekton/`, so change their params there and run the sync. Merges to `main` publish `odh-stable`, and each `v*-rhaiv.*` tag rebuilds the same pinned OpenClaw release under that tag; only the commit named in [Status](#status) is verified. The build is hermetic for linux/x86_64 and linux/arm64 with this prefetch input:

```json
[{"type": "npm", "path": "deploy/konflux/openclaw"}, {"type": "rpm", "path": "deploy/konflux/openclaw"}]
```

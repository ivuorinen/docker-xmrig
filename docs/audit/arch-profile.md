# Architecture Profile

Detected by `/nitpicker arch-profile` on 2026-08-02, updated 2026-08-04 after
the audit fixes landed. Regenerate when the repository's shape changes;
`/nitpicker arch` audits against this document.

## Pattern

**Single-artifact container image repository.** There is no application source
here. The repository builds one artifact — `ivuorinen/docker-xmrig` — from
upstream XMRig, and ships reference manifests for consuming it.

| Layer | Files | Role |
| --- | --- | --- |
| Build | `Dockerfile`, `.dockerignore`, `.hadolint.yaml` | Two-stage build: compile upstream XMRig in a builder stage, copy the bare binary into a minimal runtime stage |
| Runtime config | `config.json` | The default config baked to `/etc/xmrig/config.json`; intended to be replaced by consumers |
| Deployment references | `deployment.yaml`, `docker-compose.yml`, the `docker run` recipe in `README.md` | Three independent consumers of the image contract |
| Pipeline | `.github/workflows/build.yaml` | `lint` → `verify` (gate) → `build` (per-platform, tags only) → `merge` (manifest list) → `update_description` |
| Licence surface | `LICENSE`, `NOTICE` | MIT packaging over a GPL-3.0 conveyed work |

## The load-bearing invariant

**The image contract is defined once, in the `Dockerfile`, and every consumer
must agree with it.** The contract is:

| Element | Defined by | Consumed by |
| --- | --- | --- |
| `/bin/xmrig` | runtime-stage `COPY --from=builder` | `CMD`, `README.md` layout table |
| `/etc/xmrig/config.json` | runtime-stage `COPY` + `CMD` | `deployment.yaml` configMap mount, `docker-compose.yml` bind mount, `README.md` |
| `/log`, owned by uid 10001 | runtime-stage `adduser` + `chown` | `deployment.yaml` emptyDir, `docker-compose.yml` bind mount |
| `:8080` HTTP API | `config.json` `http` block | `HEALTHCHECK`, `deployment.yaml` liveness + readiness probes |
| uid 10001, non-root | runtime-stage `adduser` + `USER` | `deployment.yaml` `runAsUser`/`fsGroup`, the `chown` in `README.md` |
| RandomX 2336 MiB floor | upstream RandomX, fixed | `memory` limits in all three deployment references |
| `.version` / `.licenses` labels | `LABEL` | pinned again in `build.yaml`, because buildx labels override `LABEL` |

File and line references are deliberately omitted: they drift on every edit, and
a stale pointer in this document is exactly the defect it exists to catch.

## Where this pattern fails

Every architectural defect found in this repository has had one shape: **a
consumer disagreeing with the contract, or two consumers disagreeing with each
other.** Historic instances, all now resolved:

- All three references capped memory at 2 GiB against a 2336 MiB requirement.
  The floor was written down nowhere, so all three got it wrong identically
  (`audit-4ed6f222`).
- `deployment.yaml` hardened the container; `docker-compose.yml` and the
  `docker run` recipe applied none of it — same image, three security postures
  (`audit-f40795a1`).
- `config.json` enabled `cpu.huge-pages` while `deployment.yaml` dropped the
  capability the README said it required (`audit-b00928bd`).
- Earlier still: the manifest pointed at `/xmrig/xmrig`, a path the image never
  had (`audit-bdf51ba5`), and the in-image `LICENSE` pointer resolved to the
  wrong licence (`audit-1fe51b16`).

## Current enforcement

The contract now has one executable check. `verify` in
`.github/workflows/build.yaml` starts the image with its own `CMD` and default
config, polls `/2/summary`, asserts restricted mode, and runs the `HEALTHCHECK`
command verbatim — pinning the `CMD`, the config, the `:8080` API and the
healthcheck in a single step, on both published platforms. The builder also
verifies the upstream commit SHA, so the source half of the contract is pinned
too.

What remains unenforced, and is therefore where the next drift will appear:

- **The memory floor.** Nothing fails if a manifest drops back below 2336 MiB;
  it is documentation and a comment. A conformance test would need to run the
  miner to the point of dataset allocation, which the smoke test deliberately
  does not do.
- **Cross-consumer parity.** No check compares `deployment.yaml`,
  `docker-compose.yml` and the README recipe against each other. Each is
  independently editable, and three of the four historic defects above were
  parity failures.
- **uid, paths and ownership.** Asserted by the image build, not by a test.

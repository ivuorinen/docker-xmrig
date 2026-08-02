# Architecture Profile

Detected by `/nitpicker arch-profile` on 2026-08-02. Regenerate when the
repository's shape changes; `/nitpicker arch` audits against this document.

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

| Element | Defined at | Consumed by |
| --- | --- | --- |
| `/bin/xmrig` | `Dockerfile:55` | `CMD`, `README.md` layout table |
| `/etc/xmrig/config.json` | `Dockerfile:56`, `:78` | `deployment.yaml` configMap mount, `docker-compose.yml` bind mount, `README.md` |
| `/log`, owned by uid 10001 | `Dockerfile:51-53` | `deployment.yaml` emptyDir, `docker-compose.yml` bind mount |
| `:8080` HTTP API | `config.json:22-28` | `Dockerfile` `HEALTHCHECK`, `deployment.yaml` liveness + readiness probes |
| uid 10001, non-root | `Dockerfile:51`, `:68` | `deployment.yaml` `runAsUser`/`fsGroup`, the `chown` instruction in `README.md` |
| `org.opencontainers.image.{version,licenses}` | `Dockerfile:43-44` | pinned again in `build.yaml:122-124` because buildx labels override `LABEL` |

There is no code path that enforces any of this. The contract is held together
by comments, and the three deployment references are free to drift from it and
from each other independently.

## Where this pattern fails, and does

Every architectural defect in this repository is one shape: **a consumer
disagreeing with the contract, or two consumers disagreeing with each other.**
Confirmed instances, all filed as findings:

- `deployment.yaml` hardens the container (`cap_drop`, read-only rootfs,
  `no-new-privileges`); `docker-compose.yml` and the `README.md` `docker run`
  recipe apply none of it — same image, three security postures.
- All three references cap memory at 2 GiB; the runtime needs 2336 MiB. The
  contract's memory floor is written down nowhere, so all three got it wrong the
  same way.
- `config.json` enables `cpu.huge-pages`; `deployment.yaml` drops the capability
  the `README.md` table says it requires.
- The `README.md` Logging command assumes the container name only the `docker
  run` path sets.

Historically the same shape produced the resolved findings `audit-bdf51ba5`
(manifest pointed at `/xmrig/xmrig`, a path the image never had) and
`audit-1fe51b16` (in-image `LICENSE` pointer resolved to the wrong licence).

## Architectural recommendation

The contract needs an executable definition, not a documented one. The cheapest
form is a CI assertion that runs the image as shipped and checks each element —
see finding `audit-49085f91`, which proposes exactly that for the `verify` job.
A smoke test that starts the default `CMD` and probes `:8080` pins four of the
six contract elements at once, and is the only thing in this repository that
could have caught the drift above before publication.

# Plan: Automated xmrig releases via Renovate

Date: 2026-11-23
Status: Approved 2026-11-23. Tasks 1–6 implemented and verified locally; Tasks 7–8 (PR CI, post-merge
observation) pending.

## Goal

Renovate detects new upstream `xmrig/xmrig` tags and alpine base-image digests and opens a PR for each. Once CI
proves the donation patch applies and the image builds and runs, Renovate merges the PR. The merge to `main` then
publishes `<xmrig version>-<YYYY-MM-DD>` and `latest` to Docker Hub with no manual step.

## Findings that shape the plan

Each one was verified during planning. Nothing below is assumed.

1. **Renovate has never tracked xmrig.** `Dockerfile:2` carries `# renovate: datasource=github-tags
    depName=xmrig/xmrig`, but no manager reads it. The shared preset (`github>ivuorinen/renovate-config`) defines
    two custom managers. Its Dockerfile manager matches only `ENV *_VERSION=… # datasource/dep` on a single line.
    The `# renovate:` syntax is wired for Makefiles only. Control: the Dependency Dashboard (issue #7) lists only
    `alpine` under detected dependencies, and no xmrig PR has ever been opened. The comment at `Dockerfile:11-14`
    ("Renovate bumps XMRIG_VERSION from the annotation above") is false.
2. **CI has been red since 2026-08-29.** Every Renovate PR (#46–#51) fails `verify → Scan image`. Trivy reports 5
    fixed HIGH CVEs in base packages: libcrypto3 3.5.7-r0 (fixed in 3.5.8-r0), musl, and zlib. Root cause: the preset
    sets `digest: {enabled: false}` and turns digest updates back on only for `github-actions`. So
    `alpine:3.24@sha256:28bd5f…` is frozen, while `alpine:3.24` is now `sha256:f59abe…`. The comment at
    `Dockerfile:21` ("Renovate bumps the digest") is false. Until the digest moves, no automated release can pass
    `verify`.
3. **Publishing is manual-tag only.** `build` runs only on `refs/tags/*`. The last publish was `6.22.2-2024-11-03`
    on 2024-11-03; `latest` points at the same digest. Upstream is at `v6.27.0`.
4. **The tag format already exists.** Git tags are `6.22.2-2024-11-03`, `6.21.2-2024-04-20`, and so on: the version
    without its `v`, then the UTC date. Docker Hub carries the same names plus `latest`.
5. **Upstream tags are lightweight.** `git ls-remote --tags` shows no `^{}` peeled entries, so a tag's ref SHA is
    the commit SHA that `git rev-parse HEAD` returns after `clone --branch`.
6. **Renovate can update the version and the commit pin together.** Checked in Renovate's source:
    - The `github-tags` datasource attaches each tag's commit hash as `newDigest` (`github-tags/index.ts:82-83`).
    - When a dependency has a `currentDigest`, lookup sets `newDigest` on every update (`lookup/index.ts:638-639`).
    - The preset's `digest` object applies only "when updating a digest (no change in tag/version)", so a version
      bump still rewrites `XMRIG_COMMIT`.
7. **Automerge safety in this repo.** `main` has no branch protection, and the `main` ruleset is `disabled`.
    - Renovate's docs: with the default `platformAutomerge: true` and no required checks, GitHub "might merge
      Renovate PRs even if the repository's tests have not started… or possibly even when they have failed".
    - With `platformAutomerge: false`, Renovate merges only when every check succeeded. It counts `skipped` and
      `neutral` as passing (`platform/github/index.ts:1316`), so the always-skipped `build`, `merge` and
      `update_description` jobs do not block it.
    - The preset automerges minor and patch with `automergeType: branch`. No workflow runs on a Renovate branch push,
      so that path never runs `verify` before merging.
8. **The patch can be checked at runtime.** `/2/summary` reports `donate_level`
    (`src/core/Miner.cpp:155` at v6.27.0).
    - `Pools::setDonateLevel` keeps the default whenever `level < kMinimumDonateLevel` (`Pools.cpp:220`).
    - So with `config.json`'s `"donate-level": 0`, an unpatched binary reports 1 and a patched one reports 0.
    - `donate.h` at v6.27.0 has the same two lines the `sed` patch targets.
9. **Release-age holds won't stall these updates.**
    - The preset sets `minimumReleaseAge: 3 days`.
    - `github-tags` supports release timestamps.
    - For Docker Hub, digests take the tag's `tag_last_pushed` timestamp.

## Decisions taken (user, 2026-11-23)

- Alpine digest PRs **automerge** once CI is green.
- A merge to `main` publishes when the **Dockerfile changed since the last release tag**. That covers xmrig bumps
  and base-image bumps.
- xmrig **majors automerge too**.

## Scope & constraints

Touches: `Dockerfile`, `.github/renovate.json`, `.github/workflows/build.yaml`, `README.md`,
`docs/audit/arch-profile.md`.

Must not change:

- The donation patch and its grep guards.
- The `XMRIG_COMMIT` rev-parse check.
- The OCI labels that NOTICE relies on (`version`, `licenses`, `source`, `revision`).
- The manual tag-push release path.
- The `--read-only --cap-drop ALL` smoke test.
- The shared preset repository. All overrides stay repo-local.

## Tasks

Work on a branch. Nothing is committed without an explicit instruction (user git rules).

1. **Make the pin block one adjacent unit.** Files: `Dockerfile:1-17`.
    - Move `ARG XMRIG_COMMIT` directly below `ARG XMRIG_VERSION`, with the comment block above both.
    - Delete the dead `# renovate:` annotation. Task 2 hardcodes the datasource and dependency name in the manager,
      so the Dockerfile and `renovate.json` would otherwise both carry them.
    - Rewrite the comment so it is accurate:
      - Renovate updates both lines through the custom manager in `.github/renovate.json`.
      - The rev-parse check now guards only against a tag moved after Renovate recorded its commit.
      - Remove the "red by construction / maintainer pastes the SHA" text.

    Verify:
    - `git diff -U0 Dockerfile` shows the ARG values unchanged (`v6.22.2`, `f9e990d0…`).
    - `hadolint Dockerfile` (2.15.1, with the repo's `.hadolint.yaml`) is clean.
    - `docker build -t xmrig:t1 .` succeeds.

2. **Add a repo-local Renovate manager, digest re-enable and automerge rules.** File: `.github/renovate.json`.
    - Custom regex manager:
      - `managerFilePatterns: ["/(^|/)Dockerfile$/"]`, `datasourceTemplate: "github-tags"`,
        `depNameTemplate: "xmrig/xmrig"`.
      - `matchStrings: ["ARG XMRIG_VERSION=\"(?<currentValue>[^\"]+)\"\\nARG XMRIG_COMMIT=\"(?<currentDigest>[0-9a-f]{40})\""]`.
      - The templates keep this line under the 120-column `.editorconfig` limit. Capturing the datasource and
        dependency name from the comment would make the string about 177 characters, and JSON has no string
        concatenation.
    - Rule A: `matchManagers: ["dockerfile"]`, `matchUpdateTypes: ["digest"]`, `enabled: true`, `automerge: true`.
    - Rule B: `matchPackageNames: ["xmrig/xmrig"]`, `automerge: true`. This covers every update type, majors
      included.
    - Rule C: `matchFileNames: ["Dockerfile"]`, `automergeType: "pr"`, `platformAutomerge: false`.
    - Each entry carries a `description` array giving its reason, following the preset's convention.
    - `customManagers` and `packageRules` are both `mergeable: true`, so these append to the preset rather than
      replacing it. Repo rules sort after preset rules, so they win.

    Verify:
    - `npx --yes --package renovate -- renovate-config-validator --strict .github/renovate.json` passes.
    - Run `GITHUB_COM_TOKEN="$(gh auth token)" LOG_LEVEL=debug npx --yes renovate --platform=local`. Its
      extracted-updates output must show:
      - `xmrig/xmrig` (custom.regex) with `currentValue v6.22.2` and `currentDigest f9e990d0…`.
      - An update to `v6.27.0` with `newDigest be97bc8f864fdd94b1c336c8ee62136578f0b080`, the SHA that
        `git ls-remote https://github.com/xmrig/xmrig.git refs/tags/v6.27.0` returns.
      - Observed during execution: the update offered is `v6.26.0` with `newDigest
        b2ca72480c58d197e18c885d9fc1a0c8d517e60a`, which matches `git ls-remote` for that tag. `v6.27.0` was
        published 2026-11-23T03:38Z and is listed in `pendingVersions`, held by the preset's 3-day
        `minimumReleaseAge`.
      - An `alpine` `digest` update whose `newDigest` equals what
        `docker buildx imagetools inspect alpine:3.24` reports.
      - Both updates resolved with `automerge: true`, `automergeType: pr` and `platformAutomerge: false`.
    - Before Task 1 (layout unchanged) the same run must show no `xmrig/xmrig` dependency. That is the negative
      control proving the regex is what made the difference.

3. **Assert the patch in the shipped binary.** File: `.github/workflows/build.yaml`, step "Smoke test the image as
    shipped".
    - After the restricted-mode check, add `jq -e '.donate_level == 0' /tmp/summary.json`.
    - On failure, emit `::error::donate_level is not 0 — the donate.h patch did not take effect` and dump the JSON.
    - A missing field gives `null == 0` → false → exit 1. It fails closed.

    Verify:
    - `actionlint` (1.7.12, same as CI) is clean.
    - Positive control: build an image from a scratchpad copy of the Dockerfile with the donate `RUN` removed. Run
      it with `--read-only --cap-drop ALL --security-opt no-new-privileges`. `/2/summary` must report
      `donate_level: 1` and the `jq -e` command must exit 1.
    - Real image: the same run reports 0 and the command exits 0.
    - Forecast for the first Renovate PR: build the real Dockerfile with `--build-arg XMRIG_VERSION=v6.27.0
      --build-arg XMRIG_COMMIT=be97bc8f864fdd94b1c336c8ee62136578f0b080`. Then:
      - `xmrig --version` reports `6.27.0`.
      - The image serves `/2/summary` with `donate_level` 0.

4. **Publish from `main` when the Dockerfile changed since the last release.** File:
    `.github/workflows/build.yaml`.
    - New job `release` (ubuntu-latest, timeout 5): checkout with `fetch-depth: 0` and
      `persist-credentials: false`, then a step `decide` that writes `publish`, `tag` and `create_tag` outputs:
      - `refs/tags/*` → `publish=true`, `tag=$GITHUB_REF_NAME`, `create_tag=false`. The manual path is unchanged.
      - `refs/heads/main` (push or `workflow_dispatch`):
        - `last=$(git describe --tags --abbrev=0 --match '[0-9]*-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*' HEAD)`.
        - If `git diff --quiet "$last" HEAD -- Dockerfile`, emit `::notice::no release: Dockerfile unchanged since
          $last`.
        - Otherwise set `tag=<XMRIG_VERSION without v>-$(date -u +%F)`. If that git tag already exists, append `.2`,
          `.3`, and so on until it is free. Set `publish=true` and `create_tag=true`, and emit
          `::notice::publishing $tag`.
      - Any other ref → `publish=false`.
      - Any git failure fails the job. It never falls through to "publish".
    - `build`: `needs: [verify, release]`, `if: needs.release.outputs.publish == 'true'`. This replaces
      `startsWith(github.ref, 'refs/tags/')`.
    - `merge`: `needs: [build, release]`. metadata-action gets `tags: type=raw,value=${{ needs.release.outputs.tag }}`
      and `flavor: latest=true`. These explicit tags also stop a `:main` tag being pushed. "Inspect image" reads
      `needs.release.outputs.tag`.
    - New job `tag`: `needs: [release, merge]`, `if: needs.release.outputs.create_tag == 'true'`.
      - `permissions: contents: write` is set on this job only; it holds no Docker Hub secrets.
      - Step: `gh api "repos/${GITHUB_REPOSITORY}/git/refs" -f ref="refs/tags/${TAG}" -f sha="${GITHUB_SHA}"`, with
        `TAG` and `GH_TOKEN` passed via `env:`, not inline `${{ }}`.
      - The tag is pushed with `GITHUB_TOKEN`, so it does not start a second workflow run. That is intended: the
        image is already published.
    - `update_description`: drop the `if:`. Its implicit `success()` on `needs: merge` already gates it.
    - `concurrency.cancel-in-progress: ${{ github.event_name == 'pull_request' }}`. A `main` run in progress
      finishes its release instead of being cancelled by the next merge. Queued `main` runs still collapse to the
      newest.
    - Comments for each new job explain why, in the file's existing style.

    Verify:
    - `actionlint` is clean.
    - Extract the real step with `yq -r '.jobs.release.steps[] | select(.id == "decide") | .run'
      .github/workflows/build.yaml` and run it in a scratchpad `git clone --no-local` with a scratch `GITHUB_OUTPUT`.
      Expected results:
      - (a) HEAD = current `main`: `publish=true`, `tag=6.22.2-<today>`, `create_tag=true`.
      - (b) HEAD = the `6.22.2-2024-11-03` commit: `publish=false`.
      - (c) A local tag `6.22.2-<today>` exists and the Dockerfile changed after it: `tag=6.22.2-<today>.2`.
      - (d) `GITHUB_REF=refs/tags/X`: `publish=true`, `tag=X`, `create_tag=false`.
      - (e) `GITHUB_REF=refs/pull/1/merge`: `publish=false`.

5. **Unblock CI: move the alpine digest.** File: `Dockerfile:25`.
    - Set the `FROM` digest to the exact `newDigest` that Renovate reported for alpine in Task 2.
    - Order matters: Task 2's alpine check needs the stale digest still in place.
    - This is a one-off. Afterwards Rule A keeps the digest moving.

    Verify:
    - `docker build -t xmrig:t5 .`.
    - `trivy image --exit-code 1 --ignore-unfixed --severity CRITICAL,HIGH xmrig:t5` (0.76.1) exits 0.

6. **Update the docs.** Files: `README.md`, `docs/audit/arch-profile.md`.
    - README: new `## Releases` section before `## Disclaimer`, stating:
      - The tag scheme: `<xmrig version>-<YYYY-MM-DD>`, with `.N` on a same-day re-release.
      - Images publish automatically when Renovate merges an xmrig or base-image update.
      - `latest` follows every publish, **including xmrig major versions**, which is why line 147 recommends
        pinning.
      - A manual git tag push still publishes.
    - arch-profile: in the Pipeline row (line 18), change "build (per-platform, tags only)" to the new shape:
      `lint` → `verify`, `release` (decide) → `build` → `merge` → `tag` and `update_description`.

    Verify: `rg -n 'tags only|red by construction|does NOT touch this line|pastes it here|from the annotation above'
    Dockerfile README.md docs/audit/arch-profile.md .github` returns nothing.

7. **Full lint gate, then open the PR.**
    - Run `hadolint Dockerfile`, `actionlint`, `renovate-config-validator --strict`, and `docker compose -f
      docker-compose.yml config --quiet`.
    - Check `.editorconfig` compliance (120 columns, LF, final newline) on every touched non-`.md` file.
    - Fix everything until there are zero problems.
    - Push the branch and open a PR. This needs the user's instruction.

    Verify: the PR's `lint` and both `verify` legs are green, with Trivy passing and the new `donate_level` assertion
    running on amd64 and arm64.

8. **Rollout observation, after merge. Report what is observed; nothing is predicted.**
    - The merge commit's run: `release` reports `publishing 6.22.2-<date>`, because the Dockerfile changed since
      `6.22.2-2024-11-03`. Then:
      - Docker Hub shows `6.22.2-<date>` and `latest` on the same digest.
      - Git tag `6.22.2-<date>` exists at the merge commit.
      - `docker run --rm ivuorinen/docker-xmrig:latest /bin/xmrig --version` reports 6.22.2.
    - The Dependency Dashboard lists `xmrig/xmrig v6.22.2` under a `regex` section.
    - On Renovate's next non-office-hours run, a PR updates both `XMRIG_VERSION` to `v6.26.0` and `XMRIG_COMMIT` to
      `b2ca7248…` (see Task 2's observed result). If CI goes green, Renovate merges it and `6.26.0-<date>` is
      published.
    - From 2026-11-26, when `v6.27.0` clears `minimumReleaseAge`, a PR to `v6.27.0` / `be97bc8f…` follows the same
      path, or the open `v6.26.0` PR is updated to it.
    - If an open action PR (#46–#51) merges after that, its run reports `no release: Dockerfile unchanged`.

## Adversarial hardening

- **complexity**
  - Examined how to trigger the publish:
    - Pushing a git tag from a workflow does not trigger another workflow when it uses `GITHUB_TOKEN`. Chaining
      runs that way would need a PAT or GitHub App secret.
    - Cut: publishing happens in the same run, and the git tag is only a record.
  - Examined how to detect "needs a release". Cut:
    - `dorny/paths-filter` (a new third-party action).
    - Querying the Docker Hub API (external state).
    - A cron schedule.
    - `git diff` against the last release tag needs none of them.
  - Examined Renovate's built-in `customManagers:dockerfileVersions` preset. Rejected: it captures `currentValue`
    only, so `XMRIG_COMMIT` would go stale and every bump PR would be red, as today.
  - Examined editing the shared preset. Rejected: it changes other repos. A repo-local override is enough.
  - Examined the path list for "image changed". Limited to `Dockerfile`. Listing `config.json`, `NOTICE` and
    `LICENSE` would be a second list that has to track the `COPY` lines.
  - Removed the duplicated `# renovate:` annotation (Task 1).
  - Kept a separate `tag` job: `merge` holds the Docker Hub token and should not also get `contents: write`.
- **review**
  - Examined same-day collisions. Renovate often merges an xmrig bump and an alpine digest the same night, which
    would mean the same `<ver>-<date>` twice. Added the `.N` suffix (Task 4c) so published tags stay immutable;
    README line 147 tells users to pin them.
  - Examined first-run behaviour. Merging this change publishes `6.22.2-<date>` with the new base; this is stated
    in Task 8.
  - Examined `workflow_dispatch` on `main`. It now re-evaluates and can publish, which serves as the retry path.
  - Examined a run that spans midnight UTC. The tag, date included, is computed once in `release` and read by
    both `merge` and `tag`; the matrix legs push by digest and never see it.
- **security**
  - Trust boundary moved: upstream xmrig code now reaches the published image, majors included, without human
    review (user decision). What remains:
    - `minimumReleaseAge` holds a new tag for 3 days.
    - Renovate records the tag's commit at lookup time.
    - The build's rev-parse check fails if the tag moves after that.
  - `pull_request` runs, forks included, get `publish=false`, and `build` needs `publish=true`. Docker Hub
    secrets stay out of PR runs, as before.
  - `contents: write` is scoped to the `tag` job only.
  - The tag value (derived from Dockerfile text) reaches shell via `env:`, not `${{ }}` interpolation.
  - `platformAutomerge: false` prevents GitHub merging before CI with no branch protection (Finding 7).
- **errors / leaks**
  - Failure path of each new operation:
    - A `git describe` or `git diff` error fails `release`, so `build` is skipped. Fails closed, and loudly.
    - A missing `donate_level` fails `verify`.
    - A failed `tag` job after publishing turns the run red. The next Dockerfile change publishes again under a new
      date. Accepted below.
    - A red `verify` on `main` publishes nothing. The next push re-evaluates, because "changed since last tag" is
      still true. Self-healing.
  - Leaks: the only resource acquired is the smoke-test container, already released by the existing
    `trap … EXIT`. No new resources.
- **migrations**: N/A. No schema or data store. Release state lives in git tags, and the rollback below covers
  them.
- **concurrency**
  - Examined the `main` concurrency group. With `cancel-in-progress: true`, a merge landing during a release would
    cancel it after per-platform digests were pushed but before the manifest or tag. Changed to cancel only PR runs
    (Task 4).
  - Examined a manual tag push running in parallel with an automatic release. The two tag names differ; `latest` is
    last-writer-wins. Accepted.
- **contract**
  - The public surface is the Docker Hub tags.
  - Unchanged: the format.
  - New:
    - Tags appear without a maintainer.
    - A `.N` suffix on same-day re-releases.
    - `latest` moves to automerged majors, which deployment.yaml and compose consume. Documented in the README
      (Task 6).
  - No more `:main` tag pushes. The 2024 `:main` tag stays on Docker Hub untouched.
  - No version bump applies: the repo has no semver of its own.
- **arch**
  - Examined the pipeline shape `lint → verify → build → merge → update_description`.
  - Added two jobs:
    - A decision job that runs in parallel with `verify`.
    - A privileged tail job.
  - Matches the existing per-job split.
  - `arch-profile.md` is updated (Task 6).
- **perf**
  - GHA caches from PR branches are not readable on `main`, so the merge run recompiles once per platform. `build`
    still reuses `verify`'s cache within the run. This already happens on tag pushes. One extra compile per
    release is accepted.
  - No per-item or unbounded work.
- **tests**
  - Every verification has a control:
    - The Renovate lookup is checked against the SHA from `git ls-remote`, with a negative run on the old layout.
    - `donate_level` is checked against an unpatched image.
    - The `decide` script is tested on the real text extracted with `yq`, across five refs and states.
    - Rollout is checked by observing Docker Hub and git.
  - The critical path (Renovate PR → green → merge → publish) is exercised end to end by Task 8.
- **observability**
  - Examined "why did/didn't it publish". `release` emits a `::notice::` naming the decision and the last release
    tag.
  - Renovate's PR and the run page are the audit trail.
- **config**
  - No new secrets: `GITHUB_TOKEN` and the existing `DOCKERHUB_*`.
  - Repo settings are unchanged. `allow_auto_merge` is not relied on, because `platformAutomerge: false`.
- **privacy / a11y / i18n**: N/A. No personal data, UI or locale in this change.
- **docs**: three false statements are corrected:
  - `Dockerfile:11-14` (Task 1).
  - `Dockerfile:21` becomes true through Rule A.
  - arch-profile line 18 (Task 6).

## Rollback / abort

- **Stop automation without reverting:**
  - Add `"enabled": false` to Rule C in `.github/renovate.json`. It matches every Dockerfile update: xmrig, the
    alpine digest, and an alpine version bump, which the preset automerges as minor. Rules A and B each cover
    only their own updates, so with Rule B alone disabled, alpine PRs still automerge and every merge publishes
    (raised in review on #52). A local Renovate run with Rule C disabled reports both `alpine` and `xmrig/xmrig`
    as `skipReason: disabled`, with GitHub Actions updates unaffected.
  - Or `gh workflow disable "Build and release"`.
- **Bad automated release:**
  1. `git revert` the Renovate commit on `main`. If the bad release has its git tag, the reverted Dockerfile
      differs from that tag, so the revert's run publishes the previous version under today's date and moves
      `latest` back. If its `tag` job failed, the reverted Dockerfile matches the last git tag, the run's `release`
      job reports `no release`, and `latest` stays on the bad image (raised in review on #52).
  2. Add `allowedVersions` (for example `"<7"`) to Rule B so Renovate does not reopen the bad version.
  3. Read the revert run's `release` notice. If it says `no release`, or to re-point `latest` without waiting for
      the run, run
      `docker buildx imagetools create -t ivuorinen/docker-xmrig:latest ivuorinen/docker-xmrig:<previous good tag>`.
- **Revert this whole change:** revert the PR. Publishing returns to tag-push only and Renovate stops tracking
  xmrig.
  - Images and git tags already published remain.
  - Delete a git tag with `git push --delete origin <tag>`.
  - Delete a Docker Hub tag in the Hub UI.

## Open questions & accepted risks

- **Same-day suffix form `.2`:** an assumption. Published tags stay immutable; the alternative was overwriting
  `<ver>-<date>` (a mutable tag, which contradicts README line 147). Confirm or name another form.
- **Automerged majors move `latest`.** Accepted by user decision. Deployments on `:latest` get them without review;
  the README says so.
- **Upstream compromise** reaches Docker Hub roughly 3 days after the malicious tag (the `minimumReleaseAge`
  window), with no human in between. Accepted as a consequence of full automation.
- **Docker Hub digest timestamps** come from `tag_last_pushed` (renovatebot/renovate#38659). If `alpine:3.24` were
  re-pushed more often than every 3 days, its digest update would never age in. Accepted: alpine re-pushes are far
  rarer than that.
- **Changes only to `config.json`, `NOTICE` or `LICENSE`** do not auto-publish. They ship with the next Dockerfile
  change or a manual tag push. Accepted to avoid a path list coupled to the `COPY` lines.
- **A `tag` job failure after publishing** leaves an untagged release, so the next push to `main` publishes again.
  `release` checks Docker Hub as well as git tags when it picks a name, so that image gets a `.N` name instead of
  overwriting the untagged one (raised in review on #52). The result is one redundant image, and the red run flags
  it. Accepted.
- **No required status checks on `main`.** `platformAutomerge: false` makes Renovate itself check that CI is
  green. Enabling the disabled `main` ruleset with required checks would be defence in depth. It is not part of
  this plan (a repo setting, the user's call).
- **The first xmrig PR jumps four minors** (v6.22.2 → v6.26.0), and v6.27.0 follows. Task 3's forecast build
  covered v6.27.0 only; v6.26.0 was not built locally, so its PR's CI is the first build of it. If upstream broke
  something, the PR stays open and red until someone fixes it.
- **Hosted Renovate version:** Mend's hosted Renovate may run a different version than the local `npx renovate`
  used in Task 2. The `currentDigest` replacement this plan relies on is long-standing behaviour.

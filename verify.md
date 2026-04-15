# feat/infra Verification Checklist

Everything needed to verify the `feat/infra` PR works end-to-end before
merging to the real `Sparticuz/chromium` repo.

> **Test remote:** `Sparticuz/ch2` — all verification happens there first.

---

## Table of Contents

1. [Pre-merge prerequisites](#1-pre-merge-prerequisites)
2. [Workflow chain: Chromium update → Release](#2-workflow-chain-chromium-update--release)
3. [Workflow chain: Non-build PR](#3-workflow-chain-non-build-pr)
4. [Safety nets & failure modes](#4-safety-nets--failure-modes)
5. [Manual / workflow_dispatch flows](#5-manual--workflow_dispatch-flows)
6. [Source code changes](#6-source-code-changes)
7. [Repo hygiene](#7-repo-hygiene)
8. [Post-merge verification on real repo](#8-post-merge-verification-on-real-repo)

---

## 1. Pre-merge prerequisites

These must be true before any workflow testing begins.

- [ ] **Secrets configured** on the test repo (`Sparticuz/ch2`):
  - `AWS_ACCESS_KEY_ID`
  - `AWS_SECRET_ACCESS_KEY`
  - `CHROMIUM_BUILD_S3_BUCKET`
  - `NPM_PUBLISH_TOKEN` (can be a dummy for ch2)
  - `RELEASE_TOKEN` (PAT with `contents:write` + `repo` scope — needed for
    `repository_dispatch` from EC2 and tag push from `prepare-release`)
- [ ] **GitHub Environment** `chromium-build` created on ch2 with required
      reviewers (you) for the manual approval gate.
- [ ] **Labels** exist on ch2:
  - `binaries:building`
  - `binaries:available`
  - `binaries:failed`
  - `chromium-update`
- [ ] **S3 bucket** exists and is accessible with the configured AWS creds.
      Verify: `aws s3 ls s3://$BUCKET/` succeeds.
- [ ] **IAM instance profile** `chromium-build` exists with S3 read/write
      permissions. Verify:
      `aws iam get-instance-profile --instance-profile-name chromium-build`
      (See `_/ec2/README.md` for the required IAM policy.)
- [ ] **Default branch** on ch2 is `master`.
- [ ] **`feat/infra` branch** is up to date on ch2:
      `git log --oneline ch2/feat/infra -5` shows the latest commits.

---

## 2. Workflow chain: Chromium update → Release

This is the full happy-path pipeline. Each step depends on the previous one.

### 2.1 — check-chromium-update.yml

**Goal:** Detect a new Chromium stable release and open a PR.

- [ ] Trigger manually: Actions → "Check Chromium Update" → Run workflow
      (select `feat/infra` branch).
- [ ] Verify: The workflow reads the current revision from
      `_/ec2/revision.txt`.
- [ ] Verify: It queries
      `https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json`
      for the latest stable revision.
- [ ] **If revision matches** — workflow exits cleanly, no PR created.
- [ ] **If revision differs** — verify:
  - [ ] `tools/update-browser-revision.mjs` runs and writes the new revision
        to `_/ec2/revision.txt`.
  - [ ] A PR is created on branch `chore/chromium-update-{revision}`.
  - [ ] The PR has the `chromium-update` label.
  - [ ] The PR body contains previous revision, new revision, and Chrome version.

**To force a new revision for testing:** Temporarily edit `_/ec2/revision.txt`
to `1` (an old value), push, then run the workflow. It should detect the
current stable as "new" and open a PR.

### 2.2 — check-pr-binaries.yml (auto-triggered by PR)

**Goal:** Set `binaries:building` label because `revision.txt` changed.

- [ ] Verify: The workflow runs on `pull_request: [opened, synchronize, reopened]`.
- [ ] Verify: It detects that `_/ec2/revision.txt` is in the changed files
      list via `gh api repos/.../pulls/{pr}/files`.
- [ ] Verify: It removes any existing `binaries:*` labels that aren't
      `binaries:building`.
- [ ] Verify: It adds the `binaries:building` label.

### 2.3 — build-chromium.yml (triggered by label)

**Goal:** Launch an EC2 instance to compile Chromium, then exit immediately.

- [ ] Verify: The workflow triggers on `pull_request: [labeled]` where
      `label.name == 'binaries:building'`.
- [ ] Verify: The `chromium-build` environment approval gate fires — you must
      manually approve before the job proceeds.
- [ ] Verify: It reads the revision from `_/ec2/revision.txt`.
- [ ] Verify: It packages the `_/ec2/` directory as `tar czf`, base64-encodes
      it, and embeds it in a bootstrap shell script with env vars
      (`CHROMIUM_REVISION`, `S3_BUCKET`, `GITHUB_PAT`, `GITHUB_REPO`,
      `PR_NUMBER`, `AWS_DEFAULT_REGION`).
- [ ] Verify: User-data size is printed and validated < 16 KB.
- [ ] Verify: It finds the default VPC and subnet.
- [ ] Verify: It creates (or reuses) a `chromium-build` security group
      (egress-only, no SSH).
- [ ] Verify: It fetches the latest AL2023 x86_64 AMI via SSM parameter.
- [ ] Verify: A `pending.json` is uploaded to
      `s3://{bucket}/{revision}/pending.json` with `deadline` set 8 hours ahead,
      `pr_number`, `repository`, and `started_at` fields.
- [ ] Verify: It launches a `c8id.8xlarge` EC2 instance with:
  - `instance_initiated_shutdown_behavior: terminate`
  - `--user-data file:///tmp/userdata.sh` (the bootstrap script)
  - `--iam-instance-profile Name=chromium-build`
  - Tags: `Name=chromium-build`, `Revision={rev}`, `PR={number}`
- [ ] Verify: It waits for the instance to reach `running` state.
- [ ] Verify: It updates `pending.json` with the `instance_id`.
- [ ] Verify: A PR comment is posted with revision, instance ID, S3 location,
      instance type, and deadline.
- [ ] Verify: The GHA job completes in < 5 minutes (fire-and-forget).

**If the workflow itself fails** (not the EC2 build):

- [ ] Verify: The `Emergency teardown (on failure)` step runs with
      `if: failure()`.
- [ ] Verify: It terminates the instance by ID (if known).
- [ ] Verify: It terminates any instances with tag `Name=chromium-build`
      in `running` or `pending` state as a fallback.

### 2.4 — EC2 build (runs autonomously on the instance)

**Goal:** Build Chromium for x64 and arm64, upload to S3, notify GitHub.

This runs on the EC2 instance via user-data, not in GitHub Actions. The
instance has no SSH access — verify by checking S3 and the dispatch event.

#### 2.4a — Orchestrator (`build-chromium.sh`)

- [ ] Verify: First action is `shutdown -h +480` (8-hour self-destruct timer).
- [ ] Verify: Logging goes to `/var/log/chromium-build.log` via `tee`.
- [ ] Verify: All 6 required env vars are validated (exits on empty).
- [ ] Verify: `PR_NUMBER` is validated as numeric.
- [ ] Verify: `notify_failure` helper is defined — appends failure event to
      `build.json` with `status: "failed"`, scrubs `GITHUB_PAT` from log,
      uploads log to S3, sends `repository_dispatch` with failure status, then
      shuts down.
- [ ] Verify: ERR trap calls `notify_failure` with line number on any error.
- [ ] Verify: It sources `setup.sh`, `build-x64.sh`, `build-arm64.sh`,
      `teardown.sh` in order.

#### 2.4b — Setup (`setup.sh`)

- [ ] Verify: NVMe instance store (`/dev/nvme1n1`) is formatted and mounted
      at `/srv`.
- [ ] Verify: 16 GB swap file created on NVMe at `/srv/swapfile`.
- [ ] Verify: `sysctl -w vm.max_map_count=262144` set (critical for ThinLTO).
- [ ] Verify: `dnf` installs required build dependencies.
- [ ] Verify: `depot_tools` cloned and **prepended** to `PATH`.
- [ ] Verify: `.gclient` copied from `$SCRIPT_DIR/.gclient`.
- [ ] Verify: Revision number resolved to git SHA via `cr-rev.appspot.com`.
- [ ] Verify: `gclient sync` runs with `--revision {SHA}`.
- [ ] Verify: Two patches applied via sed scripts:
  - `patches/sandbox-ipc-failed-polls.sed` on `sandbox_ipc_linux.cc`
  - `patches/render-process-host-check.sed` on `render_process_host_impl.cc`
- [ ] Verify: Each patch verified with `grep -q` — calls `notify_failure` on
      mismatch.
- [ ] Verify: `CHROME_VERSION` extracted from `chrome/VERSION`.

#### 2.4c — Build x64 (`build-x64.sh`)

- [ ] Verify: GN args copied from `args-x64.gn` (static file, not inlined).
- [ ] Verify: `gn gen out/Headless/x64` and `autoninja` run.
- [ ] Verify: Binary stripped with native `strip` (not cross-strip).
- [ ] Verify: Binary brotli-compressed.
- [ ] Verify: SwiftShader libs archived as `swiftshader.tar` and brotli'd.
- [ ] Verify: AL2023 x64 system libs packaged as `al2023.tar.br` with
      correct `--transform` for `libexpat.so.1` symlink.
- [ ] Verify: Artifacts uploaded to `s3://{bucket}/{revision}/x64/`:
  - `chromium-{version}.br`
  - `swiftshader.tar.br`
  - `al2023.tar.br`
- [ ] Verify: Build artifacts cleaned up after upload (avoids arm64 collision).

#### 2.4d — Build arm64 (`build-arm64.sh`)

- [ ] Verify: arm64 sysroot installed via
      `build/linux/sysroot_scripts/install-sysroot.py --arch=arm64`.
- [ ] Verify: GN args copied from `args-arm64.gn` (has `target_cpu="arm64"`).
- [ ] Verify: Cross-compilation via `autoninja -C out/Headless/arm64`.
- [ ] Verify: Binary stripped with Chromium's bundled `llvm-strip` at
      `third_party/llvm-build/Release+Asserts/bin/llvm-strip` (not Linaro GCC).
- [ ] Verify: Artifacts uploaded to `s3://{bucket}/{revision}/arm64/`:
  - `chromium-{version}.br`
  - `swiftshader.tar.br`
- [ ] Verify: No AL2023 libs for arm64 (built separately on native ARM).

#### 2.4e — Teardown (`teardown.sh`)

- [ ] Verify: Fonts uploaded to `s3://{bucket}/{revision}/fonts.tar.br`
      (if present).
- [ ] Verify: `GITHUB_PAT` scrubbed from build log before upload.
- [ ] Verify: Build log uploaded to `s3://{bucket}/{revision}/build.log`.
- [ ] Verify: `build.json` updated with final success event and top-level
      `status: "success"` and `chrome_version`.
- [ ] Verify: `pending.json` removed from S3.
- [ ] Verify: `repository_dispatch` event sent with type `build-complete`
      and payload `{ revision, pr_number, status: "success" }`.
- [ ] Verify: 8-hour timer cancelled and immediate shutdown triggered.

#### 2.4f — Verify final S3 structure

```
s3://{bucket}/{revision}/
  x64/
    chromium-{version}.br
    swiftshader.tar.br
    al2023.tar.br
  arm64/
    chromium-{version}.br
    swiftshader.tar.br
  fonts.tar.br            (if fonts were built)
  build.log
  build.json              ← status: success, events timeline
```

### 2.5 — build-complete.yml (triggered by repository_dispatch)

**Goal:** Swap label to `binaries:available` and comment on PR.

- [ ] Verify: The workflow triggers on `repository_dispatch: [build-complete]`.
- [ ] Verify: It parses `revision`, `pr_number`, and `status` from
      `client_payload`.
- [ ] **On success (`status == 'success'`):**
  - [ ] Removes `binaries:building` label from the PR.
  - [ ] Adds `binaries:available` label.
  - [ ] Posts a PR comment with S3 paths for x64, arm64, and build log.
- [ ] **On failure (`status != 'success'`):**
  - [ ] Removes `binaries:building` label.
  - [ ] Adds `binaries:failed` label.
  - [ ] Posts a PR comment with error from `client_payload.error`, build log
        S3 path, and retry instructions.
- [ ] Verify: Cleans up `s3://{bucket}/{revision}/pending.json` regardless of
      status.

### 2.6 — test.yml (self-triggering matrix-based test workflow)

**Goal:** Download binaries from S3, build Lambda layers, run tests for both x64 and arm64.

- [ ] Verify: Triggers on `pull_request: [opened, synchronize, reopened, labeled]`
      and `push: branches: [master]`.
- [ ] Verify: `check-binaries` gate job determines if tests should run:
  - Push to master → always run.
  - PR labeled `binaries:available` → run.
  - PR labeled with something else → skip.
  - PR opened/synchronize/reopened → check if `revision.txt` changed:
    - Not changed → run (TypeScript-only PR, binaries should exist).
    - Changed → skip (waiting for build).
- [ ] Verify: Reads revision from `_/ec2/revision.txt`.
- [ ] Verify: `build` job uses matrix `arch: [x64, arm64]` with correct runners:
  - x64 → `ubuntu-latest`
  - arm64 → `ubuntu-24.04-arm`
- [ ] Verify: Downloads arch-specific binaries from S3:
  - `aws s3 sync s3://{bucket}/{revision}/{arch}/ bin/{arch}/ --exclude "*.json"`
  - `aws s3 cp s3://{bucket}/{revision}/fonts.tar.br bin/fonts.tar.br`
  - Copies arch files to `bin/` root.
- [ ] Verify: `npm ci` → `npm run test:source` (unit tests pass).
- [ ] Verify: Coverage report action runs only on x64 leg.
- [ ] Verify: `npm run build` (TypeScript compiles).
- [ ] Verify: `make chromium.{arch}.zip` produces a Lambda layer zip.
- [ ] Verify: Layer artifact is uploaded via `actions/upload-artifact`.
- [ ] Verify **execute** job: Downloads the layer artifact, provisions it to
      `_/amazon/code`, installs `puppeteer-core`, and runs SAM local invoke for
      Node 20, 22, 24 with `example.com.json` event.
- [ ] Verify: arm64 execute job patches `_/amazon/template.yml` with `sed -i 's/x86_64/arm64/g'`.
- [ ] Verify: `continue-on-error` is **NOT** present — failures are real failures.

### 2.7 — Merge the PR to master

- [ ] Both test workflows pass (or are manually verified if S3 has no real
      binaries yet).
- [ ] The PR has the `chromium-update` label (applied by check-chromium-update).
- [ ] Merge the PR to `master`.

### 2.8 — prepare-release.yml (triggered by PR merge)

**Goal:** Bump `package.json` version, create a git tag, push.

- [ ] Verify: Triggers on `pull_request: [closed]` where
      `merged == true` AND PR has `chromium-update` label.
- [ ] Verify: Checks out `master` using `secrets.RELEASE_TOKEN` (PAT).
- [ ] Verify: Fetches latest stable Chrome version from the Chrome for Testing
      API, extracts the major version, and constructs version `{MAJOR}.0.0`.
- [ ] Verify: Validates the version format matches `^\d+\.\d+\.\d+$`.
- [ ] Verify: Checks that the tag `v{VERSION}` doesn't already exist.
- [ ] Verify: Runs `npm version {VERSION} --no-git-tag-version`.
- [ ] Verify: Commits `package.json` and `package-lock.json` with message
      `{VERSION}`.
- [ ] Verify: Creates annotated tag `v{VERSION}`.
- [ ] Verify: Pushes commit and tag to `origin master --follow-tags`.
- [ ] Verify: The push is done with the PAT (not `GITHUB_TOKEN`), so the tag
      push triggers `release.yml`.

### 2.9 — release.yml (triggered by tag push)

**Goal:** Publish npm packages and create a draft GitHub Release.

- [ ] Verify: Triggers on `push: tags: ["*"]`.
- [ ] Verify: Installs `jq`, checks out code, sets up Node 24 with npm registry.
- [ ] Verify: Reads revision from `_/ec2/revision.txt`.
- [ ] Verify: Downloads **all** binaries from S3 (both x64 and arm64).
- [ ] Verify: Validates that `bin/x64/chromium.br` and `bin/arm64/chromium.br`
      exist — fails the workflow if missing.
- [ ] Verify: `npm run build` (TypeScript compile).
- [ ] Verify: Copies x64 binaries to `bin/` root, then runs
      `npm publish --provenance` for `@sparticuz/chromium`.
- [ ] Verify: Cleans up x64 binaries from `bin/` root after publish.
- [ ] Verify: Creates Lambda layer zips:
  - `chromium-{tag}-layer.x64.zip`
  - `chromium-{tag}-layer.arm64.zip`
- [ ] Verify: Modifies `package.json`:
  - Renames to `@sparticuz/chromium-min`.
  - Removes `bin`, `!bin/arm64`, `!bin/x64` from `files` array.
  - Updates homepage.
  - Runs `npm install` to regenerate `package-lock.json`.
- [ ] Verify: `npm publish --provenance` for `@sparticuz/chromium-min`.
- [ ] Verify: Creates pack tarballs:
  - `chromium-{tag}-pack.x64.tar`
  - `chromium-{tag}-pack.arm64.tar`
- [ ] Verify: Creates a **draft** GitHub Release via `gh release create --draft`:
  - Title: `{tag}`
  - Notes file with Lambda layer instructions and sponsor link.
  - 4 attached assets: 2 layer zips + 2 pack tars.
- [ ] Verify: Release is draft (requires manual publish).
- [ ] Verify: Uses `${{ github.repository }}` not hardcoded `Sparticuz/chromium`.

---

## 3. Workflow chain: Non-build PR

A PR that does NOT change `revision.txt` (e.g., docs fix, bug fix).

- [ ] Open (or push to) a PR that doesn't touch `_/ec2/revision.txt`.
- [ ] Verify: `check-pr-binaries.yml` runs and detects no revision change.
- [ ] Verify: It adds `binaries:available` (or leaves it if already present).
- [ ] Verify: `build-chromium.yml` does NOT trigger (the `binaries:building`
      label was never added).
- [ ] Verify: `test.yml` self-triggers because
      `binaries:available` was added via PAT, and tests download existing
      binaries from S3.
- [ ] Verify: Tests download existing binaries from S3 at the current
      revision in `_/ec2/revision.txt`.

---

## 4. Safety nets & failure modes

### 4.1 — EC2 build failure (ERR trap)

- [ ] Simulate: Force a build failure on EC2 (e.g., invalid revision in
      `revision.txt`, or a bad patch).
- [ ] Verify: The ERR trap in `build-chromium.sh` fires and calls
      `notify_failure "Unexpected error on line $LINENO"`.
- [ ] Verify `notify_failure` runs the full failure path:
  - Appends failure event to `build.json` with `status: "failed"` and `error` message.
  - Removes `pending.json` from S3.
  - Scrubs `GITHUB_PAT` from the build log with `sed`.
  - Uploads `build.log` to S3.
  - Sends `repository_dispatch` with `status: "failed"` and `error` field.
  - Cancels the 8-hour shutdown timer (`shutdown -c`).
  - Shuts down immediately (`shutdown -h now` → instance terminates).

### 4.2 — EC2 self-destruct timer

- [ ] Verify: `build-chromium.sh` runs `shutdown -h +480` as its very first
      action (before logging, validation, or any build work).
- [ ] Verify: The EC2 instance is launched with
      `instance_initiated_shutdown_behavior: terminate` in the workflow.
- [ ] Verify: On success, teardown cancels the timer (`shutdown -c`) and
      shuts down immediately. On failure, `notify_failure` does the same.

### 4.3 — build-safety-net.yml (stale build detection)

- [ ] Trigger manually: Actions → "Build Safety Net" → Run workflow.
- [ ] **No stale builds:** Verify it scans S3 for `pending.json` files, finds
      none (or none past deadline), and exits cleanly.
- [ ] **Stale build present:** Create a fake stale `pending.json`:
  ```bash
  DEADLINE=$(date -u -d "-1 hour" +"%Y-%m-%dT%H:%M:%SZ")
  echo '{"revision":"999999","pr_number":1,"deadline":"'$DEADLINE'","instance_id":"i-fake"}' | \
    aws s3 cp - s3://$BUCKET/999999/pending.json
  ```
  Then trigger the workflow and verify:
  - [ ] It detects the marker as stale (past deadline).
  - [ ] It attempts to terminate the EC2 instance by ID (`i-fake` — will fail
        gracefully).
  - [ ] It attempts to terminate instances by tag `Name=chromium-build`.
  - [ ] It removes `s3://...999999/pending.json`.
  - [ ] It swaps the PR label to `binaries:failed` (if `pr_number` was valid).
  - [ ] It posts a timeout comment on the PR.
  - [ ] It creates a GitHub issue titled "Build safety net: stale builds
        detected" with label `bug`.

### 4.4 — Emergency teardown in build-chromium.yml

- [ ] Verify: If any step in the `build-chromium.yml` GHA job fails, the
      `Emergency teardown (on failure)` step runs with `if: failure()`.
- [ ] Verify: It terminates the EC2 instance by ID (if known from the
      `ec2` step output).
- [ ] Verify: As fallback, it finds and terminates all instances with tag
      `Name=chromium-build` in `running` or `pending` state.

### 4.5 — build-complete.yml failure path

- [ ] Simulate a failure dispatch:
  ```bash
  curl -X POST \
    -H "Authorization: token $PAT" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/Sparticuz/ch2/dispatches \
    -d '{"event_type":"build-complete","client_payload":{"revision":"999","pr_number":"1","status":"failed","error":"Test failure simulation"}}'
  ```
- [ ] Verify: `build-complete.yml` triggers.
- [ ] Verify: The failure path runs (status != 'success'):
  - Removes `binaries:building` label.
  - Adds `binaries:failed` label.
  - Posts failure comment with error message, build log S3 URL, and retry
    instructions.
  - Cleans up `pending.json`.

### 4.6 — Patch verification failure

- [ ] Simulate: Introduce a Chromium revision where one of the sed patches
      doesn't apply (e.g., the patched line was refactored upstream).
- [ ] Verify: The `grep -q` verification in `setup.sh` detects the mismatch.
- [ ] Verify: `notify_failure "Patch verification failed: ..."` is called.
- [ ] Verify: Full failure path executes (see 4.1).

---

## 5. Manual / workflow_dispatch flows

### 5.1 — Manual prepare-release

- [ ] Trigger: Actions → "Prepare Release" → Run workflow → Enter version
      (e.g., `999.0.1`).
- [ ] Verify: It checks out `master`, runs `npm version 999.0.1`, commits, tags
      `v999.0.1`, pushes.
- [ ] Verify: The tag push triggers `release.yml`.
- [ ] Clean up: Delete the test tag and revert the commit.

### 5.2 — Manual check-chromium-update

- [ ] Trigger: Actions → "Check Chromium Update" → Run workflow.
- [ ] Verify: It runs without errors, checking the current vs latest revision.

### 5.3 — Manual build-safety-net

- [ ] Trigger: Actions → "Build Safety Net" → Run workflow.
- [ ] Verify: It scans S3 and exits cleanly (no stale builds expected).

---

## 6. Source code changes

### 6.1 — Lambda layer fallback path (source/index.ts, #483 fix)

- [ ] Verify: `source/index.ts` includes a fallback to `/opt/nodejs/node_modules/@sparticuz/chromium/bin`
      for Lambda layer deployments.
- [ ] Verify: The error message when no Chromium binary is found mentions both
      `@sparticuz/chromium` and `@sparticuz/chromium-min` with download instructions.
- [ ] Verify: `npm run build` compiles cleanly.
- [ ] Verify: `npm run test:source` passes (22 unit tests).

### 6.2 — Makefile refactoring

- [ ] Verify: `define build-zip` / `call build-zip` pattern works:
  - `make chromium.x64.zip` should work (if binaries exist in `bin/x64/`).
  - `make chromium.arm64.zip` should work (if binaries exist in `bin/arm64/`).
- [ ] Verify: `define build-pack` / `call build-pack` pattern works:
  - `make pack-x64` produces `chromium-pack.x64.tar`.
  - `make pack-arm64` produces `chromium-pack.arm64.tar`.
- [ ] Verify: Makefile uses `npm run pack:x64` / `npm run pack:arm64` (check
      that `package.json` scripts map to the Makefile targets).

### 6.3 — README updates

- [ ] Verify: README has a "Bundler Configuration" section (addresses #134).
- [ ] Verify: README has a "macOS / Playwright" section (addresses #117).
- [ ] Verify: README has a Playwright `/tmp` FAQ entry (addresses #231).
- [ ] Verify: "Updating the binaries" section references `_/ec2/` files, not
      `_/ansible/`.
- [ ] Verify: Accessible PDF patch example references `_/ec2/args-x64.gn`, not
      `_/ansible/plays/chromium.yml`.

### 6.4 — EC2 build scripts

- [ ] Verify: `_/ec2/build-chromium.sh` is the orchestrator (~95 lines).
- [ ] Verify: `_/ec2/setup.sh` handles NVMe, swap, sysctl, deps, source sync,
      patches.
- [ ] Verify: `_/ec2/build-x64.sh` handles x64 compile, strip, compress, upload.
- [ ] Verify: `_/ec2/build-arm64.sh` handles arm64 cross-compile with
      `llvm-strip` (not Linaro GCC).
- [ ] Verify: `_/ec2/teardown.sh` handles log upload, completion marker,
      dispatch, shutdown.
- [ ] Verify: Static config files exist:
  - `_/ec2/args-x64.gn` — GN args for x64 (`is_official_build = true`, etc.)
  - `_/ec2/args-arm64.gn` — GN args for arm64 (`target_cpu="arm64"`)
  - `_/ec2/.gclient` — gclient solutions config
  - `_/ec2/patches/sandbox-ipc-failed-polls.sed`
  - `_/ec2/patches/render-process-host-check.sed`
- [ ] Verify: `_/ec2/revision.txt` contains a valid numeric revision.
- [ ] Verify: `_/ec2/README.md` documents IAM setup, secrets, and build process.

---

## 7. Repo hygiene

### 7.1 — .gitignore

- [ ] `*.br` is in `.gitignore` — binaries can never be accidentally committed.
- [ ] `.env` is in `.gitignore`.

### 7.2 — No continue-on-error in tests

- [ ] Verify: `test.yml` does NOT contain
      `continue-on-error: true` anywhere.

### 7.3 — Ansible removed

- [ ] Verify: `_/ansible/` directory does not exist.
- [ ] Verify: No workflow file references `ansible`, `inventory.ini`, or
      `_/ansible/` in any `run:` block or step name.
- [ ] Verify: No `pip install ansible`, `ansible-playbook`, or `setup-python`
      steps remain in `build-chromium.yml`.

### 7.4 — EC2 build architecture

- [ ] Verify: `build-chromium.yml` uses direct AWS CLI calls, not Ansible.
- [ ] Verify: EC2 instances are tagged `Name=chromium-build` (not `Chromium`).
- [ ] Verify: `build-safety-net.yml` searches for tag `Name=chromium-build`.
- [ ] Verify: No SSH key pair, no inbound security group rules (egress only).
- [ ] Verify: No `ansible.cfg`, `inventory.ini`, or Makefile in `_/ansible/`.

### 7.5 — Static analysis

- [ ] `actionlint` passes with 0 errors on all 9 workflow files.
- [ ] TypeScript compiles with 0 errors (`npm run build`).
- [ ] `shellcheck` passes on `build-chromium.sh`, `setup.sh`, `build-x64.sh`,
      `build-arm64.sh`, `teardown.sh` (if shellcheck available).
- [ ] All workflow YAML files parse cleanly (`python3 -c "import yaml; yaml.safe_load(open('...'))"` for each).

---

## 8. Post-merge verification on real repo

After all ch2 testing passes and you're ready to push to `Sparticuz/chromium`:

### 8.1 — Pre-push checklist

- [ ] **Releases:** All 30 existing GitHub Releases still have their assets.
      (Releases are API objects — they survive force-push, but verify.)
- [ ] **Open PRs (#490, #489, #485, etc.):** Note that all 10 open PRs will have
      broken base commits after force-push. Contributors will need to rebase.
      Decide: close stale PRs? comment on active ones?
- [ ] **Forks (90):** All forks will diverge. Nothing you can do — document it.
- [ ] **npm packages:** Verify `@sparticuz/chromium` and `@sparticuz/chromium-min`
      latest versions are correct on npmjs.com before and after.
- [ ] **Secrets:** Verify all 5 secrets exist on `Sparticuz/chromium`.
- [ ] **Labels:** Create `binaries:building`, `binaries:available`,
      `binaries:failed`, `chromium-update` labels on the real repo.
- [ ] **Environment:** Create `chromium-build` environment with required
      reviewers on the real repo.
- [ ] **IAM instance profile:** Verify `chromium-build` profile exists in
      the production AWS account with S3 permissions.
- [ ] **S3 bucket:** Verify the bucket has the current revision's binaries
      (so test workflows can pass immediately after merge).

### 8.2 — Push sequence

```bash
# 1. Force-push the rewritten history (all branches + tags)
git push origin --force --all
git push origin --force --tags

# 2. Verify default branch is master
gh repo edit Sparticuz/chromium --default-branch master

# 3. Push feat/infra branch
git push origin feat/infra
```

### 8.3 — Post-push smoke tests

- [ ] Open a test PR on `Sparticuz/chromium` that doesn't change `revision.txt`.
- [ ] Verify `check-pr-binaries.yml` adds `binaries:available`.
- [ ] Verify `test.yml` triggers and downloads binaries from S3 (both x64 and arm64).
- [ ] Manually trigger "Check Chromium Update" — verify it runs cleanly.
- [ ] Manually trigger "Build Safety Net" — verify it runs cleanly.

### 8.4 — Communication

- [ ] Comment on all open PRs explaining the history rewrite and how to rebase.
- [ ] Update repo description if needed.
- [ ] Consider a GitHub Discussion or release note explaining the infrastructure
      changes.

---

## Quick reference: Workflow files

| File                        | Trigger                                         | Purpose                                               |
| --------------------------- | ----------------------------------------------- | ----------------------------------------------------- |
| `check-chromium-update.yml` | Cron daily 08:00 UTC / manual                   | Detect new Chromium stable, open PR                   |
| `check-pr-binaries.yml`     | PR opened/sync/reopened                         | Set `binaries:building` or `binaries:available` label |
| `build-chromium.yml`        | PR labeled `binaries:building`                  | Launch EC2 instance, fire-and-forget                  |
| `build-complete.yml`        | `repository_dispatch: build-complete`           | Swap label, comment on PR                             |
| `build-safety-net.yml`      | Cron daily 12:00 UTC / manual                   | Terminate stale EC2 instances                         |
| `test.yml`                  | PR labeled/opened/sync / push to master         | Download binaries, test Lambda (x64 + arm64)          |
| `prepare-release.yml`       | PR merged with `chromium-update` label / manual | Bump version, create tag                              |
| `release.yml`               | Tag push                                        | Publish npm, create GitHub Release                    |

## Quick reference: Label → Workflow trigger map

| Label added          | Triggers                             |
| -------------------- | ------------------------------------ |
| `binaries:building`  | `build-chromium.yml`                 |
| `binaries:available` | `test.yml`                           |
| `binaries:failed`    | Nothing (manual intervention needed) |

## Quick reference: Secrets → Workflows map

| Secret                     | Workflows                                                       |
| -------------------------- | --------------------------------------------------------------- |
| `AWS_ACCESS_KEY_ID`        | build-chromium, build-complete, build-safety-net, test, release |
| `AWS_SECRET_ACCESS_KEY`    | (same as above)                                                 |
| `CHROMIUM_BUILD_S3_BUCKET` | (same as above)                                                 |
| `NPM_PUBLISH_TOKEN`        | release                                                         |
| `RELEASE_TOKEN` (PAT)      | prepare-release, build-chromium                                 |

## Quick reference: EC2 build script chain

```
user-data bootstrap
  → build-chromium.sh  (orchestrator: self-destruct, logging, validation, ERR trap)
    → source setup.sh        (NVMe, swap, sysctl, deps, depot_tools, gclient sync, patches)
    → source build-x64.sh    (gn gen, autoninja, strip, brotli, libs, S3 upload)
    → source build-arm64.sh  (sysroot, gn gen, autoninja, llvm-strip, brotli, S3 upload)
    → source teardown.sh     (fonts, log scrub, log upload, build.json, dispatch, shutdown)
```

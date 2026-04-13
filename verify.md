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
  - `RELEASE_TOKEN` (PAT with `contents:write` scope)
- [ ] **GitHub Environment** `chromium-build` created on ch2 with required
      reviewers (you) for the manual approval gate.
- [ ] **Labels** exist on ch2:
  - `binaries:building`
  - `binaries:available`
  - `binaries:failed`
  - `chromium-update`
- [ ] **S3 bucket** exists and is accessible with the configured AWS creds.
      Verify: `aws s3 ls s3://$BUCKET/` succeeds.
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
- [ ] Verify: The workflow fetches the current `chromium_revision` from
      `_/ec2/revision.txt`.
- [ ] Verify: It queries
      `https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json`
      for the latest stable revision.
- [ ] **If revision matches** — workflow exits cleanly, no PR created.
- [ ] **If revision differs** — verify:
  - [ ] `tools/update-browser-revision.mjs` runs and updates `revision.txt`.
  - [ ] A PR is created on branch `chore/chromium-update-{revision}`.
  - [ ] The PR has the `chromium-update` label.
  - [ ] The PR body contains previous revision, new revision, and Chrome version.

**To force a new revision for testing:** Temporarily edit `revision.txt` on
`feat/infra` to set `chromium_revision=1` (an old value), push, then run the
workflow. It should detect the current stable as "new" and open a PR.

### 2.2 — check-pr-binaries.yml (auto-triggered by PR)

**Goal:** Set `binaries:building` label because `revision.txt` changed.

- [ ] Verify: The workflow runs on `pull_request: [opened, synchronize, reopened]`.
- [ ] Verify: It detects that `_/ec2/revision.txt` is in the changed files
      list via `gh api repos/.../pulls/{pr}/files`.
- [ ] Verify: It adds the `binaries:building` label.
- [ ] Verify: No other `binaries:*` label is present (if one was, it was removed
      first).

### 2.3 — build-chromium.yml (triggered by label)

**Goal:** Launch an EC2 instance to compile Chromium.

- [ ] Verify: The workflow triggers on `pull_request: [labeled]` where
      `label.name == 'binaries:building'`.
- [ ] Verify: The `chromium-build` environment approval gate fires — you must
      manually approve before the job proceeds.
- [ ] Verify: It reads `chromium_revision` from `revision.txt`.
- [ ] Verify: A `pending.json` is uploaded to
      `s3://{bucket}/{revision}/pending.json` with `deadline` set 8 hours ahead,
      and `pr_number`, `repository`, `started_at` fields.
- [ ] Verify: Ansible launches an EC2 `c8id.8xlarge` instance with tag
      `Name=Chromium`.
- [ ] Verify: The runner polls for up to 10 minutes until the instance is
      running, then updates `pending.json` with the `instance_id`.
- [ ] Verify: A PR comment is posted with revision, S3 location, instance type,
      deadline, and safety mechanisms.
- [ ] Verify: The runner exits (fire-and-forget) — it does NOT wait for the
      build to complete.
- [ ] Verify: EC2 instance has a self-destruct timer (`shutdown -h +480` in user
      data, applied via `instance_initiated_shutdown_behavior: terminate`).

**If the workflow itself fails** (not the EC2 build):

- [ ] Verify: The `Emergency teardown (on failure)` step runs and calls
      `ansible-playbook plays/teardown.yml`.

### 2.4 — EC2 build completes → upload-artifacts.sh

**Goal:** EC2 uploads binaries to S3 and sends `repository_dispatch`.

This runs on the EC2 instance, not in GitHub Actions. Verify by checking
S3 and the dispatch event.

- [ ] Verify: After the Ansible playbook completes on EC2, the script
      `_/ansible/plays/files/upload-artifacts.sh` runs with arguments:
      `<S3_BUCKET> <REVISION> <GITHUB_PAT> <GITHUB_REPO> <PR_NUMBER>`.
- [ ] Verify S3 structure after upload:
  ```
  s3://{bucket}/{revision}/
    x64/chromium.br
    x64/al2023.tar.br
    x64/swiftshader.tar.br
    fonts.tar.br
    completed.json    ← status: success
  ```
  (arm64 artifacts only present if arm64 build was enabled.)
- [ ] Verify: `pending.json` is removed from S3.
- [ ] Verify: A `repository_dispatch` event of type `build-complete` is sent to
      the repo with payload `{ revision, pr_number, status: "success" }`.

### 2.5 — build-complete.yml (triggered by repository_dispatch)

**Goal:** Swap label to `binaries:available` and comment on PR.

- [ ] Verify: The workflow triggers on `repository_dispatch: [build-complete]`.
- [ ] Verify: It parses `revision`, `pr_number`, and `status` from
      `client_payload`.
- [ ] **On success (`status == 'success'`):**
  - [ ] Removes `binaries:building` label from the PR.
  - [ ] Adds `binaries:available` label.
  - [ ] Posts a PR comment with S3 paths for x64 and arm64.
- [ ] **On failure (`status != 'success'`):**
  - [ ] Removes `binaries:building` label.
  - [ ] Adds `binaries:failed` label.
  - [ ] Posts a PR comment with error details.
- [ ] Verify: Cleans up `s3://{bucket}/{revision}/pending.json` regardless of
      status.

### 2.6 — test-x64.yml (triggered by `binaries:available` label)

**Goal:** Download binaries from S3, build Lambda layer, run tests.

- [ ] Verify: Triggers on `pull_request: [labeled]` where
      `label.name == 'binaries:available'`.
- [ ] Verify: Also triggers on `push: branches: [master]`.
- [ ] Verify: Reads `chromium_revision` from `revision.txt`.
- [ ] Verify: Downloads x64 binaries from S3:
  - `aws s3 sync s3://{bucket}/{revision}/x64/ bin/x64/ --exclude "*.json"`
  - `aws s3 cp s3://{bucket}/{revision}/fonts.tar.br bin/fonts.tar.br`
  - Copies x64 files to `bin/` root.
- [ ] Verify: `npm ci` → `npm run test:source` (unit tests pass).
- [ ] Verify: Coverage report action runs.
- [ ] Verify: `npm run build` (TypeScript compiles).
- [ ] Verify: `make chromium.x64.zip` produces a Lambda layer zip.
- [ ] Verify: Layer artifact is uploaded via `actions/upload-artifact`.
- [ ] Verify **execute** job: Downloads the layer artifact, provisions it to
      `_/amazon/code`, installs `puppeteer-core`, and runs SAM local invoke for
      Node 20, 22, 24 with `example.com.json` event.
- [ ] Verify: `continue-on-error` is **NOT** present — failures are real failures.

### 2.7 — test-arm.yml (triggered by `binaries:available` label)

Same as test-x64 but:

- [ ] Runs on `ubuntu-24.04-arm` runner.
- [ ] Downloads arm64 binaries: `aws s3 sync s3://{bucket}/{revision}/arm64/`.
- [ ] Builds `chromium.arm64.zip`.
- [ ] Patches `_/amazon/template.yml` with `sed -i 's/x86_64/arm64/g'`.
- [ ] Runs SAM local invoke on arm64.

### 2.8 — Merge the PR to master

- [ ] Both test workflows pass (or are manually verified if S3 has no real
      binaries yet).
- [ ] The PR has the `chromium-update` label (applied by check-chromium-update).
- [ ] Merge the PR to `master`.

### 2.9 — prepare-release.yml (triggered by PR merge)

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

### 2.10 — release.yml (triggered by tag push)

**Goal:** Publish npm packages and create a draft GitHub Release.

- [ ] Verify: Triggers on `push: tags: ["*"]`.
- [ ] Verify: Installs `jq`, checks out code, sets up Node 24 with npm registry.
- [ ] Verify: Reads `chromium_revision` from `revision.txt`.
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
- [ ] Verify: `test-x64.yml` and `test-arm.yml` trigger because
      `binaries:available` was added.
- [ ] Verify: Tests download existing binaries from S3 at the current
      `chromium_revision` in `revision.txt`.

---

## 4. Safety nets & failure modes

### 4.1 — Ansible block/rescue (build failure on EC2)

- [ ] Simulate: Force a build failure on EC2 (e.g., invalid revision).
- [ ] Verify: The Ansible `rescue` block in `chromium.yml` fires:
  - Sets `build_failed: true`.
  - Logs "Chromium build failed. Teardown will clean up AWS resources."
- [ ] Verify: The `Teardown AWS` play always runs (it's a separate play, not
      inside the block):
  - Terminates EC2 instance by ID.
  - Terminates by tag `Name=Chromium` as fallback.
  - Deletes security group `Chromium`.
  - Deletes EC2 key pair `ansible`.
  - Deletes local SSH key files.
  - All steps have `ignore_errors: yes`.

### 4.2 — EC2 self-destruct timer

- [ ] Verify: The EC2 instance is launched with
      `instance_initiated_shutdown_behavior: terminate` in the Ansible playbook.
- [ ] Verify: A shutdown timer is set (via user data or Ansible task) so the
      instance auto-terminates after ~8 hours if nothing else stops it.

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
  - [ ] It attempts to terminate instances by tag `Name=Chromium`.
  - [ ] It removes `s3://...999999/pending.json`.
  - [ ] It swaps the PR label to `binaries:failed` (if `pr_number` was valid).
  - [ ] It posts a timeout comment on the PR.
  - [ ] It creates a GitHub issue titled "Build safety net: stale builds
        detected" with label `bug`.

### 4.4 — Emergency teardown in build-chromium.yml

- [ ] Verify: If any step in the `build-chromium.yml` job fails, the
      `Emergency teardown (on failure)` step runs with `if: failure()`.
- [ ] Verify: It calls `ansible-playbook plays/teardown.yml` which imports
      `teardown-tasks.yml` (terminates by tag, cleans up SG + key pair).

### 4.5 — build-complete.yml failure path

- [ ] Simulate a failure dispatch:
  ```bash
  curl -X POST \
    -H "Authorization: token $PAT" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/Sparticuz/ch2/dispatches \
    -d '{"event_type":"build-complete","client_payload":{"revision":"999","pr_number":"1","status":"failed"}}'
  ```
- [ ] Verify: `build-complete.yml` triggers.
- [ ] Verify: The failure path runs (status != 'success'):
  - Removes `binaries:building` label.
  - Adds `binaries:failed` label.
  - Posts failure comment.
  - Cleans up `pending.json`.

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

---

## 7. Repo hygiene

### 7.1 — .gitignore

- [ ] `*.br` is in `.gitignore` — binaries can never be accidentally committed.
- [ ] `.env` is in `.gitignore`.

### 7.2 — No continue-on-error in tests

- [ ] Verify: `test-x64.yml` and `test-arm.yml` do NOT contain
      `continue-on-error: true` anywhere.

### 7.3 — EC2 instance type

- [ ] Verify: `_/ec2/revision.txt` contains the EC2 instance type configuration
      (note: Ansible inventory is being replaced by EC2-based configuration).
- [ ] Verify: `_/ansible/README.md` mentions `c8id.8xlarge` and updated build time.

### 7.4 — Ansible teardown architecture

- [ ] Verify: `chromium.yml` uses `block:` / `rescue:` around all build tasks.
- [ ] Verify: `teardown-tasks.yml` is a reusable include (used by both
      `chromium.yml` and `teardown.yml`).
- [ ] Verify: `teardown.yml` can be run standalone
      (note: Ansible is being replaced; teardown will migrate to EC2-based tooling).

### 7.5 — Static analysis

- [ ] `actionlint` passes with 0 errors on all 9 workflow files.
- [ ] TypeScript compiles with 0 errors (`npm run build`).
- [ ] Shellcheck on `upload-artifacts.sh` (if available).

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
- [ ] Verify `test-x64.yml` triggers and downloads binaries from S3.
- [ ] Verify `test-arm.yml` triggers and downloads binaries from S3.
- [ ] Manually trigger "Check Chromium Update" — verify it runs cleanly.
- [ ] Manually trigger "Build Safety Net" — verify it runs cleanly.

### 8.4 — Communication

- [ ] Comment on all open PRs explaining the history rewrite and how to rebase.
- [ ] Update repo description if needed.
- [ ] Consider a GitHub Discussion or release note explaining the infrastructure
      changes.

---

## Quick reference: Label → Workflow trigger map

| Label added          | Triggers                             |
| -------------------- | ------------------------------------ |
| `binaries:building`  | `build-chromium.yml`                 |
| `binaries:available` | `test-x64.yml`, `test-arm.yml`       |
| `binaries:failed`    | Nothing (manual intervention needed) |

## Quick reference: Secrets → Workflows map

| Secret                     | Workflows                                                                     |
| -------------------------- | ----------------------------------------------------------------------------- |
| `AWS_ACCESS_KEY_ID`        | build-chromium, build-complete, build-safety-net, test-x64, test-arm, release |
| `AWS_SECRET_ACCESS_KEY`    | (same as above)                                                               |
| `CHROMIUM_BUILD_S3_BUCKET` | (same as above)                                                               |
| `NPM_PUBLISH_TOKEN`        | release                                                                       |
| `RELEASE_TOKEN` (PAT)      | prepare-release, build-chromium                                               |

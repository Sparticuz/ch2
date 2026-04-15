# Label State Machine Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace ad-hoc label usage with a formal state machine where maintainer-added trigger labels (`binaries:build`, `binaries:test`) drive workflow actions, and automation swaps them for status labels. The PR body is dynamically updated with a checklist showing progress and next actions.

**Architecture:** Each workflow that transitions state does three things: (1) consume the trigger label and set the status label, (2) update the PR body checklist between `<!-- checklist-start -->` and `<!-- checklist-end -->` markers, (3) proceed with its actual work. A shared shell function pattern handles the checklist update across workflows. `build-complete.yml` switches from `RELEASE_TOKEN` to `GITHUB_TOKEN` since the PAT is no longer needed for label-triggered downstream workflows.

**Tech Stack:** GitHub Actions workflows (YAML + bash), GitHub REST API via `gh`, `jq` for JSON manipulation.

**Design doc:** `docs/plans/2026-04-15-label-state-machine-design.md`

---

### Task 1: Update `check-chromium-update.yml` PR body template

**Files:**

- Modify: `.github/workflows/check-chromium-update.yml:69-99` (PR body template)

**Step 1: Update the PR body template**

Replace lines 69-99 with:

```yaml
body: |
  ## Chromium Update

  A new stable Chromium version has been detected.

  | | Value |
  |---|---|
  | **Previous revision** | ${{ steps.current.outputs.revision }} |
  | **New revision** | ${{ steps.latest.outputs.revision }} |
  | **Chrome version** | ${{ steps.latest.outputs.version }} |

  ### Build Options

  Add these labels **before** adding `binaries:build`:

  | Label | Effect |
  |---|---|
  | `build:ssh` | Enable SSH access + screen session for live monitoring |
  | `build:on-demand` | Use on-demand pricing instead of spot (~3x more expensive) |

  Spot pricing is the default (~70% cheaper). If a spot instance is interrupted, retry by adding `binaries:build` again.

  <!-- checklist-start -->
  ### Maintainer Checklist
  - [x] Revision bump detected — `${{ steps.current.outputs.revision }}` → `${{ steps.latest.outputs.revision }}`
  - [ ] **Add `binaries:build` to start EC2 build** ← you are here
  - [ ] Binaries built and uploaded to S3
  - [ ] **Add `binaries:test` to run tests**
  - [ ] Tests and visual regression passed
  <!-- checklist-end -->

  ---
  *This PR was created automatically by the [Check Chromium Update](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}) workflow.*
```

Key changes:

- "Next Steps" section replaced by the checklist between markers
- "Build Options" moved above the checklist
- Instructions now reference `binaries:build` (not `binaries:building`)

**Step 2: Verify YAML is valid**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/check-chromium-update.yml'))"`
Expected: No output (success)

**Step 3: Commit**

```bash
git add .github/workflows/check-chromium-update.yml
git commit -m "refactor: update PR template with dynamic checklist and binaries:build label"
```

---

### Task 2: Update `build-chromium.yml` — trigger on `binaries:build`, swap labels, update checklist

**Files:**

- Modify: `.github/workflows/build-chromium.yml:14` (gate condition)
- Modify: `.github/workflows/build-chromium.yml` (add label swap + checklist step after gate, before EC2 launch)

**Step 1: Change the gate condition**

Line 14, change:

```yaml
if: github.event.label.name == 'binaries:building'
```

to:

```yaml
if: github.event.label.name == 'binaries:build'
```

**Step 2: Add label swap + checklist update step**

After the "Detect build options" step (which ends around line 78) and before the "Configure AWS credentials" step, add a new step:

```yaml
- name: Update labels and PR checklist
  env:
    GH_TOKEN: ${{ github.token }}
    PR_NUMBER: ${{ github.event.pull_request.number }}
  run: |
    REPO="${{ github.repository }}"

    # Swap labels: remove trigger + stale states, add building
    for LABEL in "binaries:build" "binaries:needed" "binaries:failed"; do
      gh api "repos/${REPO}/issues/${PR_NUMBER}/labels/${LABEL}" -X DELETE 2>/dev/null || true
    done
    gh api "repos/${REPO}/issues/${PR_NUMBER}/labels" -f "labels[]=binaries:building"

    # Update PR checklist
    BODY=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json body --jq .body)

    CURRENT_REV=$(echo "$BODY" | grep -oP '(?<=` → `)\d+(?=`)' | head -1)
    PREV_REV=$(echo "$BODY" | grep -oP '(?<=— `)\d+(?=` →)' | head -1)

    NEW_CHECKLIST="### Maintainer Checklist
    - [x] Revision bump detected — \`${PREV_REV}\` → \`${CURRENT_REV}\`
    - [x] Build started
    - [ ] Binaries built and uploaded to S3 ← building...
    - [ ] **Add \`binaries:test\` to run tests**
    - [ ] Tests and visual regression passed"

    # Replace content between markers
    UPDATED=$(echo "$BODY" | perl -0777 -pe "s|<!-- checklist-start -->.*?<!-- checklist-end -->|<!-- checklist-start -->\n${NEW_CHECKLIST}\n<!-- checklist-end -->|s")

    gh pr edit "$PR_NUMBER" --repo "$REPO" --body "$UPDATED"
```

**Step 3: Verify YAML is valid**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-chromium.yml'))"`
Expected: No output (success)

**Step 4: Commit**

```bash
git add .github/workflows/build-chromium.yml
git commit -m "refactor: trigger build on binaries:build label, swap labels and update checklist"
```

---

### Task 3: Update `build-complete.yml` — switch to GITHUB_TOKEN, update checklist

**Files:**

- Modify: `.github/workflows/build-complete.yml:33` (token in success path)
- Modify: `.github/workflows/build-complete.yml:83` (token in failure path)
- Modify: `.github/workflows/build-complete.yml` (add checklist update logic to both paths)

**Step 1: Change token from RELEASE_TOKEN to github.token in success path**

Line 33, change:

```yaml
GH_TOKEN: ${{ secrets.RELEASE_TOKEN }}
```

to:

```yaml
GH_TOKEN: ${{ github.token }}
```

**Step 2: Add checklist update to success path**

After the existing label swap (lines 37-41), add:

```bash
          # Update PR checklist
          BODY=$(gh pr view "$PR_NUMBER" --repo "${{ github.repository }}" --json body --jq .body)

          CURRENT_REV=$(echo "$BODY" | grep -oP '(?<=` → `)\d+(?=`)' | head -1)
          PREV_REV=$(echo "$BODY" | grep -oP '(?<=— `)\d+(?=` →)' | head -1)

          # Get binary sizes from manifest if available
          MANIFEST=$(cat /tmp/manifest.json 2>/dev/null || echo '{}')
          X64_SIZE=$(echo "$MANIFEST" | jq -r '.x64.binaries["chromium.br"].size // 0')
          ARM64_SIZE=$(echo "$MANIFEST" | jq -r '.arm64.binaries["chromium.br"].size // 0')

          SIZE_INFO=""
          if [ "$X64_SIZE" != "0" ] && [ "$ARM64_SIZE" != "0" ]; then
            X64_MB=$(echo "scale=1; $X64_SIZE / 1048576" | bc)
            ARM64_MB=$(echo "scale=1; $ARM64_SIZE / 1048576" | bc)
            SIZE_INFO=" (x64: ${X64_MB} MB, arm64: ${ARM64_MB} MB)"
          fi

          NEW_CHECKLIST="### Maintainer Checklist
          - [x] Revision bump detected — \`${PREV_REV}\` → \`${CURRENT_REV}\`
          - [x] Build started
          - [x] Binaries built and uploaded to S3${SIZE_INFO}
          - [ ] **Add \`binaries:test\` to run tests** ← you are here
          - [ ] Tests and visual regression passed"

          UPDATED=$(echo "$BODY" | perl -0777 -pe "s|<!-- checklist-start -->.*?<!-- checklist-end -->|<!-- checklist-start -->\n${NEW_CHECKLIST}\n<!-- checklist-end -->|s")

          gh pr edit "$PR_NUMBER" --repo "${{ github.repository }}" --body "$UPDATED"
```

Note: The manifest may be available from earlier steps in this workflow — check if it downloads the manifest already. If not, fetch it from S3 in this step. The exact mechanism depends on what data `build-complete.yml` already has from the `repository_dispatch` payload.

**Step 3: Change token from RELEASE_TOKEN to github.token in failure path**

Line 83, change:

```yaml
GH_TOKEN: ${{ secrets.RELEASE_TOKEN }}
```

to:

```yaml
GH_TOKEN: ${{ github.token }}
```

**Step 4: Add checklist update to failure path**

After the existing label swap (lines 87-91), add:

```bash
          # Update PR checklist
          BODY=$(gh pr view "$PR_NUMBER" --repo "${{ github.repository }}" --json body --jq .body)

          CURRENT_REV=$(echo "$BODY" | grep -oP '(?<=` → `)\d+(?=`)' | head -1)
          PREV_REV=$(echo "$BODY" | grep -oP '(?<=— `)\d+(?=` →)' | head -1)

          NEW_CHECKLIST="### Maintainer Checklist
          - [x] Revision bump detected — \`${PREV_REV}\` → \`${CURRENT_REV}\`
          - [x] Build started
          - [ ] ~~Binaries built~~ — **build failed** (add \`binaries:build\` to retry) ← you are here
          - [ ] **Add \`binaries:test\` to run tests**
          - [ ] Tests and visual regression passed"

          UPDATED=$(echo "$BODY" | perl -0777 -pe "s|<!-- checklist-start -->.*?<!-- checklist-end -->|<!-- checklist-start -->\n${NEW_CHECKLIST}\n<!-- checklist-end -->|s")

          gh pr edit "$PR_NUMBER" --repo "${{ github.repository }}" --body "$UPDATED"
```

**Step 5: Verify YAML is valid**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-complete.yml'))"`
Expected: No output (success)

**Step 6: Commit**

```bash
git add .github/workflows/build-complete.yml
git commit -m "refactor: switch to GITHUB_TOKEN and add PR checklist updates"
```

---

### Task 4: Update `test.yml` — trigger on `binaries:test`, add label management and checklist

**Files:**

- Modify: `.github/workflows/test.yml:3-8` (trigger section)
- Modify: `.github/workflows/test.yml:10-56` (replace check-binaries gate job)
- Add: New steps/jobs for label management and checklist updates

This is the largest change. The `check-binaries` gate job is simplified since `binaries:test` inherently means "binaries are available."

**Step 1: Update trigger section**

Lines 3-7, keep push trigger, change PR trigger:

```yaml
on:
  push:
    branches: [master]
  pull_request:
    types: [labeled]
```

Note: Remove `opened, synchronize, reopened` — tests only run on label triggers now (for PRs). Push to master still runs unconditionally.

**Step 2: Replace the `check-binaries` gate job**

Replace the entire `check-binaries` job (lines 10-56) with:

```yaml
check-trigger:
  name: Check Trigger
  runs-on: ubuntu-latest
  outputs:
    should_run: ${{ steps.gate.outputs.should_run }}
    is_pr: ${{ steps.gate.outputs.is_pr }}
  permissions:
    contents: read
    pull-requests: write
  steps:
    - name: Determine if tests should run
      id: gate
      env:
        GH_TOKEN: ${{ github.token }}
      run: |
        EVENT="${{ github.event_name }}"

        if [ "$EVENT" = "push" ]; then
          echo "Push event — running tests"
          echo "should_run=true" >> "$GITHUB_OUTPUT"
          echo "is_pr=false" >> "$GITHUB_OUTPUT"
          exit 0
        fi

        LABEL="${{ github.event.label.name }}"
        if [ "$LABEL" = "binaries:test" ]; then
          echo "Label 'binaries:test' added — running tests"
          echo "should_run=true" >> "$GITHUB_OUTPUT"
          echo "is_pr=true" >> "$GITHUB_OUTPUT"

          # Swap labels: remove trigger, add testing
          PR_NUMBER="${{ github.event.pull_request.number }}"
          REPO="${{ github.repository }}"
          for LABEL_RM in "binaries:test" "binaries:failed"; do
            gh api "repos/${REPO}/issues/${PR_NUMBER}/labels/${LABEL_RM}" -X DELETE 2>/dev/null || true
          done
          gh api "repos/${REPO}/issues/${PR_NUMBER}/labels" -f "labels[]=binaries:testing"

          # Update PR checklist
          BODY=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json body --jq .body)
          CURRENT_REV=$(echo "$BODY" | grep -oP '(?<=` → `)\d+(?=`)' | head -1)
          PREV_REV=$(echo "$BODY" | grep -oP '(?<=— `)\d+(?=` →)' | head -1)

          # Preserve the binary size info if present
          SIZE_LINE=$(echo "$BODY" | grep -oP 'Binaries built and uploaded to S3.*' | head -1)
          if [ -z "$SIZE_LINE" ]; then
            SIZE_LINE="Binaries built and uploaded to S3"
          fi

          NEW_CHECKLIST="### Maintainer Checklist
          - [x] Revision bump detected — \`${PREV_REV}\` → \`${CURRENT_REV}\`
          - [x] Build started
          - [x] ${SIZE_LINE}
          - [x] Tests started
          - [ ] Tests and visual regression passed ← testing..."

          UPDATED=$(echo "$BODY" | perl -0777 -pe "s|<!-- checklist-start -->.*?<!-- checklist-end -->|<!-- checklist-start -->\n${NEW_CHECKLIST}\n<!-- checklist-end -->|s")
          gh pr edit "$PR_NUMBER" --repo "$REPO" --body "$UPDATED"
        else
          echo "Label '${LABEL}' is not 'binaries:test' — skipping"
          echo "should_run=false" >> "$GITHUB_OUTPUT"
          echo "is_pr=false" >> "$GITHUB_OUTPUT"
        fi
```

**Step 3: Update references from `check-binaries` to `check-trigger`**

All downstream jobs use `needs: check-binaries` — update to `needs: check-trigger`:

- `build` job (around line 59)
- `visual-regression` job
- Any other job that references `check-binaries`

Also update the condition to reference the new output:

```yaml
if: needs.check-trigger.outputs.should_run == 'true'
```

For the `visual-regression` job, change its condition from:

```yaml
if: github.event_name == 'pull_request'
```

to:

```yaml
if: needs.check-trigger.outputs.is_pr == 'true'
```

Same for `cross-arch-comparison`.

**Step 4: Add a `finalize` job for test results**

Add a new job at the end that runs after all test and VR jobs, handles label transitions and checklist updates:

```yaml
finalize:
  name: Finalize
  needs:
    [check-trigger, build, execute, visual-regression, cross-arch-comparison]
  if: always() && needs.check-trigger.outputs.is_pr == 'true'
  runs-on: ubuntu-latest
  permissions:
    contents: read
    pull-requests: write
  steps:
    - name: Checkout
      uses: actions/checkout@v6

    - name: Update labels and checklist
      env:
        GH_TOKEN: ${{ github.token }}
        PR_NUMBER: ${{ github.event.pull_request.number }}
      run: |
        REPO="${{ github.repository }}"

        # Determine overall result
        BUILD_RESULT="${{ needs.build.result }}"
        EXECUTE_RESULT="${{ needs.execute.result }}"
        VR_RESULT="${{ needs.visual-regression.result }}"

        # VR and cross-arch are optional (informational) — don't fail on them
        if [ "$BUILD_RESULT" = "success" ] && [ "$EXECUTE_RESULT" = "success" ]; then
          OVERALL="success"
        else
          OVERALL="failure"
        fi

        BODY=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json body --jq .body)
        CURRENT_REV=$(echo "$BODY" | grep -oP '(?<=` → `)\d+(?=`)' | head -1)
        PREV_REV=$(echo "$BODY" | grep -oP '(?<=— `)\d+(?=` →)' | head -1)
        SIZE_LINE=$(echo "$BODY" | grep -oP 'Binaries built and uploaded to S3.*' | head -1)
        if [ -z "$SIZE_LINE" ]; then
          SIZE_LINE="Binaries built and uploaded to S3"
        fi

        if [ "$OVERALL" = "success" ]; then
          # Remove testing + available, add verified
          gh api "repos/${REPO}/issues/${PR_NUMBER}/labels/binaries:testing" -X DELETE 2>/dev/null || true
          gh api "repos/${REPO}/issues/${PR_NUMBER}/labels/binaries:available" -X DELETE 2>/dev/null || true
          gh api "repos/${REPO}/issues/${PR_NUMBER}/labels" -f "labels[]=binaries:verified"

          NEW_CHECKLIST="### Maintainer Checklist
          - [x] Revision bump detected — \`${PREV_REV}\` → \`${CURRENT_REV}\`
          - [x] Build started
          - [x] ${SIZE_LINE}
          - [x] Tests started
          - [x] Tests and visual regression passed"
        else
          # Remove testing, add failed
          gh api "repos/${REPO}/issues/${PR_NUMBER}/labels/binaries:testing" -X DELETE 2>/dev/null || true
          gh api "repos/${REPO}/issues/${PR_NUMBER}/labels" -f "labels[]=binaries:failed"

          NEW_CHECKLIST="### Maintainer Checklist
          - [x] Revision bump detected — \`${PREV_REV}\` → \`${CURRENT_REV}\`
          - [x] Build started
          - [x] ${SIZE_LINE}
          - [x] Tests started
          - [ ] ~~Tests passed~~ — **tests failed** (add \`binaries:test\` to retry) ← you are here"
        fi

        UPDATED=$(echo "$BODY" | perl -0777 -pe "s|<!-- checklist-start -->.*?<!-- checklist-end -->|<!-- checklist-start -->\n${NEW_CHECKLIST}\n<!-- checklist-end -->|s")
        gh pr edit "$PR_NUMBER" --repo "$REPO" --body "$UPDATED"
```

Note: The `finalize` job uses `if: always()` so it runs even when upstream jobs fail. It checks individual job results to determine success vs failure. VR is treated as informational — only `build` and `execute` determine pass/fail.

**Step 5: Verify YAML is valid**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/test.yml'))"`
Expected: No output (success)

**Step 6: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "refactor: trigger tests on binaries:test label, add finalize job with label and checklist management"
```

---

### Task 5: Update `check-pr-binaries.yml` — adjust for new label set

**Files:**

- Modify: `.github/workflows/check-pr-binaries.yml`

The current logic needs minor updates:

- When revision.txt changed: still set `binaries:needed` (same as before)
- When revision.txt NOT changed: set `binaries:verified` instead of `binaries:available` (since no build is needed, the existing binaries are already tested)
- Should also clean up any new labels (`binaries:build`, `binaries:test`, `binaries:testing`, `binaries:verified`)

**Step 1: Update the label lists**

In the "revision changed" path (lines 57-63), update to remove all status labels:

```bash
for LABEL in binaries:available binaries:building binaries:failed binaries:testing binaries:verified binaries:build binaries:test; do
```

In the "revision unchanged" path (lines 80-86), update to remove all status labels and set `binaries:verified`:

```bash
for LABEL in binaries:needed binaries:building binaries:failed binaries:testing binaries:build binaries:test; do
```

And change the label added from `binaries:available` to `binaries:verified`.

**Step 2: Verify YAML is valid**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/check-pr-binaries.yml'))"`
Expected: No output (success)

**Step 3: Commit**

```bash
git add .github/workflows/check-pr-binaries.yml
git commit -m "refactor: update check-pr-binaries for new label state machine"
```

---

### Task 6: Create GitHub labels

**Step 1: Create the new labels via GitHub API**

```bash
# New trigger labels (purple, transient)
gh label create "binaries:build" --color "5319E7" --description "Trigger: start EC2 build" --repo Sparticuz/ch2 --force
gh label create "binaries:test" --color "5319E7" --description "Trigger: run test suite" --repo Sparticuz/ch2 --force

# New status labels
gh label create "binaries:testing" --color "ededed" --description "Tests in progress" --repo Sparticuz/ch2 --force
gh label create "binaries:verified" --color "0E8A16" --description "Tests and VR passed" --repo Sparticuz/ch2 --force
```

**Step 2: Update existing label descriptions for clarity**

```bash
gh label edit "binaries:needed" --description "Binaries need to be built" --repo Sparticuz/ch2
gh label edit "binaries:building" --description "EC2 build in progress" --repo Sparticuz/ch2
gh label edit "binaries:available" --description "Binaries uploaded to S3" --repo Sparticuz/ch2
gh label edit "binaries:failed" --description "Build or tests failed" --repo Sparticuz/ch2
```

No commit needed — labels are repo metadata.

---

### Task 7: Update PR #5 body with checklist markers

Since PR #5 already exists, its body needs the new checklist markers added manually. This is a one-time fix.

**Step 1: Update the PR body**

Use `gh pr edit` to replace the "Next Steps" section with the checklist. Since binaries are already available and tests have already passed for PR #5, set the checklist to reflect the current state.

```bash
# Read current body, replace Next Steps with checklist, update
```

The exact script depends on the current PR body content — adapt at implementation time.

**Step 2: Clean up labels on PR #5**

Remove stale labels and set the correct state:

```bash
gh pr edit 5 --repo Sparticuz/ch2 --remove-label "binaries:needed"
gh pr edit 5 --repo Sparticuz/ch2 --add-label "binaries:verified"
```

---

### Task 8: Push all changes, rebase PR #5, verify

**Step 1: Push master**

```bash
git push origin master
```

**Step 2: Rebase PR #5**

```bash
git checkout chore/chromium-update-1596535
git rebase master
git push --force-with-lease origin chore/chromium-update-1596535
```

**Step 3: Test the full flow**

Since the PR was force-pushed, the `check-pr-binaries.yml` will run. But the real test is the label-triggered flow. Add `binaries:test` to PR #5 to verify:

1. `test.yml` triggers on `binaries:test`
2. Label swaps to `binaries:testing`
3. PR checklist updates to "testing..."
4. On completion, label swaps to `binaries:verified`
5. PR checklist updates to "passed"

**Step 4: Verify all jobs pass**

```bash
gh run list --repo Sparticuz/ch2 --limit 5
gh run view <run-id> --repo Sparticuz/ch2
```

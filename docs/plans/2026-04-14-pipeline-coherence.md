# Pipeline Coherence Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the CI pipeline coherent by merging duplicate test workflows into a matrix, making tests self-triggering for TypeScript-only PRs, simplifying the label workflow to cosmetic-only, and fixing the safety net to cover arm64 instances.

**Architecture:** Replace `test-x64.yml` + `test-arm.yml` (750 duplicated lines) with a single `test.yml` using `matrix.arch: [x64, arm64]`. Add a `check-binaries` job as the first job in `test.yml` that determines whether tests should run (revision unchanged = binaries exist, post-build label = binaries exist, push to master = binaries exist). Simplify `check-pr-binaries.yml` to cosmetic label management only. Extend `build-safety-net.yml` to also terminate `chromium-arm64-libs` instances.

**Tech Stack:** GitHub Actions YAML, shell scripting

---

### Task 1: Create `test.yml` with architecture matrix

**Files:**

- Create: `.github/workflows/test.yml`
- Delete: `.github/workflows/test-x64.yml`
- Delete: `.github/workflows/test-arm.yml`

The new workflow has one top-level matrix: `arch: [x64, arm64]` with an include
block that maps each arch to its runner and any arch-specific tweaks.

**Step 1: Write `.github/workflows/test.yml`**

The workflow structure:

```yaml
name: Test

on:
  push:
    branches: [master]
  pull_request:
    types: [opened, synchronize, reopened, labeled]

jobs:
  # Gate job: decides if tests should run
  check-binaries:
    name: Check binaries (${{ matrix.arch }})
    runs-on: ubuntu-latest
    strategy:
      matrix:
        arch: [x64, arm64]
    outputs:
      # Matrix outputs: use fromJSON to pick the right one downstream
      x64: ${{ steps.decide.outputs.should_run }}
      arm64: ${{ steps.decide.outputs.should_run }}
    permissions:
      contents: read
    steps:
      - name: Decide whether to run
        id: decide
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          # Push to master: always run
          if [ "${{ github.event_name }}" = "push" ]; then
            echo "should_run=true" >> "$GITHUB_OUTPUT"
            echo "Trigger: push to master"
            exit 0
          fi

          # PR labeled with binaries:available: run
          if [ "${{ github.event.action }}" = "labeled" ] && \
             [ "${{ github.event.label.name }}" = "binaries:available" ]; then
            echo "should_run=true" >> "$GITHUB_OUTPUT"
            echo "Trigger: binaries:available label added"
            exit 0
          fi

          # PR labeled with something else: skip
          if [ "${{ github.event.action }}" = "labeled" ]; then
            echo "should_run=false" >> "$GITHUB_OUTPUT"
            echo "Skip: labeled event but not binaries:available"
            exit 0
          fi

          # PR opened/synchronize/reopened: check if revision.txt changed
          CHANGED=$(gh api repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/files \
            --paginate --jq '.[].filename' | grep -c '^_/ec2/revision.txt$' || true)

          if [ "$CHANGED" -eq 0 ]; then
            echo "should_run=true" >> "$GITHUB_OUTPUT"
            echo "Trigger: TypeScript-only PR (revision unchanged, binaries should exist)"
          else
            echo "should_run=false" >> "$GITHUB_OUTPUT"
            echo "Skip: revision.txt changed, waiting for build"
          fi
```

**IMPORTANT:** GitHub Actions matrix outputs are tricky. Each matrix leg writes
its own `should_run` but they're the same logic. The outputs block uses the
matrix value as the key name. This requires a workaround — we can't dynamically
name outputs from matrix values. Instead, use TWO separate `check-binaries` jobs
(one per arch, no matrix), OR use a single non-matrix gate job that outputs both.

**Revised approach:** Use a SINGLE `check-binaries` job (no matrix) that outputs
one `should_run` value. Both architectures always get the same gate decision
(if binaries should exist, they exist for both arches). This is simpler and correct.

```yaml
check-binaries:
  name: Check binary availability
  runs-on: ubuntu-latest
  outputs:
    should_run: ${{ steps.decide.outputs.should_run }}
  permissions:
    contents: read
  steps:
    - name: Decide whether to run
      id: decide
      env:
        GH_TOKEN: ${{ github.token }}
      run: |
        # Push to master: always run
        if [ "${{ github.event_name }}" = "push" ]; then
          echo "should_run=true" >> "$GITHUB_OUTPUT"
          echo "Trigger: push to master"
          exit 0
        fi

        # PR labeled with binaries:available: run
        if [ "${{ github.event.action }}" = "labeled" ] && \
           [ "${{ github.event.label.name }}" = "binaries:available" ]; then
          echo "should_run=true" >> "$GITHUB_OUTPUT"
          echo "Trigger: binaries:available label added"
          exit 0
        fi

        # PR labeled with something else: skip
        if [ "${{ github.event.action }}" = "labeled" ]; then
          echo "should_run=false" >> "$GITHUB_OUTPUT"
          echo "Skip: labeled event but not binaries:available"
          exit 0
        fi

        # PR opened/synchronize/reopened: check if revision.txt changed
        CHANGED=$(gh api repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/files \
          --paginate --jq '.[].filename' | grep -c '^_/ec2/revision.txt$' || true)

        if [ "$CHANGED" -eq 0 ]; then
          echo "should_run=true" >> "$GITHUB_OUTPUT"
          echo "Trigger: TypeScript-only PR (revision unchanged)"
        else
          echo "should_run=false" >> "$GITHUB_OUTPUT"
          echo "Skip: revision.txt changed, waiting for build"
        fi
```

Then the `build` job:

```yaml
build:
  needs: check-binaries
  if: needs.check-binaries.outputs.should_run == 'true'
  name: Build & Test (${{ matrix.arch }})
  runs-on: ${{ matrix.runner }}
  strategy:
    matrix:
      arch: [x64, arm64]
      include:
        - arch: x64
          runner: ubuntu-latest
        - arch: arm64
          runner: ubuntu-24.04-arm
  permissions:
    contents: read
    pull-requests: write
  steps:
    - name: Checkout
      uses: actions/checkout@v6

    - name: Get chromium revision
      id: revision
      run: |
        REVISION=$(cat _/ec2/revision.txt)
        echo "revision=${REVISION}" >> "$GITHUB_OUTPUT"

    - name: Download binaries from S3
      env:
        AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
        AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        AWS_DEFAULT_REGION: us-east-1
        S3_BUCKET: ${{ secrets.CHROMIUM_BUILD_S3_BUCKET }}
      run: |
        REVISION="${{ steps.revision.outputs.revision }}"
        mkdir -p bin/${{ matrix.arch }}

        # Download arch-specific binaries
        aws s3 sync "s3://${S3_BUCKET}/${REVISION}/${{ matrix.arch }}/" bin/${{ matrix.arch }}/ --exclude "*.json"

        # Download fonts
        aws s3 cp "s3://${S3_BUCKET}/${REVISION}/fonts.tar.br" bin/fonts.tar.br || true

        # Copy to bin root for tests (Makefile presource does this too, but
        # we need them in place before npm run test:source)
        cp bin/${{ matrix.arch }}/* bin/ 2>/dev/null || true

    - name: Setup Node.js
      uses: actions/setup-node@v6
      with:
        node-version: 24.x

    - name: Install Packages
      run: npm ci

    - name: Run Source Tests
      run: npm run test:source

    - name: "Report Coverage"
      # Only report coverage once (from x64) to avoid duplicate comments
      if: matrix.arch == 'x64'
      uses: davelosert/vitest-coverage-report-action@v2

    - name: Compile Typescript
      run: npm run build

    - name: Create Lambda Layer
      run: make chromium.${{ matrix.arch }}.zip

    - name: Upload Layer Artifact
      uses: actions/upload-artifact@v7
      with:
        name: chromium.${{ matrix.arch }}.zip
        path: chromium.${{ matrix.arch }}.zip
```

Then the `execute` job:

```yaml
execute:
  needs: build
  name: Lambda ${{ matrix.arch }} (Node ${{ matrix.version }}.x)
  runs-on: ${{ matrix.runner }}
  strategy:
    fail-fast: false
    matrix:
      arch: [x64, arm64]
      version: [20, 22, 24]
      include:
        - arch: x64
          runner: ubuntu-latest
        - arch: arm64
          runner: ubuntu-24.04-arm
  steps:
    - name: Checkout
      uses: actions/checkout@v6

    - name: Setup Python
      uses: actions/setup-python@v6
      with:
        python-version: 3.13

    - name: Setup AWS SAM CLI
      uses: aws-actions/setup-sam@v2

    - name: Download Layer Artifact
      uses: actions/download-artifact@v8
      with:
        name: chromium.${{ matrix.arch }}.zip

    - name: Provision Layer
      run: unzip chromium.${{ matrix.arch }}.zip -d _/amazon/code

    - name: Install test dependencies
      run: npm install --prefix _/amazon/handlers puppeteer-core --bin-links=false --fund=false --omit=optional --omit=dev --package-lock=false --save=false

    - name: Patch template for arm64
      if: matrix.arch == 'arm64'
      run: sed -i 's/x86_64/arm64/g' _/amazon/template.yml

    - name: Invoke Lambda on SAM
      run: sam local invoke --template _/amazon/template.yml --event _/amazon/events/example.com.json node${{ matrix.version }} 2>&1 | (grep 'Error' && exit 1 || exit 0)
```

Then the `visual-regression` job:

```yaml
visual-regression:
  needs: build
  # Only on PRs, not pushes to master
  if: github.event_name == 'pull_request'
  name: Visual Regression (${{ matrix.arch }})
  runs-on: ${{ matrix.runner }}
  strategy:
    matrix:
      arch: [x64, arm64]
      include:
        - arch: x64
          runner: ubuntu-latest
        - arch: arm64
          runner: ubuntu-24.04-arm
  permissions:
    contents: read
    pull-requests: write
  env:
    AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
    AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    AWS_DEFAULT_REGION: us-east-1
    S3_BUCKET: ${{ secrets.CHROMIUM_BUILD_S3_BUCKET }}

  steps:
    - name: Checkout
      uses: actions/checkout@v6
      with:
        fetch-depth: 0

    - name: Setup Node.js
      uses: actions/setup-node@v6
      with:
        node-version: 24.x

    - name: Get chromium revision
      id: revision
      run: |
        REVISION=$(cat _/ec2/revision.txt)
        echo "revision=${REVISION}" >> "$GITHUB_OUTPUT"

    - name: Download binaries from S3
      run: |
        REVISION="${{ steps.revision.outputs.revision }}"
        mkdir -p bin/${{ matrix.arch }}
        aws s3 sync "s3://${S3_BUCKET}/${REVISION}/${{ matrix.arch }}/" bin/${{ matrix.arch }}/ --exclude "*.json"
        aws s3 cp "s3://${S3_BUCKET}/${REVISION}/fonts.tar.br" bin/fonts.tar.br || true
        cp bin/${{ matrix.arch }}/* bin/ 2>/dev/null || true

    - name: Install dependencies
      run: |
        npm ci
        npm install --no-save odiff-bin

    - name: Take screenshots
      run: node tools/visual-regression.mjs /tmp/screenshots/current

    - name: Upload current screenshots to S3
      run: |
        REVISION="${{ steps.revision.outputs.revision }}"
        aws s3 sync /tmp/screenshots/current/ "s3://${S3_BUCKET}/${REVISION}/screenshots/${{ matrix.arch }}/" \
          --exclude "manifest.json"

    - name: Resolve baseline revision
      id: baseline
      run: |
        LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
        if [ -z "$LATEST_TAG" ]; then
          echo "No tags found — no baseline"
          echo "has_baseline=false" >> "$GITHUB_OUTPUT"
          exit 0
        fi

        BASELINE_REV=$(git show "${LATEST_TAG}:_/ec2/revision.txt" 2>/dev/null || echo "")
        if [ -z "$BASELINE_REV" ]; then
          echo "Could not read revision.txt from ${LATEST_TAG}"
          echo "has_baseline=false" >> "$GITHUB_OUTPUT"
          exit 0
        fi

        if aws s3 ls "s3://${S3_BUCKET}/${BASELINE_REV}/screenshots/${{ matrix.arch }}/example.com.png" >/dev/null 2>&1; then
          echo "Baseline found: ${LATEST_TAG} (revision ${BASELINE_REV})"
          echo "has_baseline=true" >> "$GITHUB_OUTPUT"
          echo "revision=${BASELINE_REV}" >> "$GITHUB_OUTPUT"
          echo "tag=${LATEST_TAG}" >> "$GITHUB_OUTPUT"
        else
          echo "No baseline screenshots in S3 for ${BASELINE_REV}"
          echo "has_baseline=false" >> "$GITHUB_OUTPUT"
        fi

    - name: Download baseline screenshots
      if: steps.baseline.outputs.has_baseline == 'true'
      run: |
        mkdir -p /tmp/screenshots/baseline
        aws s3 sync "s3://${S3_BUCKET}/${{ steps.baseline.outputs.revision }}/screenshots/${{ matrix.arch }}/" \
          /tmp/screenshots/baseline/ --exclude "*.json" --exclude "*-diff.png"

    - name: Run odiff comparison
      if: steps.baseline.outputs.has_baseline == 'true'
      id: diff
      run: |
        mkdir -p /tmp/screenshots/diff
        DIFF_RESULTS=""

        for PAGE in example.com webgl; do
          BASELINE="/tmp/screenshots/baseline/${PAGE}.png"
          CURRENT="/tmp/screenshots/current/${PAGE}.png"
          DIFF_OUT="/tmp/screenshots/diff/${PAGE}-diff.png"

          if [ ! -f "$BASELINE" ]; then
            DIFF_RESULTS="${DIFF_RESULTS}${PAGE}|no-baseline|0|0\n"
            continue
          fi

          RESULT=$(npx odiff "$BASELINE" "$CURRENT" "$DIFF_OUT" 2>&1) || true
          DIFF_COUNT=$(echo "$RESULT" | grep -oP 'diffCount:\s*\K\d+' || echo "0")
          DIFF_PCT=$(echo "$RESULT" | grep -oP 'diffPercentage:\s*\K[\d.]+' || echo "0")

          if [ -f "$DIFF_OUT" ]; then
            DIFF_RESULTS="${DIFF_RESULTS}${PAGE}|changed|${DIFF_COUNT}|${DIFF_PCT}\n"
          else
            DIFF_RESULTS="${DIFF_RESULTS}${PAGE}|match|0|0.00\n"
          fi
        done

        echo "results<<EOF" >> "$GITHUB_OUTPUT"
        echo -e "$DIFF_RESULTS" >> "$GITHUB_OUTPUT"
        echo "EOF" >> "$GITHUB_OUTPUT"

    - name: Upload diff images to S3
      if: steps.baseline.outputs.has_baseline == 'true'
      run: |
        REVISION="${{ steps.revision.outputs.revision }}"
        if ls /tmp/screenshots/diff/*-diff.png 1>/dev/null 2>&1; then
          aws s3 sync /tmp/screenshots/diff/ "s3://${S3_BUCKET}/${REVISION}/screenshots/${{ matrix.arch }}/" \
            --exclude "*" --include "*-diff.png"
        fi

    - name: Generate presigned URLs
      id: urls
      run: |
        REVISION="${{ steps.revision.outputs.revision }}"
        BASELINE_REV="${{ steps.baseline.outputs.revision }}"
        HAS_BASELINE="${{ steps.baseline.outputs.has_baseline }}"
        ARCH="${{ matrix.arch }}"
        URLS=""

        for PAGE in example.com webgl; do
          CURRENT_URL=$(aws s3 presign "s3://${S3_BUCKET}/${REVISION}/screenshots/${ARCH}/${PAGE}.png" --expires-in 604800)
          URLS="${URLS}${PAGE}_current=${CURRENT_URL}\n"

          if [ "$HAS_BASELINE" = "true" ] && [ -n "$BASELINE_REV" ]; then
            BASELINE_URL=$(aws s3 presign "s3://${S3_BUCKET}/${BASELINE_REV}/screenshots/${ARCH}/${PAGE}.png" --expires-in 604800) || true
            URLS="${URLS}${PAGE}_baseline=${BASELINE_URL}\n"

            if [ -f "/tmp/screenshots/diff/${PAGE}-diff.png" ]; then
              DIFF_URL=$(aws s3 presign "s3://${S3_BUCKET}/${REVISION}/screenshots/${ARCH}/${PAGE}-diff.png" --expires-in 604800) || true
              URLS="${URLS}${PAGE}_diff=${DIFF_URL}\n"
            fi
          fi
        done

        echo -e "$URLS" > /tmp/screenshots/urls.txt

    - name: Post PR comment
      env:
        GH_TOKEN: ${{ github.token }}
        PR_NUMBER: ${{ github.event.pull_request.number }}
        HAS_BASELINE: ${{ steps.baseline.outputs.has_baseline }}
        BASELINE_TAG: ${{ steps.baseline.outputs.tag }}
      run: |
        REVISION="${{ steps.revision.outputs.revision }}"
        ARCH="${{ matrix.arch }}"
        MANIFEST=$(cat /tmp/screenshots/current/manifest.json)

        while IFS='=' read -r KEY VAL; do
          [ -n "$KEY" ] && export "URL_${KEY}=${VAL}"
        done < /tmp/screenshots/urls.txt

        EXAMPLE_HASH=$(echo "$MANIFEST" | jq -r '.["example.com"].hash')
        WEBGL_HASH=$(echo "$MANIFEST" | jq -r '.webgl.hash')

        if [ "$HAS_BASELINE" = "true" ]; then
          BASELINE_MANIFEST=$(cat /tmp/screenshots/baseline/manifest.json 2>/dev/null || echo '{}')
          BASELINE_EXAMPLE_HASH=$(echo "$BASELINE_MANIFEST" | jq -r '.["example.com"].hash // "n/a"')
          BASELINE_WEBGL_HASH=$(echo "$BASELINE_MANIFEST" | jq -r '.webgl.hash // "n/a"')

          EXAMPLE_STATUS="Match"
          if [ "$EXAMPLE_HASH" != "$BASELINE_EXAMPLE_HASH" ]; then EXAMPLE_STATUS="Changed"; fi
          WEBGL_STATUS="Match"
          if [ "$WEBGL_HASH" != "$BASELINE_WEBGL_HASH" ]; then WEBGL_STATUS="Changed"; fi

          EXAMPLE_IMG_ROW="| example.com | ![baseline](${URL_example_com_baseline}) | ![current](${URL_example_com_current})"
          if [ -n "${URL_example_com_diff:-}" ]; then
            EXAMPLE_IMG_ROW="${EXAMPLE_IMG_ROW} | ![diff](${URL_example_com_diff})"
          else
            EXAMPLE_IMG_ROW="${EXAMPLE_IMG_ROW} | (identical)"
          fi
          EXAMPLE_IMG_ROW="${EXAMPLE_IMG_ROW} |"

          WEBGL_IMG_ROW="| WebGL | ![baseline](${URL_webgl_baseline}) | ![current](${URL_webgl_current})"
          if [ -n "${URL_webgl_diff:-}" ]; then
            WEBGL_IMG_ROW="${WEBGL_IMG_ROW} | ![diff](${URL_webgl_diff})"
          else
            WEBGL_IMG_ROW="${WEBGL_IMG_ROW} | (identical)"
          fi
          WEBGL_IMG_ROW="${WEBGL_IMG_ROW} |"

          cat > /tmp/screenshots/comment.md <<EOF
        ## Visual Regression (${ARCH})

        Baseline: \`${BASELINE_TAG}\` | Current revision: \`${REVISION}\`

        | Page | Baseline | Current | Diff |
        |------|----------|---------|------|
        ${EXAMPLE_IMG_ROW}
        ${WEBGL_IMG_ROW}

        | Page | Baseline Hash | Current Hash | Status |
        |------|--------------|--------------|--------|
        | example.com | \`${BASELINE_EXAMPLE_HASH:0:16}...\` | \`${EXAMPLE_HASH:0:16}...\` | ${EXAMPLE_STATUS} |
        | WebGL | \`${BASELINE_WEBGL_HASH:0:16}...\` | \`${WEBGL_HASH:0:16}...\` | ${WEBGL_STATUS} |

        <details><summary>Full hashes</summary>

        | Page | Hash |
        |------|------|
        | example.com (baseline) | \`${BASELINE_EXAMPLE_HASH}\` |
        | example.com (current) | \`${EXAMPLE_HASH}\` |
        | WebGL (baseline) | \`${BASELINE_WEBGL_HASH}\` |
        | WebGL (current) | \`${WEBGL_HASH}\` |

        </details>

        *Presigned URLs expire in 7 days.*
        EOF
        else
          cat > /tmp/screenshots/comment.md <<EOF
        ## Visual Regression (${ARCH})

        No baseline screenshots found — first capture for revision \`${REVISION}\`.

        | Page | Screenshot |
        |------|-----------|
        | example.com | ![current](${URL_example_com_current}) |
        | WebGL | ![current](${URL_webgl_current}) |

        | Page | Hash |
        |------|------|
        | example.com | \`${EXAMPLE_HASH}\` |
        | WebGL | \`${WEBGL_HASH}\` |

        *Presigned URLs expire in 7 days.*
        EOF
        fi

        gh pr comment "$PR_NUMBER" --body-file /tmp/screenshots/comment.md
```

**Step 2: Delete old workflows**

```bash
rm .github/workflows/test-x64.yml .github/workflows/test-arm.yml
```

**Step 3: Validate YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/test.yml'))"
```

**Step 4: Commit**

```bash
git add .github/workflows/test.yml .github/workflows/test-x64.yml .github/workflows/test-arm.yml
git commit -m "refactor: merge test-x64 and test-arm into matrix-based test.yml

Replaces two 375-line workflows with a single workflow using
matrix.arch: [x64, arm64]. Adds a check-binaries gate job that
makes tests self-triggering for TypeScript-only PRs (no label
dependency). Tests still trigger via binaries:available label
for the post-build path."
```

**Design notes:**

- Screenshots S3 path changes from `{rev}/screenshots/` to `{rev}/screenshots/{arch}/`
  to avoid x64 and arm64 overwriting each other's screenshots. This is a new
  convention — no existing screenshots exist yet, so no migration needed.
- Coverage report only runs on x64 leg to avoid duplicate PR comments.
- `check-binaries` is a single non-matrix job — the gate decision is the same
  for both architectures. This avoids matrix output complexity.
- `visual-regression` only runs on PRs (not push to master) — same as before.

---

### Task 2: Simplify `check-pr-binaries.yml` to cosmetic-only

**Files:**

- Modify: `.github/workflows/check-pr-binaries.yml`

The workflow no longer needs to add `binaries:available` for non-revision PRs
because the test workflow's `check-binaries` job handles that logic. But we keep
it for maintainer visibility — it's helpful to see labels on PRs.

**Step 1: Remove the `binaries:available` auto-add for non-revision PRs**

Actually, on reflection: the labels are purely for human visibility. Adding
`binaries:available` for TypeScript-only PRs is still semantically correct —
binaries DO exist for that revision. And `check-pr-binaries` uses GITHUB_TOKEN,
so the label addition won't trigger any workflow (which is fine now that tests
are self-contained). Keep the workflow exactly as-is. No changes needed.

**Step 2: Skip — no changes needed**

The workflow is already correct for its cosmetic-only role. Labels are for humans.
GITHUB_TOKEN label events don't trigger other workflows, and tests no longer
depend on them.

---

### Task 3: Fix `build-safety-net.yml` to terminate arm64 instances

**Files:**

- Modify: `.github/workflows/build-safety-net.yml:66-71`

**Step 1: Extend tag-based termination to include arm64 instances**

In `build-safety-net.yml`, after the existing tag-based termination of
`chromium-build` instances, add termination of `chromium-arm64-libs` instances:

Find this block (around line 66):

```bash
              # Terminate by tag as fallback
              TAGGED_IDS=$(aws ec2 describe-instances \
                --filters "Name=tag:Name,Values=chromium-build" "Name=instance-state-name,Values=running,pending" \
                --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)
              if [ -n "$TAGGED_IDS" ]; then
                aws ec2 terminate-instances --instance-ids $TAGGED_IDS || true
              fi
```

Replace with:

```bash
              # Terminate by tag as fallback (both build and arm64 libs instances)
              for TAG_NAME in chromium-build chromium-arm64-libs; do
                TAGGED_IDS=$(aws ec2 describe-instances \
                  --filters "Name=tag:Name,Values=${TAG_NAME}" "Name=instance-state-name,Values=running,pending" \
                  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)
                if [ -n "$TAGGED_IDS" ]; then
                  echo "Terminating ${TAG_NAME} instances: ${TAGGED_IDS}"
                  aws ec2 terminate-instances --instance-ids $TAGGED_IDS || true
                fi
              done
```

**Step 2: Validate YAML**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-safety-net.yml'))"
```

**Step 3: Commit**

```bash
git add .github/workflows/build-safety-net.yml
git commit -m "fix: safety net now terminates arm64 libs instances too

The tag-based fallback termination only looked for 'chromium-build'
instances. Now also terminates 'chromium-arm64-libs' instances to
prevent stale arm64 lib packaging instances from surviving cleanup."
```

---

### Task 4: Update documentation

**Files:**

- Modify: `CONTRIBUTING.md`

**Step 1: Update CONTRIBUTING.md**

The Troubleshooting section "Labels added by workflow don't trigger builds" should
be updated to explain the full picture — labels are cosmetic, tests self-trigger.

Find:

```markdown
### Labels added by workflow don't trigger builds

This is by design. GitHub does not trigger workflows from label events caused by
`GITHUB_TOKEN` (prevents infinite loops). The `binaries:building` label must be
added manually by a maintainer.
```

Replace with:

```markdown
### Labels added by workflow don't trigger builds

This is by design. GitHub does not trigger workflows from label events caused by
`GITHUB_TOKEN` (prevents infinite loops). Labels managed by `check-pr-binaries`
are cosmetic — for maintainer visibility only. The test workflow self-determines
whether to run by checking if `revision.txt` changed in the PR.

The `binaries:building` label must always be added manually by a maintainer.
After a build completes, `build-complete.yml` adds `binaries:available` using
`RELEASE_TOKEN` (a PAT), which does trigger the test workflow.
```

**Step 2: Commit**

```bash
git add CONTRIBUTING.md
git commit -m "docs: update troubleshooting for self-triggering test workflow"
```

---

### Task 5: Final validation

**Step 1: Validate all YAML files**

```bash
python3 -c "
import yaml, sys, glob
files = glob.glob('.github/workflows/*.yml')
for f in sorted(files):
    try:
        yaml.safe_load(open(f))
        print(f'OK: {f}')
    except yaml.YAMLError as e:
        print(f'ERROR: {f}: {e}')
        sys.exit(1)
print(f'All {len(files)} workflows valid.')
"
```

**Step 2: Verify no references to deleted workflows**

```bash
rg 'test-x64|test-arm' .github/ CONTRIBUTING.md _/ec2/README.md
```

Fix any stale references.

**Step 3: Verify the pipeline flow is coherent**

Manually trace each trigger path:

1. TypeScript PR opened → `check-binaries` says should_run=true → tests run ✓
2. Revision PR opened → `check-binaries` says should_run=false → tests skip ✓
3. Build completes → `binaries:available` added via PAT → `labeled` event →
   `check-binaries` says should_run=true → tests run ✓
4. Push to master → `check-binaries` says should_run=true → tests run ✓
5. Safety net fires → terminates both build and arm64 libs instances ✓

**Step 4: Squash or amend commits if desired, then push**

```bash
git push
```

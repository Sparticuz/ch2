# Visual Regression Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** After integration tests, post a PR comment with side-by-side screenshot comparisons (baseline vs current vs diff) using odiff and S3 presigned URLs.

**Architecture:** A new `visual-regression` job in both test workflows runs Chromium directly on the GHA runner (not in SAM), takes screenshots of example.com and get.webgl.org, compares against the previous release's screenshots stored in S3 using odiff, uploads all images to S3, and posts a PR comment with presigned URLs and hash comparison.

**Tech Stack:** odiff-bin (installed ad-hoc in workflow), puppeteer-core (already a devDependency), AWS CLI for S3, gh CLI for PR comments.

---

### Task 1: Create the screenshot script

**Files:**

- Create: `tools/visual-regression.mjs`

This Node.js script takes screenshots of the two test pages using the Chromium binary from `bin/`, computes SHA-256 hashes, and writes PNGs + a JSON manifest to an output directory.

**Step 1: Create `tools/visual-regression.mjs`**

```javascript
#!/usr/bin/env node
// tools/visual-regression.mjs
// Takes screenshots of test pages using the packaged Chromium binary.
// Usage: node tools/visual-regression.mjs <output-dir>
//
// Writes to <output-dir>/:
//   example.com.png   — screenshot of https://example.com
//   webgl.png         — screenshot of https://get.webgl.org (logo removed)
//   manifest.json     — { "example.com": { hash: "..." }, "webgl": { hash: "..." } }

import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createHash } from "node:crypto";
import puppeteer from "puppeteer-core";
import chromium from "@sparticuz/chromium";

const OUTPUT_DIR = process.argv[2];
if (!OUTPUT_DIR) {
  console.error("Usage: node tools/visual-regression.mjs <output-dir>");
  process.exit(1);
}

await mkdir(OUTPUT_DIR, { recursive: true });

const pages = [
  {
    name: "example.com",
    url: "https://example.com",
  },
  {
    name: "webgl",
    url: "https://get.webgl.org",
    remove: "logo-container",
  },
];

const browser = await puppeteer.launch({
  args: puppeteer.defaultArgs({
    args: chromium.args,
    headless: "shell",
  }),
  defaultViewport: {
    deviceScaleFactor: 1,
    hasTouch: false,
    height: 1080,
    isLandscape: true,
    isMobile: false,
    width: 1920,
  },
  executablePath: await chromium.executablePath(),
  headless: "shell",
});

console.log("Chromium version:", await browser.version());

const manifest = {};

for (const job of pages) {
  const page = await browser.newPage();
  await page.goto(job.url, { waitUntil: ["domcontentloaded", "load"] });

  if (job.remove) {
    await page.evaluate((selector) => {
      document.getElementById(selector)?.remove();
    }, job.remove);
  }

  const screenshot = Buffer.from(await page.screenshot());
  const pngPath = join(OUTPUT_DIR, `${job.name}.png`);
  await writeFile(pngPath, screenshot);

  // Hash matches the existing test approach: hash the data URI string
  const base64 = `data:image/png;base64,${screenshot.toString("base64")}`;
  const hash = createHash("sha256").update(base64).digest("hex");

  manifest[job.name] = { hash };
  console.log(`${job.name}: ${hash}`);
  await page.close();
}

await writeFile(
  join(OUTPUT_DIR, "manifest.json"),
  JSON.stringify(manifest, null, 2),
);

for (const page of await browser.pages()) {
  await page.close();
}
await browser.close();

console.log(`Screenshots saved to ${OUTPUT_DIR}`);
```

**Step 2: Verify the script runs locally (manual, optional)**

```bash
# Requires binaries in bin/
node tools/visual-regression.mjs /tmp/vr-test
ls /tmp/vr-test/
cat /tmp/vr-test/manifest.json
```

**Step 3: Commit**

```bash
git add tools/visual-regression.mjs
git commit -m "feat: add visual regression screenshot script"
```

---

### Task 2: Add visual-regression job to test-x64.yml

**Files:**

- Modify: `.github/workflows/test-x64.yml`

Add a new `visual-regression` job that depends on the `build` job. It downloads
the layer artifact, unpacks it, installs puppeteer-core and odiff-bin, runs the
screenshot script, downloads baseline from S3, runs odiff, uploads everything
to S3, and posts a PR comment.

**Step 1: Add the visual-regression job**

After the existing `execute` job in `test-x64.yml`, add:

```yaml
  visual-regression:
    # Only run on PRs (not pushes to master) when binaries are available
    if: >-
      github.event_name == 'pull_request' &&
      contains(github.event.pull_request.labels.*.name, 'binaries:available')
    name: Visual Regression (x64)
    needs: build
    runs-on: ubuntu-latest
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
          fetch-depth: 0  # Need tags for baseline resolution

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
          mkdir -p bin/x64
          aws s3 sync "s3://${S3_BUCKET}/${REVISION}/x64/" bin/x64/ --exclude "*.json"
          aws s3 cp "s3://${S3_BUCKET}/${REVISION}/fonts.tar.br" bin/fonts.tar.br || true
          cp bin/x64/* bin/ 2>/dev/null || true

      - name: Install dependencies
        run: |
          npm ci
          npm install --no-save odiff-bin

      - name: Take screenshots
        run: node tools/visual-regression.mjs /tmp/screenshots/current

      - name: Upload current screenshots to S3
        run: |
          REVISION="${{ steps.revision.outputs.revision }}"
          aws s3 sync /tmp/screenshots/current/ "s3://${S3_BUCKET}/${REVISION}/screenshots/" \
            --exclude "manifest.json"

      - name: Resolve baseline revision
        id: baseline
        run: |
          # Find the latest release tag
          LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
          if [ -z "$LATEST_TAG" ]; then
            echo "No tags found — no baseline"
            echo "has_baseline=false" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          # Read the revision from that tag
          BASELINE_REV=$(git show "${LATEST_TAG}:_/ec2/revision.txt" 2>/dev/null || echo "")
          if [ -z "$BASELINE_REV" ]; then
            echo "Could not read revision.txt from ${LATEST_TAG}"
            echo "has_baseline=false" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          # Check if baseline screenshots exist in S3
          if aws s3 ls "s3://${S3_BUCKET}/${BASELINE_REV}/screenshots/example.com.png" >/dev/null 2>&1; then
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
          aws s3 sync "s3://${S3_BUCKET}/${{ steps.baseline.outputs.revision }}/screenshots/" \
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

            # Run odiff — exit code 0=match, 1=diff, 2=error
            RESULT=$(npx odiff "$BASELINE" "$CURRENT" "$DIFF_OUT" 2>&1) || true
            DIFF_COUNT=$(echo "$RESULT" | grep -oP 'diffCount:\s*\K\d+' || echo "0")
            DIFF_PCT=$(echo "$RESULT" | grep -oP 'diffPercentage:\s*\K[\d.]+' || echo "0")

            # Check if diff image was created (only created if pixels differ)
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
            aws s3 sync /tmp/screenshots/diff/ "s3://${S3_BUCKET}/${REVISION}/screenshots/" \
              --exclude "*" --include "*-diff.png"
          fi

      - name: Generate presigned URLs
        id: urls
        run: |
          REVISION="${{ steps.revision.outputs.revision }}"
          BASELINE_REV="${{ steps.baseline.outputs.revision }}"
          HAS_BASELINE="${{ steps.baseline.outputs.has_baseline }}"
          URLS=""

          for PAGE in example.com webgl; do
            CURRENT_URL=$(aws s3 presign "s3://${S3_BUCKET}/${REVISION}/screenshots/${PAGE}.png" --expires-in 604800)
            URLS="${URLS}${PAGE}_current=${CURRENT_URL}\n"

            if [ "$HAS_BASELINE" = "true" ] && [ -n "$BASELINE_REV" ]; then
              BASELINE_URL=$(aws s3 presign "s3://${S3_BUCKET}/${BASELINE_REV}/screenshots/${PAGE}.png" --expires-in 604800) || true
              URLS="${URLS}${PAGE}_baseline=${BASELINE_URL}\n"

              if [ -f "/tmp/screenshots/diff/${PAGE}-diff.png" ]; then
                DIFF_URL=$(aws s3 presign "s3://${S3_BUCKET}/${REVISION}/screenshots/${PAGE}-diff.png" --expires-in 604800) || true
                URLS="${URLS}${PAGE}_diff=${DIFF_URL}\n"
              fi
            fi
          done

          # Write URLs to a file (too large for GITHUB_OUTPUT)
          echo -e "$URLS" > /tmp/screenshots/urls.txt

      - name: Post PR comment
        env:
          GH_TOKEN: ${{ github.token }}
          PR_NUMBER: ${{ github.event.pull_request.number }}
          HAS_BASELINE: ${{ steps.baseline.outputs.has_baseline }}
          BASELINE_TAG: ${{ steps.baseline.outputs.tag }}
        run: |
          REVISION="${{ steps.revision.outputs.revision }}"
          MANIFEST=$(cat /tmp/screenshots/current/manifest.json)

          # Parse URLs
          source <(sed 's/=/ /' /tmp/screenshots/urls.txt | while read KEY VAL; do
            echo "export URL_${KEY}=\"${VAL}\""
          done)

          # Read current hashes
          EXAMPLE_HASH=$(echo "$MANIFEST" | jq -r '.["example.com"].hash')
          WEBGL_HASH=$(echo "$MANIFEST" | jq -r '.webgl.hash')

          if [ "$HAS_BASELINE" = "true" ]; then
            BASELINE_MANIFEST=$(cat /tmp/screenshots/baseline/manifest.json 2>/dev/null || echo '{}')
            BASELINE_EXAMPLE_HASH=$(echo "$BASELINE_MANIFEST" | jq -r '.["example.com"].hash // "n/a"')
            BASELINE_WEBGL_HASH=$(echo "$BASELINE_MANIFEST" | jq -r '.webgl.hash // "n/a"')

            # Determine status
            EXAMPLE_STATUS="Match"
            if [ "$EXAMPLE_HASH" != "$BASELINE_EXAMPLE_HASH" ]; then EXAMPLE_STATUS="Changed"; fi
            WEBGL_STATUS="Match"
            if [ "$WEBGL_HASH" != "$BASELINE_WEBGL_HASH" ]; then WEBGL_STATUS="Changed"; fi

            # Build image table rows
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

            BODY="## Visual Regression (x64)

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

*Presigned URLs expire in 7 days.*"
          else
            BODY="## Visual Regression (x64)

No baseline screenshots found — first capture for revision \`${REVISION}\`.

| Page | Screenshot |
|------|-----------|
| example.com | ![current](${URL_example_com_current}) |
| WebGL | ![current](${URL_webgl_current}) |

| Page | Hash |
|------|------|
| example.com | \`${EXAMPLE_HASH}\` |
| WebGL | \`${WEBGL_HASH}\` |

*Presigned URLs expire in 7 days.*"
          fi

          gh pr comment "$PR_NUMBER" --body "$BODY"
```

**Step 2: Commit**

```bash
git add .github/workflows/test-x64.yml
git commit -m "feat: add visual regression job to x64 test workflow"
```

---

### Task 3: Add visual-regression job to test-arm.yml

**Files:**

- Modify: `.github/workflows/test-arm.yml`

Same job as Task 2, adapted for arm64:

- Runs on `ubuntu-24.04-arm`
- Downloads arm64 binaries instead of x64
- PR comment header says "Visual Regression (arm64)"

**Step 1: Add the visual-regression job (same structure as x64, with arm64 changes)**

The job is identical to Task 2 except:

- `runs-on: ubuntu-24.04-arm`
- S3 sync from `arm64/` instead of `x64/`
- `cp bin/arm64/* bin/`
- Comment title: `## Visual Regression (arm64)`

**Step 2: Commit**

```bash
git add .github/workflows/test-arm.yml
git commit -m "feat: add visual regression job to arm64 test workflow"
```

---

### Task 4: Update design doc and CONTRIBUTING.md

**Files:**

- Modify: `CONTRIBUTING.md`
- Update: `docs/plans/2026-04-14-visual-regression-design.md` (mark as implemented)

**Step 1: Add a section to CONTRIBUTING.md under Build System about visual regression**

Add after the "Safety Net" section:

```markdown
### Visual Regression

When the test workflows run on a PR with `binaries:available`, a visual
regression job takes screenshots of `example.com` and `get.webgl.org` using the
new Chromium binary, compares them against the previous release's screenshots
using [odiff](https://github.com/dmtrKovalenko/odiff), and posts a PR comment
with:

- Side-by-side images (baseline, current, diff) via S3 presigned URLs
- SHA-256 hashes for each screenshot
- Match/changed status

This is informational only — visual changes don't block the workflow. If hashes
changed, update the expected values in `_/amazon/events/example.com.json` and
in `tests/chromium.test.ts`.
```

**Step 2: Commit**

```bash
git add CONTRIBUTING.md docs/plans/2026-04-14-visual-regression-design.md
git commit -m "docs: add visual regression section to CONTRIBUTING.md"
```

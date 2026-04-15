# Visual Regression Screenshots Design

> **Status:** Implemented (2026-04-14)

## Summary

After integration tests run in the GHA test workflows, save screenshots to S3,
download the previous release's screenshots as baseline, run `odiff` to produce
diff images, and post a PR comment with presigned URL images and hash comparison.

## Goals

- Make rendering changes visible in PR review without manual inspection
- Provide side-by-side comparison (baseline, current, diff) for each test page
- Show SHA-256 hashes so reviewers know if expected hashes need updating
- Purely informational — does not block the workflow on visual differences

## Test Pages

1. `example.com` — basic HTML rendering test
2. `get.webgl.org` — WebGL rendering test (with `#logo-container` removed)

## Architecture

### Screenshot Capture

The SAM Lambda handler (`_/amazon/handlers/index.mjs`) already takes screenshots
and hashes them. Modify it to also write the raw PNG to `/tmp/screenshots/`. SAM
local invoke mounts `/tmp` from the host, so the workflow can access the files.

### S3 Layout

```
REVISION/
  screenshots/
    example.com.png         # current build
    webgl.png               # current build
    example.com-diff.png    # diff against baseline
    webgl-diff.png          # diff against baseline
```

### Baseline Resolution

The baseline is the previous release's screenshots:

```
latest git tag → read that tag's _/ec2/revision.txt → download from S3
```

If no baseline exists (first build, or baseline revision has no screenshots),
the comment shows only the current screenshots with a note.

### Diff Tool

`odiff-bin` — installed in the workflow only (not a project dependency). Produces
diff PNGs and returns `diffPercentage` and `diffCount`.

### PR Comment

Uses S3 presigned URLs (7-day expiry) for all images. Format:

```markdown
## Visual Regression (x64)

| Page        | Baseline               | Current               | Diff               |
| ----------- | ---------------------- | --------------------- | ------------------ |
| example.com | ![baseline](presigned) | ![current](presigned) | ![diff](presigned) |
| WebGL       | ![baseline](presigned) | ![current](presigned) | ![diff](presigned) |

| Page        | Baseline Hash | Current Hash  | Status  | Diff % |
| ----------- | ------------- | ------------- | ------- | ------ |
| example.com | `bcafb911...` | `bcafb911...` | Match   | 0.00%  |
| WebGL       | `b2b99192...` | `a1c3f200...` | Changed | 0.12%  |
```

### Shared Baseline

Screenshots use a single shared baseline (not per-architecture). Both x64 and
arm64 test workflows compare against the same baseline revision's screenshots.

## Changes Required

### `_/amazon/handlers/index.mjs`

- Write each screenshot PNG to `/tmp/screenshots/{page-name}.png`
- Continue returning hash results as before (no behavior change)

### `test-x64.yml` / `test-arm.yml`

New steps after SAM invoke in the `execute` job:

1. Upload new screenshots to `s3://BUCKET/REVISION/screenshots/`
2. Resolve baseline revision from latest git tag
3. Download baseline screenshots from S3
4. Install `odiff-bin`, run diff on each pair
5. Upload diff PNGs to S3
6. Generate presigned URLs (7 days)
7. Post PR comment with images and hash table

### IAM

No changes needed — existing policy covers `s3:PutObject`, `s3:GetObject`,
and presigned URL generation.

## What Stays the Same

- Hash-based test assertions in `chromium.test.ts` and `index.mjs`
- Pass/fail behavior based on exact hash match
- The visual regression comment is informational only
- No new runtime dependencies

# Revision Manifest (`manifest.json`) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a single `s3://{bucket}/{rev}/manifest.json` that is the authoritative metadata document for a revision — containing chrome version, build timestamp, per-arch binary checksums/sizes, and per-arch screenshot hashes.

**Architecture:** EC2 teardown creates the manifest with build metadata + binary info. The arm64-libs instance contributes its artifact data. VR jobs in test.yml append screenshot hashes via read-modify-write. Consumers (VR PR comments, build-complete comments, release workflow) read from manifest instead of ad-hoc sources.

**Tech Stack:** python3 on EC2 (consistent with build.json), jq on GHA runners.

---

### Task 1: Create manifest in EC2 teardown

**Files:**

- Modify: `_/ec2/teardown.sh:17-48`

After finalizing `build.json`, compute sha256 checksums and sizes for all uploaded binaries, then write `manifest.json` to S3.

**Step 1: Add manifest generation to teardown.sh**

After the existing `build.json` finalization block (line 48), add a new block that:

- Computes `sha256sum` and `stat -c%s` for each artifact (6 binaries + fonts)
- Writes `manifest.json` via python3 with structure:

```json
{
  "revision": "1596535",
  "chrome_version": "147.0.7727.56",
  "built_at": "2026-04-15T12:00:00Z",
  "x64": {
    "binaries": {
      "chromium.br": { "size": 12345678, "sha256": "abc..." },
      "swiftshader.tar.br": { "size": 2345678, "sha256": "def..." },
      "al2023.tar.br": { "size": 345678, "sha256": "ghi..." }
    }
  },
  "arm64": {
    "binaries": {
      "chromium.br": { "size": 11234567, "sha256": "jkl..." },
      "swiftshader.tar.br": { "size": 2234567, "sha256": "mno..." }
    }
  },
  "fonts": {
    "fonts.tar.br": { "size": 567890, "sha256": "stu..." }
  }
}
```

**Important notes:**

- x64 artifacts are at: `/srv/build/chromium/chromium-${CHROME_VERSION}.br`, `/srv/build/chromium/swiftshader.tar.br`, `/srv/lib/al2023.tar.br`
- But `build-x64.sh` **deletes** these files after upload (lines 46-50). So teardown cannot access x64 local files.
- arm64 artifacts are at: `/srv/build/chromium/chromium-${CHROME_VERSION}.br`, `/srv/build/chromium/swiftshader.tar.br` — these exist at teardown time since arm64 builds last.
- **Solution:** Compute checksums in each build script and pass them to teardown, OR download from S3 to compute (wasteful), OR compute checksums in the build scripts and write to temp files.

**Revised approach:** Each build script computes checksums and writes them to a temp JSON file. Teardown assembles the manifest from these temp files.

**Step 1a: Add checksum computation to build-x64.sh**

After uploads (line 43), before cleanup (line 46), add:

```bash
# Compute artifact checksums for manifest
python3 -c "
import json, hashlib, os
artifacts = {}
for name, path in [
    ('chromium.br', '/srv/build/chromium/chromium-${CHROME_VERSION}.br'),
    ('swiftshader.tar.br', '/srv/build/chromium/swiftshader.tar.br'),
    ('al2023.tar.br', '/srv/lib/al2023.tar.br'),
]:
    size = os.path.getsize(path)
    sha = hashlib.sha256(open(path, 'rb').read()).hexdigest()
    artifacts[name] = {'size': size, 'sha256': sha}
with open('/tmp/manifest-x64.json', 'w') as f:
    json.dump(artifacts, f)
"
```

Modify: `_/ec2/build-x64.sh:43-44` — insert before line 45 (cleanup).

**Step 1b: Add checksum computation to build-arm64.sh**

After uploads (line 36), add:

```bash
# Compute artifact checksums for manifest
python3 -c "
import json, hashlib, os
artifacts = {}
for name, path in [
    ('chromium.br', '/srv/build/chromium/chromium-${CHROME_VERSION}.br'),
    ('swiftshader.tar.br', '/srv/build/chromium/swiftshader.tar.br'),
]:
    size = os.path.getsize(path)
    sha = hashlib.sha256(open(path, 'rb').read()).hexdigest()
    artifacts[name] = {'size': size, 'sha256': sha}
with open('/tmp/manifest-arm64.json', 'w') as f:
    json.dump(artifacts, f)
"
```

Modify: `_/ec2/build-arm64.sh:36-37` — insert after uploads.

**Step 1c: Add checksum for fonts in build-chromium.yml**

Fonts are built and uploaded in GHA, not EC2. The EC2 instance downloads fonts from S3 during setup. Since fonts are uploaded by `build-chromium.yml` at `s3://{rev}/fonts.tar.br`, we can either:

- Compute the checksum in `build-chromium.yml` and pass it via user-data env var (complex)
- Have teardown download fonts.tar.br from S3 and compute checksum (simple, small file)
- Skip fonts in the EC2-written manifest; let a GHA step add it later

**Decision:** Have teardown download `fonts.tar.br` from S3 to compute checksum. It's a small file (~500KB).

**Step 1d: Assemble manifest in teardown.sh**

After build.json finalization, add:

```bash
# Generate manifest.json
report_progress "teardown" "Generating revision manifest"
MANIFEST="/tmp/manifest.json"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Download fonts for checksum
aws s3 cp "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/fonts.tar.br" /tmp/fonts.tar.br || true

python3 -c "
import json, hashlib, os

manifest = {
    'revision': '${CHROMIUM_REVISION}',
    'chrome_version': '${CHROME_VERSION}',
    'built_at': '$TIMESTAMP'
}

# Load per-arch binary checksums from build phases
for arch in ['x64', 'arm64']:
    path = f'/tmp/manifest-{arch}.json'
    if os.path.exists(path):
        with open(path) as f:
            manifest[arch] = {'binaries': json.load(f)}

# Fonts checksum
fonts_path = '/tmp/fonts.tar.br'
if os.path.exists(fonts_path):
    size = os.path.getsize(fonts_path)
    sha = hashlib.sha256(open(fonts_path, 'rb').read()).hexdigest()
    manifest['fonts'] = {'fonts.tar.br': {'size': size, 'sha256': sha}}

with open('$MANIFEST', 'w') as f:
    json.dump(manifest, f, indent=2)
"

aws s3 cp "$MANIFEST" "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/manifest.json"
```

Modify: `_/ec2/teardown.sh` — insert after build.json block (after line 48), before pending.json removal.

**Step 2: Commit**

```
feat: generate manifest.json with binary metadata during EC2 build
```

---

### Task 2: Add arm64-libs checksums to manifest

**Files:**

- Modify: `_/ec2/build-arm64-libs.sh:47-57`

The arm64-libs instance runs independently and uploads `al2023.tar.br` to `{rev}/arm64/al2023.tar.br`. It needs to contribute its checksum to the manifest via read-modify-write (the main build instance may or may not have written the manifest yet).

**Step 1: Add manifest update to build-arm64-libs.sh**

After uploading `al2023.tar.br` (line 48), before the completion marker (line 51), add:

```bash
# Update manifest.json with arm64 al2023 checksum
MANIFEST_S3="s3://${S3_BUCKET}/${CHROMIUM_REVISION}/manifest.json"
MANIFEST_TMP="/tmp/manifest.json"
aws s3 cp "$MANIFEST_S3" "$MANIFEST_TMP" 2>/dev/null || echo '{}' > "$MANIFEST_TMP"

AL2023_SIZE=$(stat -c%s /srv/lib/al2023.tar.br)
AL2023_SHA=$(sha256sum /srv/lib/al2023.tar.br | cut -d' ' -f1)

python3 -c "
import json
with open('$MANIFEST_TMP') as f:
    data = json.load(f)
data.setdefault('arm64', {}).setdefault('binaries', {})
data['arm64']['binaries']['al2023.tar.br'] = {
    'size': $AL2023_SIZE,
    'sha256': '$AL2023_SHA'
}
with open('$MANIFEST_TMP', 'w') as f:
    json.dump(data, f, indent=2)
" && aws s3 cp "$MANIFEST_TMP" "$MANIFEST_S3"
```

**Note:** This is a read-modify-write. If the main instance hasn't created manifest.json yet, it starts with `{}` and the main instance's teardown will merge its data. If it has, this appends cleanly. The `setdefault` pattern is safe for both cases.

**Wait — race condition:** If both the arm64-libs instance and the main instance's teardown run simultaneously, one will overwrite the other. The main instance's teardown should also do read-modify-write instead of creating fresh. Update Task 1d accordingly: teardown should load existing manifest and merge, not overwrite.

**Step 2: Update teardown.sh to merge instead of overwrite**

Modify the teardown manifest generation to:

1. Download existing manifest.json (may have arm64 al2023 data from libs instance)
2. Merge in the build data
3. Upload

```python
# In teardown.sh python3 block:
manifest_path = '$MANIFEST'
if os.path.exists(manifest_path):
    with open(manifest_path) as f:
        manifest = json.load(f)
else:
    manifest = {}

# Set/overwrite top-level fields
manifest['revision'] = '${CHROMIUM_REVISION}'
manifest['chrome_version'] = '${CHROME_VERSION}'
manifest['built_at'] = '$TIMESTAMP'

# Merge per-arch binaries (preserve existing keys like arm64.binaries.al2023.tar.br)
for arch in ['x64', 'arm64']:
    path = f'/tmp/manifest-{arch}.json'
    if os.path.exists(path):
        with open(path) as f:
            binaries = json.load(f)
        manifest.setdefault(arch, {}).setdefault('binaries', {}).update(binaries)
```

**Step 3: Commit**

```
feat: add arm64-libs checksums to revision manifest
```

---

### Task 3: Add screenshot hashes to manifest from VR job

**Files:**

- Modify: `.github/workflows/test.yml:233-237` (upload step)
- Modify: `.github/workflows/test.yml:317-346` (presign step — add manifest update)

**Step 1: Upload manifest.json to S3 alongside screenshots**

Remove `--exclude "manifest.json"` from the upload step, OR add a separate step that does the read-modify-write on the S3 manifest.

**Better approach:** Dedicated step that reads the S3 manifest, adds screenshot hashes, and writes back. This is cleaner than uploading the VR tool's manifest.json (which has a different schema).

Add new step after "Upload current screenshots to S3" (after line 237):

```yaml
- name: Update revision manifest with screenshot hashes
  run: |
    REVISION="${{ steps.revision.outputs.revision }}"
    ARCH="${{ matrix.arch }}"
    MANIFEST_S3="s3://${S3_BUCKET}/${REVISION}/manifest.json"
    MANIFEST_TMP="/tmp/manifest-update.json"

    # Download existing manifest (EC2 build may have created it)
    aws s3 cp "$MANIFEST_S3" "$MANIFEST_TMP" 2>/dev/null || echo '{}' > "$MANIFEST_TMP"

    # Read hashes from VR tool output
    VR_MANIFEST=$(cat /tmp/screenshots/current/manifest.json)

    # Merge screenshot hashes into arch section
    echo "$VR_MANIFEST" | jq --arg arch "$ARCH" \
      --slurpfile existing "$MANIFEST_TMP" '
      ($existing[0] // {}) * {
        ($arch): (($existing[0][$arch] // {}) * {
          "screenshots": (to_entries | map({(.key): .value.hash}) | add)
        })
      }
    ' > "${MANIFEST_TMP}.new" && mv "${MANIFEST_TMP}.new" "$MANIFEST_TMP"

    aws s3 cp "$MANIFEST_TMP" "$MANIFEST_S3"
```

This transforms the VR manifest `{"example.com": {"hash": "abc"}, "webgl": {"hash": "def"}}` into `{"{arch}": {"screenshots": {"example.com": "abc", "webgl": "def"}}}` and merges it into the existing manifest.

**Step 2: Commit**

```
feat: append screenshot hashes to S3 revision manifest
```

---

### Task 4: Read baseline hashes from S3 manifest in PR comment

**Files:**

- Modify: `.github/workflows/test.yml:366-370` (baseline hash reading)

**Step 1: Replace git-based hash reading with S3 manifest reading**

Change the baseline hash reading from `git show origin/master:_/amazon/events/example.com.json` to downloading `s3://{baseline_rev}/manifest.json`:

```bash
if [ "$HAS_BASELINE" = "true" ]; then
  BASELINE_MANIFEST=$(aws s3 cp "s3://${S3_BUCKET}/${BASELINE_REV}/manifest.json" - 2>/dev/null || echo '{}')
  BASELINE_EXAMPLE_HASH=$(echo "$BASELINE_MANIFEST" | jq -r ".${{ matrix.arch }}.screenshots[\"example.com\"] // \"n/a\"")
  BASELINE_WEBGL_HASH=$(echo "$BASELINE_MANIFEST" | jq -r ".${{ matrix.arch }}.screenshots.webgl // \"n/a\"")
```

**Key improvement:** This gives per-arch baseline hashes (x64 baseline vs x64 current, arm64 baseline vs arm64 current) rather than the repo's single expected hash. Screenshots can differ between architectures (font rendering, GPU behavior), so per-arch comparison is more accurate.

**Step 2: Also update the `has_baseline` check**

Currently checks for `example.com.png` in S3. Could also/instead check for `manifest.json` existence. But screenshots in S3 are still needed for the odiff visual comparison (image files, not just hashes). Keep the `s3 ls` check for screenshots, but also download the manifest for hashes.

**Step 3: Commit**

```
refactor: read baseline hashes from S3 manifest instead of repo
```

---

### Task 5: Enrich build-complete PR comment with manifest data

**Files:**

- Modify: `.github/workflows/build-complete.yml:30-53`

**Step 1: Download manifest and show artifact sizes + chrome version**

```yaml
- name: Handle success
  if: steps.payload.outputs.status == 'success'
  env:
    GH_TOKEN: ${{ secrets.RELEASE_TOKEN }}
    PR_NUMBER: ${{ steps.payload.outputs.pr_number }}
    REVISION: ${{ steps.payload.outputs.revision }}
  run: |
    # Label management (unchanged)
    gh api repos/${{ github.repository }}/issues/${PR_NUMBER}/labels/binaries:building \
      -X DELETE || true
    gh api repos/${{ github.repository }}/issues/${PR_NUMBER}/labels \
      -f "labels[]=binaries:available"

    # Download manifest for artifact details
    MANIFEST=$(aws s3 cp "s3://${S3_BUCKET}/${REVISION}/manifest.json" - 2>/dev/null || echo '{}')
    CHROME_VERSION=$(echo "$MANIFEST" | jq -r '.chrome_version // "unknown"')

    # Format sizes as human-readable
    fmt_size() { echo "$MANIFEST" | jq -r ".$1.binaries[\"$2\"].size // 0" | numfmt --to=iec-i --suffix=B; }

    cat > /tmp/comment.md <<EOF
    ## Build Complete

    Chromium revision \`${REVISION}\` (Chrome ${CHROME_VERSION}) built successfully.
    Binaries are available in S3. Tests will run automatically.

    | Architecture | Artifact | Size |
    |---|---|---|
    | x64 | chromium.br | $(fmt_size x64 chromium.br) |
    | x64 | swiftshader.tar.br | $(fmt_size x64 swiftshader.tar.br) |
    | x64 | al2023.tar.br | $(fmt_size x64 al2023.tar.br) |
    | arm64 | chromium.br | $(fmt_size arm64 chromium.br) |
    | arm64 | swiftshader.tar.br | $(fmt_size arm64 swiftshader.tar.br) |
    | arm64 | al2023.tar.br | $(fmt_size arm64 al2023.tar.br) |
    | shared | fonts.tar.br | $(fmt_size fonts fonts.tar.br) |
    EOF

    gh pr comment "${PR_NUMBER}" --repo "${{ github.repository }}" --body-file /tmp/comment.md
```

**Step 2: Commit**

```
feat: show artifact sizes and chrome version in build-complete comment
```

---

### Task 6: Verify end-to-end

Cannot run the full EC2 build in a test, but can verify:

1. The python3 manifest generation logic works by running the python snippets locally
2. The jq merge logic works by testing with sample data
3. The PR comment template renders correctly

This will be fully validated when the next chromium-update PR triggers a build.

**Step 1: Commit all changes and push to master**

```
git add -A && git commit -m "feat: add S3 revision manifest with binary and screenshot metadata"
git push origin master
```

**Step 2: Toggle `binaries:available` label on PR #5 to trigger test workflow with new VR code**

---

## Summary of changes by file

| File                                   | Change                                                                     |
| -------------------------------------- | -------------------------------------------------------------------------- |
| `_/ec2/build-x64.sh`                   | Add checksum computation after upload, before cleanup                      |
| `_/ec2/build-arm64.sh`                 | Add checksum computation after upload                                      |
| `_/ec2/build-arm64-libs.sh`            | Add manifest read-modify-write with al2023 checksum                        |
| `_/ec2/teardown.sh`                    | Assemble manifest.json from per-arch temp files + fonts, upload to S3      |
| `.github/workflows/test.yml`           | Add manifest update step (screenshots), read baseline hashes from manifest |
| `.github/workflows/build-complete.yml` | Download manifest, show chrome version + artifact sizes                    |

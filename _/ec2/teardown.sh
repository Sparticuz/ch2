#!/bin/bash
# teardown.sh — Sourced by build-chromium.sh
# Uploads shared artifacts, notifies GitHub of success, and shuts down.
#
# Expects from orchestrator/setup: CHROMIUM_REVISION, CHROME_VERSION, S3_BUCKET,
#   GITHUB_PAT, GITHUB_REPO, PR_NUMBER, LOG, notify_failure, ERR trap

echo "=== Teardown: Finalize ==="
report_progress "teardown" "Uploading logs and notifying GitHub"

# Scrub secrets from build log before upload
sed -i "s/${GITHUB_PAT}/[REDACTED]/g" "$LOG" 2>/dev/null || true

# Upload build log
aws s3 cp "$LOG" "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/build.log" || true

# Finalize build.json with success status
S3_BUILD="s3://${S3_BUCKET}/${CHROMIUM_REVISION}/build.json"
TMP_BUILD="/tmp/build.json"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
NOW_EPOCH=$(date +%s)
ELAPSED=$(( NOW_EPOCH - BUILD_START_EPOCH ))
HOURS=$(( ELAPSED / 3600 ))
MINS=$(( (ELAPSED % 3600) / 60 ))

aws s3 cp "$S3_BUILD" "$TMP_BUILD" 2>/dev/null || echo '{}' > "$TMP_BUILD"

python3 -c "
import json
with open('$TMP_BUILD') as f:
    data = json.load(f)
data.setdefault('revision', '${CHROMIUM_REVISION}')
data.setdefault('pr_number', ${PR_NUMBER})
data.setdefault('started_at', '$TIMESTAMP')
data['status'] = 'success'
data['chrome_version'] = '${CHROME_VERSION}'
data.setdefault('events', [])
data['events'].append({
    'phase': 'completed',
    'detail': 'Build successful',
    'timestamp': '$TIMESTAMP',
    'elapsed': '${HOURS}h${MINS}m',
    'status': 'success',
    'chrome_version': '${CHROME_VERSION}'
})
with open('$TMP_BUILD', 'w') as f:
    json.dump(data, f, indent=2)
" && aws s3 cp "$TMP_BUILD" "$S3_BUILD"

# Assemble manifest.json with artifact checksums
S3_MANIFEST="s3://${S3_BUCKET}/${CHROMIUM_REVISION}/manifest.json"
MANIFEST_TMP="/tmp/manifest.json"

# Download fonts to compute checksum
aws s3 cp "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/fonts.tar.br" /tmp/fonts.tar.br || true

# Download existing manifest (arm64-libs instance may have contributed)
aws s3 cp "$S3_MANIFEST" "$MANIFEST_TMP" 2>/dev/null || echo '{}' > "$MANIFEST_TMP"

python3 -c "
import json, hashlib, os

manifest_path = '$MANIFEST_TMP'
if os.path.exists(manifest_path):
    with open(manifest_path) as f:
        manifest = json.load(f)
else:
    manifest = {}

manifest['revision'] = '${CHROMIUM_REVISION}'
manifest['chrome_version'] = '${CHROME_VERSION}'
manifest['built_at'] = '$TIMESTAMP'

for arch in ['x64', 'arm64']:
    path = f'/tmp/manifest-{arch}.json'
    if os.path.exists(path):
        with open(path) as f:
            binaries = json.load(f)
        manifest.setdefault(arch, {}).setdefault('binaries', {}).update(binaries)

fonts_path = '/tmp/fonts.tar.br'
if os.path.exists(fonts_path):
    size = os.path.getsize(fonts_path)
    sha = hashlib.sha256(open(fonts_path, 'rb').read()).hexdigest()
    manifest['fonts'] = {'fonts.tar.br': {'size': size, 'sha256': sha}}

with open(manifest_path, 'w') as f:
    json.dump(manifest, f, indent=2)
" && aws s3 cp "$MANIFEST_TMP" "$S3_MANIFEST"

# Remove pending marker
aws s3 rm "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/pending.json" || true

# Notify GitHub via repository_dispatch
echo "Notifying GitHub..."
curl -sf -X POST \
  -H "Authorization: token ${GITHUB_PAT}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GITHUB_REPO}/dispatches" \
  -d "{
    \"event_type\": \"build-complete\",
    \"client_payload\": {
      \"revision\": \"${CHROMIUM_REVISION}\",
      \"pr_number\": \"${PR_NUMBER}\",
      \"status\": \"success\"
    }
  }"

echo "=== Build Complete at $(date -u) ==="

# Cancel the 8-hour safety timer; shut down now
shutdown -c || true
shutdown -h now

#!/bin/bash
# upload-artifacts.sh
# Uploads compiled Chromium artifacts to S3 and notifies GitHub.
# Called from the Ansible playbook on the EC2 build instance.
#
# Usage: ./upload-artifacts.sh <S3_BUCKET> <REVISION> <GITHUB_PAT> <GITHUB_REPO> <PR_NUMBER>

set -euo pipefail

S3_BUCKET="${1:?S3_BUCKET is required}"
REVISION="${2:?REVISION is required}"
GITHUB_PAT="${3:?GITHUB_PAT is required}"
GITHUB_REPO="${4:?GITHUB_REPO is required}"
PR_NUMBER="${5:?PR_NUMBER is required}"

S3_PREFIX="s3://${S3_BUCKET}/${REVISION}"

echo "Uploading artifacts to ${S3_PREFIX}/"

# Upload x64 artifacts
if [ -d /srv/build/chromium ] && ls /srv/build/chromium/*.br 1>/dev/null 2>&1; then
    for f in /srv/build/chromium/*.br; do
        aws s3 cp "$f" "${S3_PREFIX}/x64/$(basename "$f")"
    done
fi

# Upload x64 libs
if [ -f /srv/lib/al2023.tar.br ]; then
    aws s3 cp /srv/lib/al2023.tar.br "${S3_PREFIX}/x64/al2023.tar.br"
fi

# Upload swiftshader for x64
if [ -f /srv/build/chromium/swiftshader.tar.br ]; then
    aws s3 cp /srv/build/chromium/swiftshader.tar.br "${S3_PREFIX}/x64/swiftshader.tar.br"
fi

# Upload fonts (shared between architectures)
if [ -f /srv/build/chromium/fonts.tar.br ]; then
    aws s3 cp /srv/build/chromium/fonts.tar.br "${S3_PREFIX}/fonts.tar.br"
fi

# TODO: arm64 artifacts if cross-compiled on the same instance

# Create completion marker
COMPLETED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat <<EOF | aws s3 cp - "${S3_PREFIX}/completed.json"
{
  "revision": "${REVISION}",
  "completed_at": "${COMPLETED_AT}",
  "status": "success",
  "pr_number": ${PR_NUMBER}
}
EOF

echo "Upload complete. Marker written to ${S3_PREFIX}/completed.json"

# Remove pending marker
aws s3 rm "${S3_PREFIX}/pending.json" || true

# Notify GitHub via repository_dispatch
echo "Sending repository_dispatch to ${GITHUB_REPO}..."
curl -sf -X POST \
  -H "Authorization: token ${GITHUB_PAT}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GITHUB_REPO}/dispatches" \
  -d "{
    \"event_type\": \"build-complete\",
    \"client_payload\": {
      \"revision\": \"${REVISION}\",
      \"pr_number\": \"${PR_NUMBER}\",
      \"status\": \"success\"
    }
  }"

echo "GitHub notified. Done."

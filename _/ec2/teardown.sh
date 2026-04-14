#!/bin/bash
# teardown.sh — Sourced by build-chromium.sh
# Uploads shared artifacts, notifies GitHub of success, and shuts down.
#
# Expects from orchestrator/setup: CHROMIUM_REVISION, CHROME_VERSION, S3_BUCKET,
#   GITHUB_PAT, GITHUB_REPO, PR_NUMBER, LOG, notify_failure, ERR trap

echo "=== Teardown: Finalize ==="
report_progress "teardown" "Uploading logs and notifying GitHub"

# Upload fonts (if present — may be pre-built and committed to repo)
if [ -f /srv/build/chromium/fonts.tar.br ]; then
  aws s3 cp /srv/build/chromium/fonts.tar.br \
    "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/fonts.tar.br"
fi

# Scrub secrets from build log before upload
sed -i "s/${GITHUB_PAT}/[REDACTED]/g" "$LOG" 2>/dev/null || true

# Upload build log
aws s3 cp "$LOG" "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/build.log" || true

# Create completion marker
cat <<EOF | aws s3 cp - "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/completed.json"
{
  "revision": "${CHROMIUM_REVISION}",
  "chrome_version": "${CHROME_VERSION}",
  "completed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "status": "success",
  "pr_number": ${PR_NUMBER}
}
EOF

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

#!/bin/bash
# build-chromium.sh — Orchestrator that runs on EC2 via user-data.
# Sets up logging, error handling, and self-destruct, then sources
# sub-scripts for each phase of the Chromium build.
#
# Required environment variables (set by user-data wrapper):
#   CHROMIUM_REVISION  — Chromium revision number (e.g., 1596535)
#   S3_BUCKET          — S3 bucket for artifact upload
#   GITHUB_PAT         — GitHub PAT for repository_dispatch
#   GITHUB_REPO        — GitHub repo (e.g., owner/repo)
#   PR_NUMBER          — PR number to notify
#   AWS_DEFAULT_REGION — AWS region (e.g., us-east-1)

set -euo pipefail

# Resolve the directory containing this script and its companions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === Self-destruct timer ===
# Schedule shutdown in 8 hours as the VERY FIRST action.
# instance_initiated_shutdown_behavior=terminate ensures the instance is terminated.
shutdown -h +480 "Build safety timeout reached (8 hours)"

LOG="/var/log/chromium-build.log"
BUILD_START_EPOCH=$(date +%s)
exec > >(tee -a "$LOG") 2>&1
echo "=== Chromium Build Started at $(date -u) ==="
echo "Revision: ${CHROMIUM_REVISION-}"
echo "S3 Bucket: ${S3_BUCKET-}"
echo "PR: ${PR_NUMBER-}"

# Validate required environment variables
for VAR in CHROMIUM_REVISION S3_BUCKET GITHUB_PAT GITHUB_REPO PR_NUMBER AWS_DEFAULT_REGION; do
  if [[ -z "${!VAR-}" ]]; then
    echo "FATAL: Required environment variable ${VAR} is empty or unset"
    exit 1
  fi
done
[[ "${PR_NUMBER}" =~ ^[0-9]+$ ]] || { echo "FATAL: PR_NUMBER must be a number, got: ${PR_NUMBER}"; exit 1; }

# Helper: upload progress marker to S3
report_progress() {
  local PHASE="$1"
  local DETAIL="${2:-}"
  local NOW_EPOCH
  NOW_EPOCH=$(date +%s)
  local ELAPSED=$(( NOW_EPOCH - BUILD_START_EPOCH ))
  local HOURS=$(( ELAPSED / 3600 ))
  local MINS=$(( (ELAPSED % 3600) / 60 ))

  echo ">>> Progress: ${PHASE} (${HOURS}h${MINS}m elapsed)"

  cat <<EOF | aws s3 cp - "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/progress.json" 2>/dev/null || true
{
  "revision": "${CHROMIUM_REVISION}",
  "phase": "${PHASE}",
  "detail": "${DETAIL}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "elapsed_seconds": ${ELAPSED},
  "elapsed_human": "${HOURS}h${MINS}m",
  "pr_number": ${PR_NUMBER}
}
EOF
}

# Helper: notify GitHub of failure and exit
notify_failure() {
  local MESSAGE="${1:-Build failed}"
  # Escape for JSON: backslashes, double quotes, tabs
  MESSAGE=$(printf '%s' "$MESSAGE" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' ' ')
  echo "FAILURE: ${MESSAGE}"

  # Upload failure marker to S3
  cat <<EOF | aws s3 cp - "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/completed.json"
{
  "revision": "${CHROMIUM_REVISION}",
  "completed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "status": "failed",
  "error": "${MESSAGE}",
  "pr_number": ${PR_NUMBER}
}
EOF

  # Remove pending marker
  aws s3 rm "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/pending.json" || true

  # Scrub secrets from build log before upload
  sed -i "s/${GITHUB_PAT}/[REDACTED]/g" "$LOG" 2>/dev/null || true

  # Upload build log
  aws s3 cp "$LOG" "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/build.log" || true

  # Notify GitHub
  curl -sf -X POST \
    -H "Authorization: token ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GITHUB_REPO}/dispatches" \
    -d "{
      \"event_type\": \"build-complete\",
      \"client_payload\": {
        \"revision\": \"${CHROMIUM_REVISION}\",
        \"pr_number\": \"${PR_NUMBER}\",
        \"status\": \"failed\",
        \"error\": \"${MESSAGE}\"
      }
    }" || true

  # Cancel the 8-hour shutdown timer; shut down now
  shutdown -c || true
  shutdown -h now
  exit 1
}

# Trap any unexpected failure
trap 'notify_failure "Unexpected error on line $LINENO"' ERR

# === Run build phases ===
source "$SCRIPT_DIR/setup.sh"
source "$SCRIPT_DIR/build-x64.sh"
source "$SCRIPT_DIR/build-arm64.sh"
source "$SCRIPT_DIR/teardown.sh"

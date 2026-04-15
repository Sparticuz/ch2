# Build Pipeline Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix three gaps in the build-to-test pipeline: (1) test workflows not auto-triggering after build, (2) missing arm64 AL2023 system libs, (3) missing fonts.tar.br in S3.

**Architecture:** Fix 1 swaps GITHUB_TOKEN for the existing PAT in build-complete.yml so label events trigger downstream workflows. Fix 2 adds a parallel arm64 EC2 instance (m8g.medium, ~5 min) launched alongside the x86_64 build to package arm64 system libs. Fix 3 builds fonts.tar.br on the GHA runner and uploads to S3 before EC2 even boots.

**Tech Stack:** GitHub Actions workflows, AWS CLI (EC2, S3, SSM), bash shell scripts.

---

### Task 1: Fix build-complete.yml to use PAT for label operations

**Files:**

- Modify: `.github/workflows/build-complete.yml`

When `build-complete.yml` adds/removes labels using `${{ github.token }}` (GITHUB_TOKEN), the resulting `labeled` event is suppressed by GitHub and does NOT trigger `test-x64.yml` / `test-arm.yml`. Switching to `secrets.RELEASE_TOKEN` (the PAT) fixes this.

**Step 1: Change the token in the success handler**

In `.github/workflows/build-complete.yml`, change the `Handle success` step's env:

```yaml
- name: Handle success
  if: steps.payload.outputs.status == 'success'
  env:
    GH_TOKEN: ${{ secrets.RELEASE_TOKEN }}
    PR_NUMBER: ${{ steps.payload.outputs.pr_number }}
    REVISION: ${{ steps.payload.outputs.revision }}
```

**Step 2: Change the token in the failure handler**

Same file, change the `Handle failure` step's env:

```yaml
- name: Handle failure
  if: steps.payload.outputs.status != 'success'
  env:
    GH_TOKEN: ${{ secrets.RELEASE_TOKEN }}
    PR_NUMBER: ${{ steps.payload.outputs.pr_number }}
    REVISION: ${{ steps.payload.outputs.revision }}
```

**Step 3: Update the success comment to include arm64 al2023.tar.br**

In the success handler's PR comment, update the artifacts table to include arm64 al2023.tar.br and fonts:

```
          | Architecture | Artifacts |
          |---|---|
          | x64 | chromium.br, swiftshader.tar.br, al2023.tar.br |
          | arm64 | chromium.br, swiftshader.tar.br, al2023.tar.br |
          | shared | fonts.tar.br |"
```

**Step 4: Commit**

```bash
git add .github/workflows/build-complete.yml
git commit -m "fix: use PAT in build-complete.yml so label events trigger test workflows"
```

---

### Task 2: Create build-arm64-libs.sh for packaging arm64 system libraries

**Files:**

- Create: `_/ec2/build-arm64-libs.sh`

This is a standalone script (NOT sourced by build-chromium.sh) that runs on a small arm64 AL2023 instance. It installs NSS/NSPR/expat packages, packages the same 12 library files as the x64 build, uploads to S3, and shuts down.

**Step 1: Create `_/ec2/build-arm64-libs.sh`**

```bash
#!/bin/bash
# build-arm64-libs.sh — Standalone script for arm64 AL2023 system library packaging.
# Runs on a small arm64 AL2023 EC2 instance launched by build-chromium.yml.
# Packages the same NSS/NSPR/expat libs as build-x64.sh for arm64 Lambda.
#
# Required environment variables (set by user-data wrapper):
#   CHROMIUM_REVISION   — Chromium revision number
#   S3_BUCKET           — S3 bucket for artifact upload
#   AWS_DEFAULT_REGION  — AWS region

set -euo pipefail
export HOME="${HOME:-/root}"

LOG="/var/log/arm64-libs.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== arm64 AL2023 Libs Build Started at $(date -u) ==="
echo "Revision: ${CHROMIUM_REVISION}"

# Self-destruct in 1 hour (this should take < 5 minutes)
shutdown -h +60 "arm64 libs safety timeout (1 hour)"

# Install required packages
dnf install -y nss nspr expat brotli

# Create working directory
mkdir -p /srv/lib

# Package AL2023 arm64 system libraries (same set as x64 in build-x64.sh)
echo "Packaging arm64 AL2023 system libraries..."

# Find the actual expat version (may vary across AL2023 updates)
EXPAT_SO=$(ls /usr/lib64/libexpat.so.1.* 2>/dev/null | head -1)
EXPAT_BASENAME=$(basename "$EXPAT_SO")

tar --directory /usr/lib64 --create --file /srv/lib/al2023.tar \
  --transform="s,^${EXPAT_BASENAME}$,libexpat.so.1," \
  --transform='s,^,lib/,' \
  "$EXPAT_BASENAME" libfreebl3.so libfreeblpriv3.so libnspr4.so libnss3.so \
  libnssutil3.so libplc4.so libplds4.so libsoftokn3.so libfreebl3.chk \
  libfreeblpriv3.chk libsoftokn3.chk

brotli --best --force /srv/lib/al2023.tar

# Upload to S3
echo "Uploading arm64 al2023.tar.br to S3..."
aws s3 cp /srv/lib/al2023.tar.br \
  "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/arm64/al2023.tar.br"

# Upload a small completion marker for debugging
cat <<EOF | aws s3 cp - "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/arm64-libs-complete.json"
{
  "revision": "${CHROMIUM_REVISION}",
  "completed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "status": "success"
}
EOF

echo "=== arm64 libs complete at $(date -u) ==="

# Upload log and shut down
aws s3 cp "$LOG" "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/arm64-libs.log" || true
shutdown -c || true
shutdown -h now
```

**Step 2: Commit**

```bash
git add _/ec2/build-arm64-libs.sh
git commit -m "feat: add build-arm64-libs.sh for arm64 AL2023 system library packaging"
```

---

### Task 3: Add arm64 libs EC2 launch and fonts upload to build-chromium.yml

**Files:**

- Modify: `.github/workflows/build-chromium.yml`

Add three things:

1. A step to build and upload fonts.tar.br from the GHA runner
2. An arm64 AMI lookup step
3. A second EC2 launch for the arm64 libs instance (fire-and-forget, parallel with x86_64)

**Step 1: Add Node.js setup and fonts build steps**

After the "Get chromium revision" step (line 37) and before "Detect build options", add:

```yaml
- name: Setup Node.js
  uses: actions/setup-node@v6
  with:
    node-version: 24.x

- name: Build and upload fonts
  env:
    REVISION: ${{ steps.revision.outputs.revision }}
  run: |
    mkdir -p bin
    npm run build:fonts
    aws s3 cp bin/fonts.tar.br "s3://${S3_BUCKET}/${REVISION}/fonts.tar.br"
    echo "Uploaded fonts.tar.br to S3"
```

**Step 2: Add arm64 AMI lookup step**

After the existing "Get AMI ID" step (which gets x86_64 AMI), add:

```yaml
- name: Get arm64 AMI ID
  id: ami_arm64
  run: |
    AMI_ID=$(aws ssm get-parameters \
      --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64 \
      --query 'Parameters[0].Value' --output text)
    echo "ami_id=${AMI_ID}" >> "$GITHUB_OUTPUT"
    echo "arm64 AMI: ${AMI_ID}"
```

**Step 3: Prepare arm64 libs user-data**

After the existing "Prepare user-data" step, add a new step for the arm64 libs user-data:

```yaml
- name: Prepare arm64 libs user-data
  id: userdata_arm64
  env:
    REVISION: ${{ steps.revision.outputs.revision }}
  run: |
    # The arm64 libs script is self-contained — just upload and run it
    {
      echo '#!/bin/bash'
      echo 'set -euo pipefail'
      echo "CHROMIUM_REVISION=\"${REVISION}\""
      echo "S3_BUCKET=\"${S3_BUCKET}\""
      echo "AWS_DEFAULT_REGION=\"${AWS_DEFAULT_REGION}\""
      echo 'export CHROMIUM_REVISION S3_BUCKET AWS_DEFAULT_REGION'
      echo ''
      # Embed the script directly
      cat _/ec2/build-arm64-libs.sh | grep -v '^#!/bin/bash' | grep -v '^set -euo pipefail'
    } > /tmp/userdata-arm64.sh

    SIZE=$(wc -c < /tmp/userdata-arm64.sh)
    echo "arm64 libs user-data size: ${SIZE} bytes"
    echo "userdata_file=/tmp/userdata-arm64.sh" >> "$GITHUB_OUTPUT"
```

**Step 4: Find arm64-compatible subnets**

After the existing "Find default VPC and subnets" step, add:

```yaml
- name: Find arm64 subnets
  id: vpc_arm64
  run: |
    VPC_ID="${{ steps.vpc.outputs.vpc_id }}"

    # m8g.medium is widely available but still check
    SUPPORTED_AZS=$(aws ec2 describe-instance-type-offerings \
      --location-type availability-zone \
      --filters "Name=instance-type,Values=m8g.medium" \
      --query 'InstanceTypeOfferings[].Location' --output json)

    SUBNET_IDS=$(aws ec2 describe-subnets \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
      --query 'Subnets[].{Id:SubnetId,AZ:AvailabilityZone}' --output json \
      | jq -r --argjson azs "$SUPPORTED_AZS" \
        '[.[] | select(.AZ as $az | $azs | index($az))] | .[].Id')

    if [ -z "$SUBNET_IDS" ]; then
      echo "::warning::No subnet found for arm64 libs instance — arm64 al2023.tar.br will be missing"
      echo "has_subnets=false" >> "$GITHUB_OUTPUT"
    else
      echo "has_subnets=true" >> "$GITHUB_OUTPUT"
      echo "subnet_ids<<EOF" >> "$GITHUB_OUTPUT"
      echo "$SUBNET_IDS" >> "$GITHUB_OUTPUT"
      echo "EOF" >> "$GITHUB_OUTPUT"
    fi
```

**Step 5: Launch arm64 libs instance**

After the existing "Launch EC2 instance" step, add:

```yaml
- name: Launch arm64 libs instance
  if: steps.vpc_arm64.outputs.has_subnets == 'true'
  id: ec2_arm64
  env:
    REVISION: ${{ steps.revision.outputs.revision }}
    USE_SPOT: ${{ steps.options.outputs.use_spot }}
    SUBNET_IDS: ${{ steps.vpc_arm64.outputs.subnet_ids }}
  run: |
    MARKET_OPTS=()
    if [ "${USE_SPOT}" = "true" ]; then
      MARKET_OPTS=(--instance-market-options 'MarketType=spot,SpotOptions={SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}')
    fi

    INSTANCE_ID=""
    while IFS= read -r SUBNET_ID; do
      [ -z "$SUBNET_ID" ] && continue
      echo "Trying arm64 subnet ${SUBNET_ID}..."
      if INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "${{ steps.ami_arm64.outputs.ami_id }}" \
        --instance-type m8g.medium \
        --security-group-ids "${{ steps.sg.outputs.sg_id }}" \
        --subnet-id "${SUBNET_ID}" \
        --associate-public-ip-address \
        --instance-initiated-shutdown-behavior terminate \
        --user-data "file://${{ steps.userdata_arm64.outputs.userdata_file }}" \
        --iam-instance-profile Name=chromium-build \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=chromium-arm64-libs},{Key=Revision,Value=${REVISION}},{Key=PR,Value=${{ github.event.pull_request.number }}}]" \
        ${MARKET_OPTS[@]+"${MARKET_OPTS[@]}"} \
        --query 'Instances[0].InstanceId' --output text 2>/tmp/ec2-arm64-error.txt); then
        echo "Launched arm64 libs instance: ${INSTANCE_ID}"
        break
      else
        echo "Failed: $(cat /tmp/ec2-arm64-error.txt)"
        INSTANCE_ID=""
      fi
    done <<< "$SUBNET_IDS"

    if [ -z "$INSTANCE_ID" ]; then
      echo "::warning::Failed to launch arm64 libs instance — arm64 al2023.tar.br will be missing"
    else
      echo "instance_id=${INSTANCE_ID}" >> "$GITHUB_OUTPUT"
    fi
```

**Step 6: Update the PR comment to mention both instances**

Update the "Comment on PR" step to include the arm64 libs instance:

```yaml
- name: Comment on PR
  env:
    GH_TOKEN: ${{ github.token }}
    USE_SPOT: ${{ steps.options.outputs.use_spot }}
    USE_SSH: ${{ steps.options.outputs.use_ssh }}
  run: |
    MARKET_TYPE="on-demand"
    if [ "${USE_SPOT}" = "true" ]; then MARKET_TYPE="spot"; fi
    SSH_STATUS="disabled"
    if [ "${USE_SSH}" = "true" ]; then SSH_STATUS="enabled"; fi

    ARM64_INSTANCE="${{ steps.ec2_arm64.outputs.instance_id }}"
    ARM64_ROW=""
    if [ -n "$ARM64_INSTANCE" ]; then
      ARM64_ROW="| **arm64 libs instance** | \`${ARM64_INSTANCE}\` (m8g.medium, ~5 min) |
    "
    fi

    gh pr comment ${{ github.event.pull_request.number }} --body "## Chromium Build Launched

    | | Value |
    |---|---|
    | **Revision** | \`${{ steps.revision.outputs.revision }}\` |
    | **Build instance** | \`${{ steps.ec2.outputs.instance_id }}\` (${INSTANCE_TYPE}) |
    ${ARM64_ROW}| **Market** | ${MARKET_TYPE} |
    | **SSH** | ${SSH_STATUS} |
    | **Deadline** | 8 hours from now |

    The EC2 instances are running autonomously. No GitHub runner connection is needed.
    Artifacts will be uploaded to S3, then this PR will be notified and instances will self-terminate."
```

**Step 7: Update emergency teardown to include arm64 instance**

In the "Emergency teardown (on failure)" step, add the arm64 instance to termination:

```yaml
- name: Emergency teardown (on failure)
  if: failure()
  env:
    REVISION: ${{ steps.revision.outputs.revision }}
  run: |
    # Terminate x86_64 build instance
    INSTANCE_ID="${{ steps.ec2.outputs.instance_id }}"
    if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "" ]; then
      aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" || true
    fi
    # Terminate arm64 libs instance
    ARM64_ID="${{ steps.ec2_arm64.outputs.instance_id }}"
    if [ -n "$ARM64_ID" ] && [ "$ARM64_ID" != "" ]; then
      aws ec2 terminate-instances --instance-ids "$ARM64_ID" || true
    fi
    # Also terminate by tag as fallback
    STALE_IDS=$(aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=chromium-build,chromium-arm64-libs" "Name=instance-state-name,Values=running,pending" \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)
    if [ -n "$STALE_IDS" ]; then
      aws ec2 terminate-instances --instance-ids $STALE_IDS || true
    fi
    # Clean up orphaned pending.json
    aws s3 rm "s3://${S3_BUCKET}/${REVISION}/pending.json" || true
```

**Step 8: Remove dead fonts upload from teardown.sh**

In `_/ec2/teardown.sh`, remove lines 11-15 (the conditional fonts upload) since fonts are now uploaded by the GHA runner:

```bash
# Remove this block:
# Upload fonts (if present — may be pre-built and committed to repo)
if [ -f /srv/build/chromium/fonts.tar.br ]; then
  aws s3 cp /srv/build/chromium/fonts.tar.br \
    "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/fonts.tar.br"
fi
```

**Step 9: Commit**

```bash
git add .github/workflows/build-chromium.yml _/ec2/teardown.sh
git commit -m "feat: add arm64 libs EC2 instance and fonts upload to build pipeline"
```

---

### Task 4: Update documentation

**Files:**

- Modify: `CONTRIBUTING.md`
- Modify: `_/ec2/README.md`

**Step 1: Update CONTRIBUTING.md build system section**

In the "How It Works" section, update step 2 to mention both instances:

> 2. The workflow packages the `_/ec2/` directory into user-data, launches a
>    `c8id.4xlarge` instance for the full build **and** a `m8g.medium` arm64
>    instance for system library packaging, builds and uploads `fonts.tar.br`,
>    comments on the PR, and exits (~2 minutes).

Update the artifacts table in "How It Works" or add a note about the arm64 libs instance.

**Step 2: Update the build-complete comment in CONTRIBUTING.md**

In the "Label Lifecycle" section, add a note that `binaries:available` is now added via PAT so it triggers test workflows automatically.

**Step 3: Update `_/ec2/README.md`**

Add `build-arm64-libs.sh` to the script descriptions and mention the m8g.medium instance.

**Step 4: Commit**

```bash
git add CONTRIBUTING.md _/ec2/README.md
git commit -m "docs: update build pipeline documentation for arm64 libs and fonts"
```

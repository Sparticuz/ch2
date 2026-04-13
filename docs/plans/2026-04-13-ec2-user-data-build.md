# EC2 User-Data Build Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the Ansible-over-SSH build system with a fire-and-forget EC2 user-data architecture so the GitHub Actions runner can exit immediately after launching the instance.

**Architecture:** The `build-chromium.yml` workflow uses AWS CLI to launch an EC2 instance with a self-contained user-data build script. The instance installs dependencies, compiles Chromium for x64 and arm64, uploads artifacts to S3, sends a `repository_dispatch` to GitHub, and self-terminates. No SSH connection is needed. Ansible is removed entirely.

**Tech Stack:** AWS CLI, EC2 user-data (bash), S3, GitHub API, existing GN/autoninja Chromium build tooling.

---

## Summary of Changes

| File                                          | Action  | Purpose                                                                               |
| --------------------------------------------- | ------- | ------------------------------------------------------------------------------------- |
| `_/ec2/build-chromium.sh`                     | Create  | Self-contained build script that runs on EC2 via user-data                            |
| `_/ec2/upload-artifacts.sh`                   | Create  | Uploads artifacts to S3, notifies GitHub (rewritten from old version)                 |
| `_/ec2/.gclient`                              | Move    | Moved from `_/ansible/plays/.gclient`                                                 |
| `.github/workflows/build-chromium.yml`        | Rewrite | Replace Ansible with AWS CLI, encode user-data, fire-and-forget                       |
| `.github/workflows/build-safety-net.yml`      | Modify  | Update tag filter from `Chromium` to `chromium-build` to match new tag                |
| `_/ansible/`                                  | Delete  | Entire directory removed (ansible.cfg, inventory.ini, Makefile, README.md, plays/)    |
| `Makefile`                                    | Modify  | Remove any Ansible references if present                                              |
| `.github/workflows/check-chromium-update.yml` | Modify  | Read revision from new location (or keep `_/ansible/inventory.ini` path — see Task 1) |

## Key Design Decisions

1. **Revision source of truth:** Currently stored in `_/ansible/inventory.ini`. Since we're removing Ansible, we'll move the revision to a simple file: `_/ec2/revision.txt` (just the number). All workflows that read `chromium_revision` will be updated.

2. **EC2 instance config:** Keep `c8id.8xlarge` for x64 builds (NVMe storage, 32 vCPU). Cross-compile arm64 on the same instance (same as current approach, not native like remotion-dev).

3. **No Docker:** The current Ansible playbook builds directly on the host. We'll keep this approach — simpler than Docker-in-EC2, and the instance is disposable anyway.

4. **No SSH / no security group with port 22:** The instance doesn't need inbound access. We only need egress for `gclient sync`, S3, and GitHub API. We'll use a security group with egress-only rules.

5. **Self-destruct:** `shutdown -h +480` (8 hours) scheduled at boot as the first action, before anything else. Combined with `instance_initiated_shutdown_behavior: terminate`.

6. **Secrets:** AWS credentials via IAM instance profile (S3 access). GitHub PAT passed via user-data environment variable (the user-data is base64-encoded and only accessible from the instance metadata service).

---

## Task 1: Create revision.txt and update all consumers

**Files:**

- Create: `_/ec2/revision.txt`
- Modify: `.github/workflows/build-chromium.yml:33-36`
- Modify: `.github/workflows/check-chromium-update.yml:29-30`
- Modify: `.github/workflows/test-x64.yml:27-29`
- Modify: `.github/workflows/test-arm.yml` (same pattern as test-x64)
- Modify: `tools/update-browser-revision.mjs`

**Step 1: Create `_/ec2/revision.txt`**

```
1596535
```

Just the revision number, no other content. This replaces the `chromium_revision=1596535` line in `_/ansible/inventory.ini`.

**Step 2: Create `_/ec2/.gclient`**

Copy from `_/ansible/plays/.gclient` — identical content:

```python
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {
        "checkout_pgo_profiles": True,
    },
  },
]
```

**Step 3: Update `tools/update-browser-revision.mjs`**

This script currently updates `_/ansible/inventory.ini`. Change it to write to `_/ec2/revision.txt` instead.

Find the line that writes `chromium_revision=...` to `inventory.ini` and replace it with writing just the number to `_/ec2/revision.txt`.

**Step 4: Update workflow revision-reading steps**

In every workflow that reads the revision, change:

```bash
# Old:
REVISION=$(grep -oP 'chromium_revision=\K[0-9]+' _/ansible/inventory.ini)

# New:
REVISION=$(cat _/ec2/revision.txt)
```

Affected workflows:

- `.github/workflows/build-chromium.yml` (step "Get chromium revision")
- `.github/workflows/test-x64.yml` (step "Get chromium revision")
- `.github/workflows/test-arm.yml` (step "Get chromium revision")

**Step 5: Update `check-chromium-update.yml`**

Change the "Get current revision" step:

```bash
# Old:
CURRENT_REVISION=$(grep -oP 'chromium_revision=\K[0-9]+' _/ansible/inventory.ini)

# New:
CURRENT_REVISION=$(cat _/ec2/revision.txt)
```

**Step 6: Update `check-pr-binaries.yml`**

Change the file path it checks for changes:

```bash
# Old:
CHANGED=$(gh api repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/files \
  --jq '.[].filename' | grep -c '^_/ansible/inventory.ini$' || true)

# New:
CHANGED=$(gh api repos/${{ github.repository }}/pulls/${{ github.event.pull_request.number }}/files \
  --jq '.[].filename' | grep -c '^_/ec2/revision.txt$' || true)
```

**Step 7: Commit**

```bash
git add _/ec2/revision.txt _/ec2/.gclient tools/update-browser-revision.mjs \
  .github/workflows/build-chromium.yml .github/workflows/test-x64.yml \
  .github/workflows/test-arm.yml .github/workflows/check-chromium-update.yml \
  .github/workflows/check-pr-binaries.yml
git commit -m "refactor: move chromium revision to _/ec2/revision.txt"
```

---

## Task 2: Create the EC2 build script

**Files:**

- Create: `_/ec2/build-chromium.sh`

This is the core build script that runs on the EC2 instance. It's derived from the current Ansible playbook tasks (`chromium.yml`, `build-x64.yml`, `build-arm64.yml`) and informed by remotion-dev/chrome-compile patterns.

**Step 1: Write `_/ec2/build-chromium.sh`**

The script performs these phases:

1. Self-destruct timer
2. Mount NVMe storage
3. Install system dependencies
4. Clone depot_tools, sync Chromium source
5. Apply patches
6. Build x64
7. Build arm64 (cross-compile)
8. Package artifacts (strip, brotli, tar)
9. Upload to S3
10. Notify GitHub
11. Shutdown

```bash
#!/bin/bash
# build-chromium.sh — Runs on EC2 via user-data to build Chromium headless_shell.
# The instance self-terminates on completion (success or failure).
#
# Required environment variables (set by user-data wrapper):
#   CHROMIUM_REVISION  — Chromium revision number (e.g., 1596535)
#   S3_BUCKET          — S3 bucket for artifact upload
#   GITHUB_PAT         — GitHub PAT for repository_dispatch
#   GITHUB_REPO        — GitHub repo (e.g., owner/repo)
#   PR_NUMBER          — PR number to notify
#   AWS_DEFAULT_REGION — AWS region (e.g., us-east-1)

set -euo pipefail

# === Phase 0: Self-destruct timer ===
# Schedule shutdown in 8 hours as the VERY FIRST action.
# instance_initiated_shutdown_behavior=terminate ensures the instance is terminated.
shutdown -h +480 "Build safety timeout reached (8 hours)"

LOG="/var/log/chromium-build.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== Chromium Build Started at $(date -u) ==="
echo "Revision: ${CHROMIUM_REVISION}"
echo "S3 Bucket: ${S3_BUCKET}"
echo "PR: ${PR_NUMBER}"

# Helper: notify GitHub of failure and exit
notify_failure() {
  local MESSAGE="${1:-Build failed}"
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

# === Phase 1: Mount NVMe storage ===
echo "=== Phase 1: Mount NVMe ==="
# c8id.8xlarge has an NVMe instance store at /dev/nvme1n1
if [ -b /dev/nvme1n1 ]; then
  mkfs -t ext4 -m 0 /dev/nvme1n1
  echo "/dev/nvme1n1 /srv ext4 defaults,noatime,nofail 0 2" >> /etc/fstab
  mount -a
  echo "NVMe mounted at /srv"
else
  echo "No NVMe device found, using root volume"
  mkdir -p /srv
fi

# === Phase 2: Install system dependencies ===
echo "=== Phase 2: Install dependencies ==="
dnf update -y
dnf install -y \
  "@Development Tools" \
  alsa-lib-devel atk-devel bc bluez-libs-devel brotli bzip2-devel \
  cairo-devel cmake cups-devel dbus-devel dbus-glib-devel dbus-x11 \
  expat-devel glibc glibc-langpack-en gperf gtk3-devel httpd \
  java-17-amazon-corretto libatomic libcap-devel libjpeg-devel \
  libstdc++ libXScrnSaver-devel libxkbcommon-x11-devel mod_ssl \
  ncurses-compat-libs nspr-devel nss-devel pam-devel pciutils-devel \
  perl php php-cli pulseaudio-libs-devel python python-psutil \
  python-setuptools ruby xorg-x11-server-Xvfb zlib

# === Phase 3: Create directory structure ===
echo "=== Phase 3: Setup directories ==="
mkdir -p /srv/{build/chromium,source/chromium,lib}

# === Phase 4: Clone depot_tools and sync Chromium ===
echo "=== Phase 4: Sync Chromium source ==="
export PATH="$PATH:/srv/source/depot_tools"

git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git \
  /srv/source/depot_tools

# Write .gclient
cat > /srv/source/chromium/.gclient <<'GCLIENT'
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {
        "checkout_pgo_profiles": True,
    },
  },
]
GCLIENT

# Resolve git SHA from revision number
echo "Resolving git SHA for revision ${CHROMIUM_REVISION}..."
REVISION_JSON=$(curl -sf "https://cr-rev.appspot.com/_ah/api/crrev/v1/redirect/${CHROMIUM_REVISION}")
GIT_SHA=$(echo "$REVISION_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['git_sha'])")
echo "Git SHA: ${GIT_SHA}"

cd /srv/source/chromium
gclient sync --force --reset --delete_unversioned_trees \
  --revision "${GIT_SHA}" --with_branch_heads
gclient runhooks

# === Phase 5: Apply patches ===
echo "=== Phase 5: Apply patches ==="
cd /srv/source/chromium/src

# Patch sandbox_ipc_linux.cc: add failed_polls reset after PLOG
sed -i 's/^\(\s*\)PLOG(WARNING) << "poll";$/\1PLOG(WARNING) << "poll"; failed_polls = 0;/' \
  content/browser/sandbox_ipc_linux.cc

# Patch render_process_host_impl.cc: comment out CHECK(render_process_host->InSameStoragePartition...)
# These are three consecutive lines that need to be commented out
sed -i '/CHECK(render_process_host->InSameStoragePartition(/{
  s|^\(  \)\(\s*\)\(CHECK.*\)|  // \2\3|
  N; s|^\(  \)\(\s*\)\(browser_context->GetStoragePartition.*\)|  // \2\3|
  N; s|^\(  \)\(\s*\)\(false /\*.*\)|  // \2\3|
}' content/browser/renderer_host/render_process_host_impl.cc

# === Phase 6: Build x64 ===
echo "=== Phase 6: Build x64 ==="
mkdir -p out/Headless/x64

cat > out/Headless/x64/args.gn <<'ARGS'
import("//build/args/headless.gn")
blink_symbol_level = 0
dcheck_always_on = false
disable_histogram_support = false
enable_basic_print_dialog = false
enable_keystone_registration_framework = false
enable_linux_installer = false
enable_media_remoting = false
ffmpeg_branding = "Chrome"
is_component_build = false
is_debug = false
is_official_build = true
proprietary_codecs = true
symbol_level = 0
target_os = "linux"
use_sysroot = true
v8_symbol_level = 0
target_cpu="x64"
v8_target_cpu="x64"
ARGS

gn gen out/Headless/x64
autoninja -C out/Headless/x64 headless_shell

# Get version string
CHROME_VERSION=$(sed --regexp-extended 's~[^0-9]+~~g' chrome/VERSION | tr '\n' '.' | sed 's~[.]$~~')
echo "Chrome version: ${CHROME_VERSION}"

# Strip and compress x64 binary
strip -o /srv/build/chromium/chromium-${CHROME_VERSION} out/Headless/x64/headless_shell
cd /srv/build/chromium
brotli --best --force "chromium-${CHROME_VERSION}"
cd /srv/source/chromium/src

# Archive SwiftShader (x64)
tar --directory out/Headless/x64 --create --file /srv/build/chromium/swiftshader.tar \
  libEGL.so libGLESv2.so libvk_swiftshader.so libvulkan.so.1 vk_swiftshader_icd.json
cd /srv/build/chromium
brotli --best --force swiftshader.tar
cd /srv/source/chromium/src

# Package AL2023 x64 system libraries
tar --directory /usr/lib64 --create --file /srv/lib/al2023.tar \
  --transform='s,^libexpat\.so\.1\.9\.3$,libexpat.so.1,' \
  --transform='s,^,lib/,' \
  libexpat.so.1.9.3 libfreebl3.so libfreeblpriv3.so libnspr4.so libnss3.so \
  libnssutil3.so libplc4.so libplds4.so libsoftokn3.so libfreebl3.chk \
  libfreeblpriv3.chk libsoftokn3.chk
cd /srv/lib
brotli --best --force al2023.tar
cd /srv/source/chromium/src

# Upload x64 artifacts to S3
echo "Uploading x64 artifacts..."
aws s3 cp "/srv/build/chromium/chromium-${CHROME_VERSION}.br" \
  "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/x64/chromium-${CHROME_VERSION}.br"
aws s3 cp /srv/build/chromium/swiftshader.tar.br \
  "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/x64/swiftshader.tar.br"
aws s3 cp /srv/lib/al2023.tar.br \
  "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/x64/al2023.tar.br"

# === Phase 7: Build arm64 (cross-compile) ===
echo "=== Phase 7: Build arm64 (cross-compile) ==="

# Clean up x64 build artifacts from /srv/build/chromium to avoid filename collisions
rm -f /srv/build/chromium/chromium-${CHROME_VERSION} \
      /srv/build/chromium/chromium-${CHROME_VERSION}.br \
      /srv/build/chromium/swiftshader.tar \
      /srv/build/chromium/swiftshader.tar.br
rm -f /srv/lib/al2023.tar /srv/lib/al2023.tar.br

mkdir -p out/Headless/arm64

cat > out/Headless/arm64/args.gn <<'ARGS'
import("//build/args/headless.gn")
blink_symbol_level = 0
dcheck_always_on = false
disable_histogram_support = false
enable_basic_print_dialog = false
enable_keystone_registration_framework = false
enable_linux_installer = false
enable_media_remoting = false
ffmpeg_branding = "Chrome"
is_component_build = false
is_debug = false
is_official_build = true
proprietary_codecs = true
symbol_level = 0
target_os = "linux"
use_sysroot = true
v8_symbol_level = 0
target_cpu="arm64"
v8_target_cpu="arm64"
ARGS

# Install arm64 sysroot
./build/linux/sysroot_scripts/install-sysroot.py --arch=arm64

gn gen out/Headless/arm64
autoninja -C out/Headless/arm64 headless_shell

# Strip arm64 binary using cross-toolchain
wget -q https://releases.linaro.org/components/toolchain/binaries/latest-7/aarch64-linux-gnu/gcc-linaro-7.5.0-2019.12-x86_64_aarch64-linux-gnu.tar.xz
tar -xf gcc-linaro-7.5.0-2019.12-x86_64_aarch64-linux-gnu.tar.xz
./gcc-linaro-7.5.0-2019.12-x86_64_aarch64-linux-gnu/bin/aarch64-linux-gnu-strip \
  -o /srv/build/chromium/chromium-${CHROME_VERSION} out/Headless/arm64/headless_shell
cd /srv/build/chromium
brotli --best --force "chromium-${CHROME_VERSION}"
cd /srv/source/chromium/src

# Archive SwiftShader (arm64)
tar --directory out/Headless/arm64 --create --file /srv/build/chromium/swiftshader.tar \
  libEGL.so libGLESv2.so libvk_swiftshader.so libvulkan.so.1 vk_swiftshader_icd.json
cd /srv/build/chromium
brotli --best --force swiftshader.tar
cd /srv/source/chromium/src

# Upload arm64 artifacts to S3
echo "Uploading arm64 artifacts..."
aws s3 cp "/srv/build/chromium/chromium-${CHROME_VERSION}.br" \
  "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/arm64/chromium-${CHROME_VERSION}.br"
aws s3 cp /srv/build/chromium/swiftshader.tar.br \
  "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/arm64/swiftshader.tar.br"

# NOTE: arm64 AL2023 libs are built separately on a native ARM instance
# (see the arm-libs workflow / or pre-existing S3 artifacts)

# === Phase 8: Upload shared artifacts and notify ===
echo "=== Phase 8: Finalize ==="

# Upload fonts (if present — may be pre-built and committed to repo)
if [ -f /srv/build/chromium/fonts.tar.br ]; then
  aws s3 cp /srv/build/chromium/fonts.tar.br \
    "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/fonts.tar.br"
fi

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
```

**Step 2: Make executable**

```bash
chmod +x _/ec2/build-chromium.sh
```

**Step 3: Commit**

```bash
git add _/ec2/build-chromium.sh
git commit -m "feat: add self-contained EC2 build script for user-data execution"
```

---

## Task 3: Rewrite build-chromium.yml workflow

**Files:**

- Rewrite: `.github/workflows/build-chromium.yml`

Replace the entire workflow. The new version:

1. Creates an IAM-compatible security group (egress only, no SSH)
2. Encodes `build-chromium.sh` as user-data
3. Calls `aws ec2 run-instances` with user-data
4. Writes pending.json to S3
5. Waits for instance to enter `running` state
6. Posts PR comment and exits

**Step 1: Write the new workflow**

```yaml
name: Build Chromium

on:
  pull_request:
    types: [labeled]

permissions:
  contents: read
  pull-requests: write

jobs:
  build:
    name: Launch Chromium EC2 Build
    if: github.event.label.name == 'binaries:building'
    runs-on: ubuntu-latest
    environment: chromium-build
    timeout-minutes: 15

    env:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_DEFAULT_REGION: us-east-1
      S3_BUCKET: ${{ secrets.CHROMIUM_BUILD_S3_BUCKET }}

    steps:
      - name: Checkout
        uses: actions/checkout@v6
        with:
          ref: ${{ github.event.pull_request.head.sha }}

      - name: Get chromium revision
        id: revision
        run: |
          REVISION=$(cat _/ec2/revision.txt)
          echo "revision=${REVISION}" >> "$GITHUB_OUTPUT"
          echo "Chromium revision: ${REVISION}"

      - name: Prepare user-data script
        id: userdata
        env:
          REVISION: ${{ steps.revision.outputs.revision }}
          PR_NUMBER: ${{ github.event.pull_request.number }}
          GITHUB_PAT: ${{ secrets.RELEASE_TOKEN }}
          GITHUB_REPO_NAME: ${{ github.repository }}
        run: |
          # Create a wrapper that sets environment variables and runs the build script
          cat > /tmp/userdata.sh <<WRAPPER_EOF
          #!/bin/bash
          export CHROMIUM_REVISION="${REVISION}"
          export S3_BUCKET="${S3_BUCKET}"
          export GITHUB_PAT="${GITHUB_PAT}"
          export GITHUB_REPO="${GITHUB_REPO_NAME}"
          export PR_NUMBER="${PR_NUMBER}"
          export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION}"

          # The build script follows below
          WRAPPER_EOF

          # Append the build script
          cat _/ec2/build-chromium.sh >> /tmp/userdata.sh

          # Encode as base64 for user-data
          USER_DATA_B64=$(base64 -w 0 /tmp/userdata.sh)
          echo "userdata_b64=${USER_DATA_B64}" >> "$GITHUB_OUTPUT"

          # Verify size (user-data limit is 16 KB)
          SIZE=$(wc -c < /tmp/userdata.sh)
          echo "User-data script size: ${SIZE} bytes"
          if [ "$SIZE" -gt 16384 ]; then
            echo "::error::User-data script exceeds 16 KB limit (${SIZE} bytes)"
            exit 1
          fi

      - name: Find default VPC and subnet
        id: vpc
        run: |
          VPC_ID=$(aws ec2 describe-vpcs \
            --filters "Name=isDefault,Values=true" \
            --query 'Vpcs[0].VpcId' --output text)
          SUBNET_ID=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=${VPC_ID}" \
            --query 'Subnets[0].SubnetId' --output text)
          echo "vpc_id=${VPC_ID}" >> "$GITHUB_OUTPUT"
          echo "subnet_id=${SUBNET_ID}" >> "$GITHUB_OUTPUT"

      - name: Create security group (if needed)
        id: sg
        run: |
          SG_NAME="chromium-build"
          VPC_ID="${{ steps.vpc.outputs.vpc_id }}"

          SG_ID=$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
            --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

          if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
            echo "Creating security group..."
            SG_ID=$(aws ec2 create-security-group \
              --group-name "${SG_NAME}" \
              --description "Chromium build - egress only" \
              --vpc-id "${VPC_ID}" \
              --query 'GroupId' --output text)
            # Default SG already allows all egress; revoke default ingress
            # (default VPC SGs allow ingress from same SG — that's fine, no SSH rule added)
            echo "Security group created: ${SG_ID}"
          else
            echo "Security group exists: ${SG_ID}"
          fi
          echo "sg_id=${SG_ID}" >> "$GITHUB_OUTPUT"

      - name: Get AMI ID
        id: ami
        run: |
          AMI_ID=$(aws ssm get-parameters \
            --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64 \
            --query 'Parameters[0].Value' --output text)
          echo "ami_id=${AMI_ID}" >> "$GITHUB_OUTPUT"
          echo "AMI: ${AMI_ID}"

      - name: Create S3 pending marker
        env:
          PR_NUMBER: ${{ github.event.pull_request.number }}
          REVISION: ${{ steps.revision.outputs.revision }}
        run: |
          DEADLINE=$(date -u -d "+8 hours" +"%Y-%m-%dT%H:%M:%SZ")
          cat <<EOF > /tmp/pending.json
          {
            "revision": "${REVISION}",
            "pr_number": ${PR_NUMBER},
            "started_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
            "deadline": "${DEADLINE}",
            "repository": "${{ github.repository }}"
          }
          EOF
          aws s3 cp /tmp/pending.json "s3://${S3_BUCKET}/${REVISION}/pending.json"

      - name: Launch EC2 instance
        id: ec2
        env:
          REVISION: ${{ steps.revision.outputs.revision }}
        run: |
          INSTANCE_ID=$(aws ec2 run-instances \
            --image-id "${{ steps.ami.outputs.ami_id }}" \
            --instance-type c8id.8xlarge \
            --security-group-ids "${{ steps.sg.outputs.sg_id }}" \
            --subnet-id "${{ steps.vpc.outputs.subnet_id }}" \
            --associate-public-ip-address \
            --instance-initiated-shutdown-behavior terminate \
            --user-data "${{ steps.userdata.outputs.userdata_b64 }}" \
            --iam-instance-profile Name=chromium-build \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=chromium-build},{Key=Revision,Value=${REVISION}},{Key=PR,Value=${{ github.event.pull_request.number }}}]" \
            --query 'Instances[0].InstanceId' --output text)

          echo "instance_id=${INSTANCE_ID}" >> "$GITHUB_OUTPUT"
          echo "Launched: ${INSTANCE_ID}"

          # Wait for instance to be running
          aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}"
          echo "Instance is running"

          # Update pending marker with instance ID
          PENDING=$(aws s3 cp "s3://${S3_BUCKET}/${REVISION}/pending.json" -)
          echo "$PENDING" | jq --arg iid "$INSTANCE_ID" '. + {instance_id: $iid}' | \
            aws s3 cp - "s3://${S3_BUCKET}/${REVISION}/pending.json"

      - name: Comment on PR
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh pr comment ${{ github.event.pull_request.number }} --body "## Chromium Build Launched

          | | Value |
          |---|---|
          | **Revision** | \`${{ steps.revision.outputs.revision }}\` |
          | **Instance** | \`${{ steps.ec2.outputs.instance_id }}\` |
          | **S3 Location** | \`s3://${{ env.S3_BUCKET }}/${{ steps.revision.outputs.revision }}/\` |
          | **Instance Type** | c8id.8xlarge |
          | **Deadline** | 8 hours from now |

          The EC2 instance is running autonomously. No SSH or GitHub runner connection is needed.
          The instance will upload artifacts to S3, notify this PR, and self-terminate."

      - name: Emergency teardown (on failure)
        if: failure()
        run: |
          INSTANCE_ID="${{ steps.ec2.outputs.instance_id }}"
          if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "" ]; then
            aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" || true
          fi
          # Also terminate by tag as fallback
          aws ec2 terminate-instances --instance-ids $(
            aws ec2 describe-instances \
              --filters "Name=tag:Name,Values=chromium-build" "Name=instance-state-name,Values=running,pending" \
              --query 'Reservations[].Instances[].InstanceId' --output text
          ) 2>/dev/null || true
          # Clean up SG
          aws ec2 delete-security-group \
            --group-id "${{ steps.sg.outputs.sg_id }}" 2>/dev/null || true
```

**Step 2: Commit**

```bash
git add .github/workflows/build-chromium.yml
git commit -m "feat: rewrite build-chromium workflow to use EC2 user-data (fire-and-forget)"
```

---

## Task 4: Update build-safety-net.yml for new tag name

**Files:**

- Modify: `.github/workflows/build-safety-net.yml:66-70`

The old Ansible playbook tagged instances as `Name=Chromium`. The new workflow tags them as `Name=chromium-build`. Update the safety net to match.

**Step 1: Update tag filter**

Change the fallback termination command:

```bash
# Old:
aws ec2 terminate-instances --instance-ids $(
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=Chromium" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text
) 2>/dev/null || true

# New:
aws ec2 terminate-instances --instance-ids $(
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=chromium-build" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text
) 2>/dev/null || true
```

**Step 2: Commit**

```bash
git add .github/workflows/build-safety-net.yml
git commit -m "fix: update safety-net tag filter to match new instance tag"
```

---

## Task 5: Delete Ansible directory

**Files:**

- Delete: `_/ansible/` (entire directory)

Everything has been migrated:

- `inventory.ini` → `_/ec2/revision.txt`
- `plays/.gclient` → `_/ec2/.gclient` (and also inlined in build script)
- `plays/chromium.yml`, `build-x64.yml`, `build-arm64.yml` → `_/ec2/build-chromium.sh`
- `plays/files/upload-artifacts.sh` → integrated into `_/ec2/build-chromium.sh`
- `plays/teardown.yml`, `plays/teardown-tasks.yml` → replaced by `instance_initiated_shutdown_behavior: terminate` + safety-net workflow
- `plays/arm-libs.yml` → still needed? (see note below)
- `ansible.cfg`, `Makefile`, `README.md` → no longer needed

**Note on arm-libs.yml:** This playbook launches a separate ARM64 EC2 instance to build AL2023 arm64 system libraries. The main build does NOT cross-compile these (they must be built on native ARM hardware). Two options:

- Create a separate `_/ec2/build-arm-libs.sh` user-data script (future task)
- Assume arm64 libs are already in S3 from a previous build

For now, remove Ansible and note that arm64 libs need a separate mechanism. This is consistent with the current `build-chromium.sh` which has a comment: `# NOTE: arm64 AL2023 libs are built separately`.

**Step 1: Delete the directory**

```bash
rm -rf _/ansible
```

**Step 2: Commit**

```bash
git add -A _/ansible
git commit -m "chore: remove Ansible directory (replaced by EC2 user-data build)"
```

---

## Task 6: Update build-complete.yml to handle build log URL

**Files:**

- Modify: `.github/workflows/build-complete.yml:44-52`

The new build script uploads `build.log` to S3. Add the log URL to the success/failure PR comments.

**Step 1: Update success comment**

In the "Handle success" step, add the build log link:

```yaml
gh pr comment "${PR_NUMBER}" --repo "${{ github.repository }}" --body "## Build Complete

Chromium revision \`${REVISION}\` built successfully.
Binaries are available in S3. Tests will run automatically.

| Architecture | S3 Path |
|---|---|
| x64 | \`s3://${S3_BUCKET}/${REVISION}/x64/\` |
| arm64 | \`s3://${S3_BUCKET}/${REVISION}/arm64/\` |
| Build Log | \`s3://${S3_BUCKET}/${REVISION}/build.log\` |"
```

**Step 2: Update failure comment**

In the "Handle failure" step, add log URL and error from payload:

```yaml
          gh pr comment "${PR_NUMBER}" --repo "${{ github.repository }}" --body "## Build Failed

          Chromium revision \`${REVISION}\` build failed.
          Status: \`${{ github.event.client_payload.status }}\`
          Error: \`${{ github.event.client_payload.error }}\`

          Build log: \`s3://${S3_BUCKET}/${REVISION}/build.log\`

          To retry, remove the \`binaries:failed\` label and re-add \`binaries:building\`."
```

**Step 3: Commit**

```bash
git add .github/workflows/build-complete.yml
git commit -m "feat: add build log S3 URL to PR comments"
```

---

## Task 7: Create IAM instance profile documentation

**Files:**

- Create: `_/ec2/README.md`

The EC2 instance needs an IAM instance profile named `chromium-build` with these permissions. This must be created manually in the AWS account (one-time setup).

**Step 1: Write README**

````markdown
# EC2 Chromium Build

## Overview

The `build-chromium.sh` script runs on EC2 via user-data to compile Chromium
headless_shell for x64 and arm64. The instance self-terminates on completion.

## AWS Prerequisites (one-time setup)

### IAM Instance Profile: `chromium-build`

Create an IAM role named `chromium-build` with the following policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ArtifactUpload",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": ["arn:aws:s3:::BUCKET_NAME", "arn:aws:s3:::BUCKET_NAME/*"]
    }
  ]
}
```
````

Attach trust policy for EC2:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

Then create an instance profile with the same name and associate the role:

```bash
aws iam create-instance-profile --instance-profile-name chromium-build
aws iam add-role-to-instance-profile \
  --instance-profile-name chromium-build --role-name chromium-build
```

### GitHub Secrets

| Secret                     | Description                                                                    |
| -------------------------- | ------------------------------------------------------------------------------ |
| `AWS_ACCESS_KEY_ID`        | IAM user credentials for the GHA runner (EC2 launch, S3 marker, SG management) |
| `AWS_SECRET_ACCESS_KEY`    | Corresponding secret key                                                       |
| `CHROMIUM_BUILD_S3_BUCKET` | S3 bucket name for artifacts                                                   |
| `RELEASE_TOKEN`            | GitHub PAT with `repo` scope (for `repository_dispatch`)                       |

### Security Group: `chromium-build`

Created automatically by the workflow. Allows egress only (no SSH).

## Build Process

1. GHA workflow launches EC2 with `build-chromium.sh` as user-data
2. Instance schedules 8-hour self-destruct (`shutdown -h +480`)
3. Installs dependencies, syncs Chromium source, applies patches
4. Builds x64 and arm64 (cross-compile) headless_shell
5. Strips, brotli-compresses, uploads to S3
6. Sends `repository_dispatch` event to GitHub
7. Instance shuts down (terminates via `instance_initiated_shutdown_behavior`)

## Local Testing

To test the build script locally on an EC2 instance:

```bash
export CHROMIUM_REVISION=1596535
export S3_BUCKET=your-bucket
export GITHUB_PAT=ghp_xxx
export GITHUB_REPO=owner/repo
export PR_NUMBER=123
export AWS_DEFAULT_REGION=us-east-1

bash build-chromium.sh
```

````

**Step 2: Commit**

```bash
git add _/ec2/README.md
git commit -m "docs: add EC2 build README with IAM setup instructions"
````

---

## Task 8: Verify and test

This task cannot be automated — it requires AWS infrastructure. Manual verification checklist:

1. **IAM instance profile exists:** `aws iam get-instance-profile --instance-profile-name chromium-build`
2. **Revision file is correct:** `cat _/ec2/revision.txt` returns a number
3. **User-data size check:** `wc -c < _/ec2/build-chromium.sh` must be well under 16 KB (the wrapper adds ~300 bytes for env vars)
4. **Workflow dry-run:** Push to a test branch, create a PR, add `binaries:building` label. Verify:
   - Instance launches with correct tags
   - pending.json appears in S3
   - PR gets a comment
   - GHA job completes in <5 minutes
5. **Build completion:** Wait for EC2 to finish (~5 hours). Verify:
   - Artifacts appear in `s3://bucket/revision/x64/` and `s3://bucket/revision/arm64/`
   - `completed.json` appears in S3
   - `pending.json` is removed
   - `build-complete` workflow fires
   - PR gets `binaries:available` label
   - Test workflows trigger
6. **Failure path:** Test by introducing a build error (bad revision). Verify:
   - `notify_failure` runs
   - `completed.json` with `status: "failed"` appears in S3
   - `build.log` is uploaded
   - `repository_dispatch` with failure status fires
   - Instance terminates

---

## File Inventory (Final State)

### New files

| File                                           | Purpose                         |
| ---------------------------------------------- | ------------------------------- |
| `_/ec2/revision.txt`                           | Chromium revision number        |
| `_/ec2/.gclient`                               | gclient configuration           |
| `_/ec2/build-chromium.sh`                      | Self-contained EC2 build script |
| `_/ec2/README.md`                              | IAM setup and documentation     |
| `docs/plans/2026-04-13-ec2-user-data-build.md` | This plan                       |

### Modified files

| File                                          | Change                         |
| --------------------------------------------- | ------------------------------ |
| `.github/workflows/build-chromium.yml`        | Rewritten: AWS CLI + user-data |
| `.github/workflows/build-complete.yml`        | Add build log URL to comments  |
| `.github/workflows/build-safety-net.yml`      | Update tag filter              |
| `.github/workflows/check-chromium-update.yml` | Read from revision.txt         |
| `.github/workflows/check-pr-binaries.yml`     | Check revision.txt for changes |
| `.github/workflows/test-x64.yml`              | Read from revision.txt         |
| `.github/workflows/test-arm.yml`              | Read from revision.txt         |
| `tools/update-browser-revision.mjs`           | Write to revision.txt          |

### Deleted files

| File                            | Reason               |
| ------------------------------- | -------------------- |
| `_/ansible/` (entire directory) | Replaced by `_/ec2/` |

### Unchanged files

| File                                    | Why unchanged                            |
| --------------------------------------- | ---------------------------------------- |
| `.github/workflows/prepare-release.yml` | Doesn't reference Ansible or revision    |
| `.github/workflows/release.yml`         | Downloads from S3, no Ansible dependency |
| `Makefile`                              | Root Makefile has no Ansible references  |
| `_/amazon/`                             | SAM templates unchanged                  |

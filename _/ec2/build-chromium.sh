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

# Create 16GB swap file on NVMe — safety net for linker OOM during ThinLTO
echo "Creating 16GB swap file..."
fallocate -l 16G /srv/swapfile
chmod 600 /srv/swapfile
mkswap /srv/swapfile
swapon /srv/swapfile
echo "Swap enabled: $(swapon --show)"

# === Phase 2: Install system dependencies ===
echo "=== Phase 2: Install dependencies ==="

# Critical for ThinLTO/official builds — linker will crash without this
sysctl -w vm.max_map_count=262144

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

# Prepend depot_tools to PATH so it takes priority
export PATH="/srv/source/depot_tools:$PATH"

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
# These are three consecutive lines that each need to be individually commented out
sed -i 's|^\(  \)\(\s*\)\(CHECK(render_process_host->InSameStoragePartition(\)$|  // \2\3|' \
  content/browser/renderer_host/render_process_host_impl.cc
sed -i 's|^\(  \)\(\s*\)\(browser_context->GetStoragePartition(site_instance,\)$|  // \2\3|' \
  content/browser/renderer_host/render_process_host_impl.cc
sed -i 's|^\(  \)\(\s*\)\(false /\* can_create \*/)));\)$|  // \2\3|' \
  content/browser/renderer_host/render_process_host_impl.cc

echo "Patches applied"

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
strip -o /srv/build/chromium/chromium-"${CHROME_VERSION}" out/Headless/x64/headless_shell
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

# Clean up x64 build artifacts to avoid filename collisions
rm -f /srv/build/chromium/chromium-"${CHROME_VERSION}" \
      /srv/build/chromium/chromium-"${CHROME_VERSION}".br \
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

# Strip arm64 binary using Chromium's bundled llvm-strip (cross-compatible)
third_party/llvm-build/Release+Asserts/bin/llvm-strip \
  -o /srv/build/chromium/chromium-"${CHROME_VERSION}" out/Headless/arm64/headless_shell
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

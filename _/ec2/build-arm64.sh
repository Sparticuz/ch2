#!/bin/bash
# build-arm64.sh — Sourced by build-chromium.sh
# Cross-compiles, strips, compresses, and uploads arm64 headless_shell.
#
# Expects from orchestrator/setup: CHROMIUM_REVISION, CHROME_VERSION, S3_BUCKET,
#   SCRIPT_DIR, notify_failure, ERR trap, PATH with depot_tools, cwd=/srv/source/chromium/src

echo "=== Build arm64 (cross-compile) ==="
report_progress "build-arm64:compile" "Cross-compiling arm64 headless_shell"
mkdir -p out/Headless/arm64

cp "$SCRIPT_DIR/args-arm64.gn" out/Headless/arm64/args.gn

# Install arm64 sysroot
./build/linux/sysroot_scripts/install-sysroot.py --arch=arm64

gn gen out/Headless/arm64
autoninja -C out/Headless/arm64 headless_shell

# Strip arm64 binary using Chromium's bundled llvm-strip (cross-compatible)
third_party/llvm-build/Release+Asserts/bin/llvm-strip \
  -o /srv/build/chromium/chromium-"${CHROME_VERSION}" out/Headless/arm64/headless_shell
brotli --best --force /srv/build/chromium/"chromium-${CHROME_VERSION}"

# Archive SwiftShader
tar --directory out/Headless/arm64 --create --file /srv/build/chromium/swiftshader.tar \
  libEGL.so libGLESv2.so libvk_swiftshader.so libvulkan.so.1 vk_swiftshader_icd.json
brotli --best --force /srv/build/chromium/swiftshader.tar

# Upload arm64 artifacts to S3
echo "Uploading arm64 artifacts..."
report_progress "build-arm64:upload" "Uploading arm64 artifacts to S3"
aws s3 cp "/srv/build/chromium/chromium-${CHROME_VERSION}.br" \
  "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/arm64/chromium.br"
aws s3 cp /srv/build/chromium/swiftshader.tar.br \
  "s3://${S3_BUCKET}/${CHROMIUM_REVISION}/arm64/swiftshader.tar.br"

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

# NOTE: arm64 AL2023 libs are built separately on a native ARM instance

echo "arm64 build complete"

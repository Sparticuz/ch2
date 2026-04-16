# Security Remediations Design (SEC-006, SEC-002, SEC-003)

Date: 2026-04-15

## SEC-006: Checksum Verification in release.yml

**Problem:** `release.yml` downloads binaries from S3 and publishes to npm without verifying integrity. `manifest.json` with SHA-256 checksums already exists in S3 but is explicitly excluded from download (`--exclude "*.json"`).

**Design:** After the S3 sync step in `release.yml`:

1. Download `manifest.json` from S3 for the revision (extract revision from `package.json`)
2. For each binary listed in manifest (x64/arm64 chromium.br, swiftshader.tar.br, al2023.tar.br, fonts.tar.br), compute `sha256sum` of the downloaded file
3. Compare against the manifest value; fail the release if any mismatch

**Trust model:** S3-only. Defends against partial corruption and CDN/transport tampering. Does not defend against full bucket compromise (that would require git-anchored checksums, which adds complexity disproportionate to the threat).

**Changes:**

- `release.yml`: Add "Verify checksums" step after S3 download, before npm publish
- Download `manifest.json` via separate `aws s3 cp` (since the sync excludes JSON)
- Use `jq` to extract expected hashes, `sha256sum` to compute actual, string comparison to verify

## SEC-002: Restrict isValidUrl to HTTPS

**Problem:** `isValidUrl()` in `source/helper.ts` accepts any URL scheme (`file://`, `ftp://`, etc.). The only caller is `executablePath()` which downloads a tar pack — allowing arbitrary schemes could enable SSRF or local file access.

**Design:** Restrict to `https://` only. For development/testing convenience, also allow `http://` when the hostname is `localhost` or `127.0.0.1`.

**Changes:**

- `source/helper.ts`: Add scheme check after URL parsing
- `tests/chromium.test.ts`: Update tests — `ftp://` becomes invalid, add explicit `http://localhost` test

## SEC-003: Dispatch Sender Validation in build-complete.yml

**Problem:** `build-complete.yml` processes any `repository_dispatch` of type `build-complete` without checking whether a build was actually in progress. Anyone with repo write access could send a spoofed dispatch.

**Design:** Add a validation step that checks the `binaries:building` label exists on the PR referenced in the payload. If not present, skip processing and post a warning comment.

**Changes:**

- `build-complete.yml`: Add "Validate dispatch" step before payload processing that fetches PR labels and checks for `binaries:building`

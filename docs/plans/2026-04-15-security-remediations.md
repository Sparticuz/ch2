# Security Remediations Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix three security findings: checksum verification in release.yml (SEC-006), URL scheme restriction in isValidUrl (SEC-002), and dispatch sender validation in build-complete.yml (SEC-003).

**Architecture:** Three independent changes to workflows and source code. SEC-002 has unit tests; SEC-006 and SEC-003 are workflow-only changes testable via dry-run logic review.

**Tech Stack:** GitHub Actions YAML, TypeScript, vitest

---

### Task 1: SEC-002 — Restrict isValidUrl to HTTPS

**Files:**

- Modify: `source/helper.ts:69-75`
- Modify: `tests/chromium.test.ts:219-231`

**Step 1: Update the test expectations**

In `tests/chromium.test.ts`, update the `isValidUrl` test block:

```typescript
describe("isValidUrl", () => {
  it("should return true for valid HTTPS URLs", () => {
    expect(isValidUrl("https://example.com")).toBe(true);
    expect(isValidUrl("https://example.com/path/to/pack.tar")).toBe(true);
  });

  it("should return true for localhost HTTP URLs (development)", () => {
    expect(isValidUrl("http://localhost:3000")).toBe(true);
    expect(isValidUrl("http://127.0.0.1:8080/pack.tar")).toBe(true);
  });

  it("should return false for non-HTTPS URLs", () => {
    expect(isValidUrl("http://example.com")).toBe(false);
    expect(isValidUrl("ftp://ftp.example.com")).toBe(false);
    expect(isValidUrl("file:///etc/passwd")).toBe(false);
  });

  it("should return false for invalid URLs", () => {
    expect(isValidUrl("not-a-url")).toBe(false);
    expect(isValidUrl("http://")).toBe(false);
    expect(isValidUrl("")).toBe(false);
  });
});
```

**Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/chromium.test.ts -t "isValidUrl"`
Expected: FAIL — `ftp://ftp.example.com` still returns `true`, `http://example.com` still returns `true`

**Step 3: Update isValidUrl implementation**

In `source/helper.ts`, replace lines 69-75:

```typescript
export const isValidUrl = (input: string) => {
  try {
    const url = new URL(input);
    if (url.protocol === "https:") return true;
    // Allow http:// only for localhost/127.0.0.1 (development/testing)
    if (
      url.protocol === "http:" &&
      (url.hostname === "localhost" || url.hostname === "127.0.0.1")
    ) {
      return true;
    }
    return false;
  } catch {
    return false;
  }
};
```

**Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/chromium.test.ts -t "isValidUrl"`
Expected: PASS

**Step 5: Run full test suite (non-integration)**

Run: `npx vitest run tests/chromium.test.ts --testPathIgnorePatterns=Integration`
Expected: All Helper and Paths tests pass

**Step 6: Commit**

```bash
git add source/helper.ts tests/chromium.test.ts
git commit -m "fix(SEC-002): restrict isValidUrl to HTTPS (allow http for localhost only)"
```

---

### Task 2: SEC-003 — Validate dispatch sender in build-complete.yml

**Files:**

- Modify: `.github/workflows/build-complete.yml:22-34`

**Step 1: Add validation step after "Parse payload"**

Insert a new step between "Parse payload" (line 34) and "Handle success" (line 36). This step checks that `binaries:building` exists on the PR:

```yaml
- name: Validate dispatch
  env:
    GH_TOKEN: ${{ github.token }}
    PR_NUMBER: ${{ steps.payload.outputs.pr_number }}
    REVISION: ${{ steps.payload.outputs.revision }}
  id: validate
  run: |
    # Verify PR exists and has binaries:building label
    LABELS=$(gh api "repos/${{ github.repository }}/issues/${PR_NUMBER}/labels" --jq '.[].name' 2>/dev/null || echo "")

    if ! echo "$LABELS" | grep -q '^binaries:building$'; then
      echo "::warning::Dispatch rejected — PR #${PR_NUMBER} does not have binaries:building label"
      gh pr comment "${PR_NUMBER}" --repo "${{ github.repository }}" --body "⚠️ **Dispatch rejected:** Received \`build-complete\` for revision \`${REVISION}\`, but \`binaries:building\` label is not present. Ignoring." || true
      echo "valid=false" >> "$GITHUB_OUTPUT"
      exit 0
    fi

    echo "valid=true" >> "$GITHUB_OUTPUT"
```

**Step 2: Gate subsequent steps on validation**

Add `&& steps.validate.outputs.valid == 'true'` to the `if` conditions of "Handle success", "Handle failure", and "Clean up S3 pending marker" steps:

- Line 37: `if: steps.payload.outputs.status == 'success' && steps.validate.outputs.valid == 'true'`
- Line 112: `if: steps.payload.outputs.status != 'success' && steps.validate.outputs.valid == 'true'`
- Line 158 (Clean up): add `if: steps.validate.outputs.valid == 'true'` (was unconditional)

**Step 3: Review the complete file for correctness**

Verify indentation, step IDs, and output references are consistent.

**Step 4: Commit**

```bash
git add .github/workflows/build-complete.yml
git commit -m "fix(SEC-003): validate binaries:building label before processing dispatch"
```

---

### Task 3: SEC-006 — Checksum verification in release.yml

**Files:**

- Modify: `.github/workflows/release.yml:36-57`

**Step 1: Add checksum verification step**

Insert a new step after "Download binaries from S3" (after line 57) and before "npm run build" (line 59):

```yaml
- name: Verify binary checksums
  env:
    AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
    AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    AWS_DEFAULT_REGION: us-east-1
    S3_BUCKET: ${{ secrets.CHROMIUM_BUILD_S3_BUCKET }}
  run: |
    REVISION="${{ steps.revision.outputs.revision }}"

    # Download manifest (contains SHA-256 checksums from build time)
    aws s3 cp "s3://${S3_BUCKET}/${REVISION}/manifest.json" /tmp/manifest.json

    echo "Verifying binary checksums against manifest..."
    FAILED=0

    verify() {
      local FILE="$1" JQ_PATH="$2"
      if [ ! -f "$FILE" ]; then
        echo "SKIP: $FILE not found"
        return
      fi
      EXPECTED=$(jq -r "$JQ_PATH" /tmp/manifest.json)
      if [ "$EXPECTED" = "null" ] || [ -z "$EXPECTED" ]; then
        echo "WARN: No checksum in manifest for $FILE"
        return
      fi
      ACTUAL=$(sha256sum "$FILE" | cut -d' ' -f1)
      if [ "$ACTUAL" != "$EXPECTED" ]; then
        echo "FAIL: $FILE"
        echo "  expected: $EXPECTED"
        echo "  actual:   $ACTUAL"
        FAILED=1
      else
        echo "OK: $FILE ($ACTUAL)"
      fi
    }

    verify bin/x64/chromium.br       '.x64.binaries["chromium.br"].sha256'
    verify bin/x64/swiftshader.tar.br '.x64.binaries["swiftshader.tar.br"].sha256'
    verify bin/x64/al2023.tar.br      '.x64.binaries["al2023.tar.br"].sha256'
    verify bin/arm64/chromium.br       '.arm64.binaries["chromium.br"].sha256'
    verify bin/arm64/swiftshader.tar.br '.arm64.binaries["swiftshader.tar.br"].sha256'
    verify bin/arm64/al2023.tar.br     '.arm64.binaries["al2023.tar.br"].sha256'
    verify bin/fonts.tar.br            '.fonts["fonts.tar.br"].sha256'

    if [ "$FAILED" -eq 1 ]; then
      echo "::error::Checksum verification failed — aborting release"
      exit 1
    fi
    echo "All checksums verified successfully"
```

**Step 2: Review the complete file for correctness**

Verify the step has proper `env` block, correct jq paths matching the manifest structure, and that it runs before `npm run build` and `npm publish`.

**Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "fix(SEC-006): verify binary checksums against manifest before npm publish"
```

---

### Task 4: Push and verify

**Step 1: Push all commits to master**

```bash
git push origin master
```

**Step 2: Rebase PR #5 on master**

```bash
git checkout chore/chromium-update-1596535
git rebase master
git push --force-with-lease origin chore/chromium-update-1596535
git checkout master
```

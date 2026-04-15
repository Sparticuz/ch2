# Label State Machine + Dynamic PR Checklist

## Overview

Replace the current ad-hoc label usage with a formal state machine where labels serve two purposes:

1. **Triggers** — maintainer adds a label to direct a workflow action
2. **Status** — workflows swap trigger labels for status labels, giving visual feedback on the PR

Additionally, the PR description is dynamically updated with a maintainer checklist that tracks progress through the pipeline.

## Labels

### State labels (set by automation)

| Label                | Color            | Set by                                   | Meaning                           |
| -------------------- | ---------------- | ---------------------------------------- | --------------------------------- |
| `binaries:needed`    | yellow `#FBCA04` | check-chromium-update, check-pr-binaries | Revision changed, binaries needed |
| `binaries:building`  | gray `#ededed`   | build-chromium.yml                       | EC2 build in progress             |
| `binaries:available` | blue `#1D76DB`   | build-complete.yml                       | Binaries uploaded to S3           |
| `binaries:failed`    | red `#D93F0B`    | build-complete.yml, test.yml, safety-net | Build or test failed              |
| `binaries:testing`   | gray `#ededed`   | test.yml                                 | Tests in progress                 |
| `binaries:verified`  | green `#0E8A16`  | test.yml                                 | Tests + VR passed                 |

### Trigger labels (set by maintainer, consumed by workflows)

| Label            | Color            | Consumed by        | Effect                 |
| ---------------- | ---------------- | ------------------ | ---------------------- |
| `binaries:build` | purple `#5319E7` | build-chromium.yml | Starts EC2 build       |
| `binaries:test`  | purple `#5319E7` | test.yml           | Starts test + VR suite |

### Modifier labels (read-only, not part of state machine)

| Label             | Color           | Read by            | Effect                      |
| ----------------- | --------------- | ------------------ | --------------------------- |
| `build:on-demand` | red `#D93F0B`   | build-chromium.yml | Use on-demand EC2 pricing   |
| `build:ssh`       | green `#0E8A16` | build-chromium.yml | Enable SSH + screen session |

## State Machine

```
PR created (check-chromium-update)
    |
    v
[binaries:needed]
    |
    | maintainer adds binaries:build
    v
[binaries:building]         build-chromium.yml removes binaries:build,
    |                       removes binaries:needed, removes binaries:failed,
    |                       adds binaries:building
    |
    +-- success --> [binaries:available]     build-complete.yml removes
    |                                        binaries:building, adds binaries:available
    |
    +-- failure --> [binaries:failed]        build-complete.yml removes
                        |                    binaries:building, adds binaries:failed
                        |
                        | maintainer adds binaries:build (retry)
                        v
                    [binaries:building]      cycle repeats

[binaries:available]
    |
    | maintainer adds binaries:test
    v
[binaries:testing]          test.yml removes binaries:test,
    |                       adds binaries:testing
    |
    +-- all pass --> [binaries:verified]     test.yml removes binaries:testing,
    |                                        removes binaries:available,
    |                                        adds binaries:verified
    |
    +-- failure --> [binaries:failed]        test.yml removes binaries:testing,
                                             adds binaries:failed
```

## Workflow Changes

### build-chromium.yml

- **Trigger:** `pull_request: [labeled]` with gate `github.event.label.name == 'binaries:build'`
- **On start:** Remove `binaries:build`, `binaries:needed`, `binaries:failed`. Add `binaries:building`.
- **Update PR checklist:** Mark "Build started" checked, set "you are here" to build in progress.

### build-complete.yml

- **No change to trigger:** `repository_dispatch: [build-complete]`
- **On success:** Remove `binaries:building`. Add `binaries:available`. Use `GITHUB_TOKEN` (not PAT).
- **On failure:** Remove `binaries:building`. Add `binaries:failed`.
- **Update PR checklist:** Mark "Binaries built" checked (with sizes), set "you are here" to add `binaries:test`.

### test.yml

- **Trigger change:** `pull_request: [labeled]` with gate on `binaries:test` (replaces `binaries:available`)
- **Push to master:** Still runs unconditionally (no label needed).
- **On start (new step):** Remove `binaries:test`, `binaries:failed`. Add `binaries:testing`. Update PR checklist.
- **On all pass (new job):** Remove `binaries:testing`, `binaries:available`. Add `binaries:verified`. Update PR checklist.
- **On failure (new job):** Remove `binaries:testing`. Add `binaries:failed`. Update PR checklist.

### check-pr-binaries.yml

- Unchanged in logic. Still adds `binaries:needed` when revision.txt changes on a new PR.

### check-chromium-update.yml

- PR body template updated to include checklist markers.
- Still applies `binaries:needed` at creation.

### build-safety-net.yml

- Unchanged. Still swaps `binaries:building` → `binaries:failed` for stale builds.

## Dynamic PR Checklist

The PR body contains a section between HTML comment markers that workflows update:

```markdown
<!-- checklist-start -->

### Maintainer Checklist

- [x] Revision bump detected — `1` → `1596535`
- [ ] **Add `binaries:build` to start EC2 build** ← you are here
- [ ] Binaries built and uploaded to S3
- [ ] **Add `binaries:test` to run tests**
- [ ] Tests and visual regression passed
<!-- checklist-end -->
```

Each workflow patches the PR body by replacing content between the markers. The rest of the PR body (Chromium Update table, Build Options) is untouched.

### Checklist states

**Initial (PR created):**

```
- [x] Revision bump detected — `1` → `1596535`
- [ ] **Add `binaries:build` to start EC2 build** ← you are here
- [ ] Binaries built and uploaded to S3
- [ ] **Add `binaries:test` to run tests**
- [ ] Tests and visual regression passed
```

**Build in progress:**

```
- [x] Revision bump detected — `1` → `1596535`
- [x] Build started
- [ ] Binaries built and uploaded to S3 ← building...
- [ ] **Add `binaries:test` to run tests**
- [ ] Tests and visual regression passed
```

**Build complete:**

```
- [x] Revision bump detected — `1` → `1596535`
- [x] Build started
- [x] Binaries built and uploaded to S3 (x64: 60.6 MB, arm64: 55.3 MB)
- [ ] **Add `binaries:test` to run tests** ← you are here
- [ ] Tests and visual regression passed
```

**Build failed:**

```
- [x] Revision bump detected — `1` → `1596535`
- [x] Build started
- [ ] ~~Binaries built~~ — **build failed** (add `binaries:build` to retry) ← you are here
- [ ] **Add `binaries:test` to run tests**
- [ ] Tests and visual regression passed
```

**Testing in progress:**

```
- [x] Revision bump detected — `1` → `1596535`
- [x] Build started
- [x] Binaries built and uploaded to S3 (x64: 60.6 MB, arm64: 55.3 MB)
- [x] Tests started
- [ ] Tests and visual regression passed ← testing...
```

**Tests passed:**

```
- [x] Revision bump detected — `1` → `1596535`
- [x] Build started
- [x] Binaries built and uploaded to S3 (x64: 60.6 MB, arm64: 55.3 MB)
- [x] Tests started
- [x] Tests and visual regression passed
```

**Tests failed:**

```
- [x] Revision bump detected — `1` → `1596535`
- [x] Build started
- [x] Binaries built and uploaded to S3 (x64: 60.6 MB, arm64: 55.3 MB)
- [x] Tests started
- [ ] ~~Tests passed~~ — **tests failed** (add `binaries:test` to retry) ← you are here
```

## Token Changes

- `build-complete.yml` switches from `RELEASE_TOKEN` (PAT) to `GITHUB_TOKEN` for label operations. The PAT is no longer needed for the label flow since `test.yml` now triggers on maintainer-added `binaries:test`, not on automated `binaries:available`.
- `RELEASE_TOKEN` may still be needed by `build-complete.yml` for other purposes (e.g., updating PR body requires `pull-requests: write`). Evaluate during implementation whether `GITHUB_TOKEN` with appropriate permissions suffices for all operations in that workflow.

## Constraints

- `GITHUB_TOKEN` label events do not trigger other workflows — this is fine now since all cross-workflow triggers come from maintainer actions (adding `binaries:build` or `binaries:test` through the GitHub UI).
- The `check-binaries` gate job in `test.yml` is removed or simplified — the `binaries:test` label is the only PR trigger, and it inherently means "binaries are available, run tests."
- Push-to-master path in `test.yml` remains unchanged (no labels involved).

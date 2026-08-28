# Releasing

[English](./RELEASING.md) · [한국어](./ko/RELEASING.md)

Releases are immutable source/runtime boundaries. The published source bundle
must come from the exact annotated tag and includes the documentation needed to
reproduce the installation. The installed runtime is self-contained and does
not depend on the checkout's root `Makefile`, ordinary `scripts/`, or `docs/`.

## Prepare the version

`VERSION` contains exactly one strict core SemVer line:

```text
MAJOR.MINOR.PATCH
```

The application and E2E package metadata, lockfiles, Gateway/MCP build version,
Compose runtime image suffix, and first `CHANGELOG.md` heading must agree with
it. Keep release metadata changes in the release task; do not infer a version
from a branch name.

Before tagging, run the repository's normal CI/local gates and inspect the
resulting tree. The publish workflow is authoritative and runs CI success checks
for the exact commit, release-version validation, runtime/install checks, and
source-bundle verification.

## Create an immutable tag

A release tag must be exactly `vMAJOR.MINOR.PATCH`, must be an annotated tag,
and must point at the commit that is already on `main`:

```bash
version=$(tr -d '\n' < VERSION)
git status --short
git fetch --no-tags origin main
git show-ref --verify --quiet "refs/remotes/origin/main"
git tag -a "v${version}" -m "AgentOTelStack v${version}" "origin/main"
git push origin "v${version}"
```

Do not retag a different commit after pushing. The release workflow checks the
tag object, peels it to a commit, confirms that commit is an ancestor of the
freshly fetched `origin/main`, and validates `VERSION` and release metadata.

## Build and verify a source bundle locally

`build-release-source.sh` accepts an exact tag and output directory. Publish mode
requires the checkout HEAD to equal the tag commit and the tree to be clean:

```bash
mkdir -p dist
./scripts/build-release-source.sh "v${version}" dist
```

It writes exactly this pair:

```text
AgentOTelStack-v${version}.tar.gz
AgentOTelStack-v${version}.tar.gz.sha256
```

The archive walk is explicit and deterministic: paths are sorted, tar/gzip
metadata is normalized, unsafe links and secret/generated/retired paths are
rejected, required source inputs are checked, and the verifier runs before the
pair is published. The checksum is a single basename-only SHA-256 line.

Verify the pair independently:

```bash
./scripts/verify-release-source.sh --version "$version" \
  "dist/AgentOTelStack-v${version}.tar.gz" \
  "dist/AgentOTelStack-v${version}.tar.gz.sha256"

# Linux
(cd dist && sha256sum --check "AgentOTelStack-v${version}.tar.gz.sha256")

# macOS
(cd dist && shasum -a 256 -c "AgentOTelStack-v${version}.tar.gz.sha256")
```

`RELEASE_SOURCE_MODE=dirty` is a deliberately explicit local snapshot mode for
source-bundle development; it is not publish mode and must never be used to
bypass the exact-tag/clean-tree release boundary.

## Install boundary

The installer stages a version under
`${XDG_DATA_HOME:-$HOME/.local/share}/agentotel`, creates `current` and
`previous` runtime pointers, installs the launcher under
`${XDG_BIN_HOME:-$HOME/.local/bin}/obs`, and writes a SHA-256 manifest. It copies
runtime assets from the source bundle and keeps a version-specific image/tag
selection so rollback does not silently reuse a newer image.

Install a verified bundle by extracting it and running the included installer
from its source root, or use the repository checkout only for explicitly
controlled development. The default installation includes the read-only MCP
binary and requires Docker for that build; pass `--without-mcp` when that
optional adapter is intentionally omitted.

After installation, use:

```bash
obs setup
obs up
obs doctor
obs runtime list
```

`obs runtime rollback` swaps only the validated `current`/`previous` pointers;
it does not delete telemetry volumes. Keep the paired archive/checksum and record
the exact tag, commit, checksum, and install mode in the release record.

## Publish workflow boundary

Pushing the annotated tag starts `.github/workflows/release.yml`. The workflow:

1. checks out the exact tag and validates its annotation and commit ancestry;
2. waits for the newest CI run for that exact commit to succeed;
3. runs release/source/install gates and builds the tested archive/checksum pair;
4. transfers only that tested pair to the publish job;
5. re-resolves the tag and verifies the pair before creating or safely reusing a
   draft release;
6. publishes exactly the archive and checksum assets, refusing mismatched or
   unexpected assets; and
7. computes the stable `latest` policy from strict stable SemVer releases.

A published release is not edited or overwritten. A pre-existing draft is reused
only when its tag, name, notes, and assets are byte/metadata compatible with the
tested pair. A transient failure is retried only after re-reading the remote
state; unknown outcomes fail closed.

## Release incident response

If the tag, archive, checksum, release notes, or remote assets disagree, stop the
publish path. Do not overwrite a published release or replace a checksum by
hand. Preserve the exact workflow logs, tag object/commit, local archive digest,
and remote asset metadata, then resolve the discrepancy with a new correctly
versioned release if needed.

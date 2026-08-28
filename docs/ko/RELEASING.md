# Release

[English](../RELEASING.md) · [한국어](./RELEASING.md)

Release는 immutable source/runtime 경계입니다. Published source bundle은 정확한 annotated tag에서 나와야 하며 설치를 재현하는 데 필요한 documentation을 포함합니다. 설치된 runtime은 self-contained이며 checkout의 root `Makefile`, 일반 `scripts/` 또는 `docs/`에 의존하지 않습니다.

## Version 준비

`VERSION`에는 strict core SemVer 한 줄만 들어갑니다.

```text
MAJOR.MINOR.PATCH
```

Application과 E2E package metadata, lockfile, Gateway/MCP build version, Compose runtime image suffix 및 첫 `CHANGELOG.md` heading은 이 값과 일치해야 합니다. Release task에서 release metadata 변경을 유지하고 branch name에서 version을 추론하지 마세요.

Tagging 전에 repository의 일반 CI/local gate를 실행하고 결과 tree를 검사하세요. Publish workflow가 authoritative하며 정확한 commit에 대한 CI success check, release-version validation, runtime/install check 및 source-bundle verification을 실행합니다.

## Immutable tag 생성

Release tag는 정확히 `vMAJOR.MINOR.PATCH`여야 하고 annotated tag여야 하며 이미 `main`에 있는 commit을 가리켜야 합니다.

```bash
version=$(tr -d '\n' < VERSION)
git status --short
git fetch --no-tags origin main
git show-ref --verify --quiet "refs/remotes/origin/main"
git tag -a "v${version}" -m "AgentOTelStack v${version}" "origin/main"
git push origin "v${version}"
```

Push한 뒤 다른 commit에 retag하지 마세요. Release workflow는 tag object를 검사하고 이를 commit으로 peel하며, freshly fetched `origin/main`의 ancestor인지 확인하고 `VERSION`과 release metadata를 검증합니다.

## Source bundle을 local에서 build 및 검증

`build-release-source.sh`는 정확한 tag와 output directory를 받습니다. Publish mode에서는 checkout HEAD가 tag commit과 같고 tree가 clean이어야 합니다.

```bash
mkdir -p dist
./scripts/build-release-source.sh "v${version}" dist
```

정확히 다음 pair를 씁니다.

```text
AgentOTelStack-v${version}.tar.gz
AgentOTelStack-v${version}.tar.gz.sha256
```

Archive walk는 명시적이고 deterministic합니다. Path를 정렬하고 tar/gzip metadata를 normalize하며 unsafe link와 secret/generated/retired path를 거부하고 required source input을 검사한 뒤 pair를 publish하기 전에 verifier를 실행합니다. Checksum은 basename-only SHA-256 한 줄입니다.

Pair를 독립적으로 검증하세요.

```bash
./scripts/verify-release-source.sh --version "$version" \
  "dist/AgentOTelStack-v${version}.tar.gz" \
  "dist/AgentOTelStack-v${version}.tar.gz.sha256"

# Linux
(cd dist && sha256sum --check "AgentOTelStack-v${version}.tar.gz.sha256")

# macOS
(cd dist && shasum -a 256 -c "AgentOTelStack-v${version}.tar.gz.sha256")
```

`RELEASE_SOURCE_MODE=dirty`는 source-bundle development를 위한 의도적으로 명시적인 local snapshot mode입니다. Publish mode가 아니며 exact-tag/clean-tree release boundary를 우회하는 데 사용해서는 안 됩니다.

## Install 경계

Installer는 `${XDG_DATA_HOME:-$HOME/.local/share}/agentotel` 아래에 version을 stage하고, `current` 및 `previous` runtime pointer를 만들며, `${XDG_BIN_HOME:-$HOME/.local/bin}/obs` 아래에 launcher를 설치하고 SHA-256 manifest를 씁니다. Source bundle에서 runtime asset을 복사하고 version별 image/tag selection을 유지하므로 rollback이 더 새로운 image를 조용히 재사용하지 않습니다.

검증된 bundle을 extract하고 source root에 포함된 installer를 실행해 설치하거나, repository checkout은 명시적으로 통제된 개발에만 사용하세요. 기본 설치에는 read-only MCP binary가 포함되고 해당 build에 Docker가 필요합니다. Optional adapter를 의도적으로 생략할 때는 `--without-mcp`를 전달하세요.

설치 후 다음을 사용하세요.

```bash
obs setup
obs up
obs doctor
obs runtime list
```

`obs runtime rollback`은 검증된 `current`/`previous` pointer만 교체하며 telemetry volume을 삭제하지 않습니다. Paired archive/checksum을 보관하고 정확한 tag, commit, checksum 및 install mode를 release record에 남기세요.

## Publish workflow 경계

Annotated tag를 push하면 `.github/workflows/release.yml`이 시작됩니다. Workflow는 다음을 수행합니다.

1. 정확한 tag를 checkout하고 annotation 및 commit ancestry를 검증합니다.
2. 해당 exact commit에 대한 최신 CI run이 성공할 때까지 기다립니다.
3. Release/source/install gate를 실행하고 검증된 archive/checksum pair를 build합니다.
4. 검증된 pair만 publish job으로 전달합니다.
5. Tag를 다시 해석하고 pair를 검증한 뒤 draft release를 생성하거나 안전하게 재사용합니다.
6. 정확히 archive와 checksum asset만 publish하고 불일치하거나 예상하지 못한 asset을 거부합니다.
7. Strict stable SemVer release에서 안정적인 `latest` policy를 계산합니다.

Published release는 편집하거나 덮어쓰지 않습니다. Pre-existing draft는 tag, name, notes 및 asset이 테스트된 pair와 byte/metadata 수준에서 호환될 때만 재사용합니다. Transient failure는 remote state를 다시 읽은 뒤에만 retry하며 unknown outcome은 fail closed합니다.

## Release incident 대응

Tag, archive, checksum, release note 또는 remote asset이 서로 다르면 publish path를 중지하세요. Published release를 덮어쓰거나 checksum을 손으로 교체하지 마세요. 정확한 workflow log, tag object/commit, local archive digest 및 remote asset metadata를 보존한 뒤 필요하면 정확히 version을 새로 지정한 release로 discrepancy를 해결하세요.

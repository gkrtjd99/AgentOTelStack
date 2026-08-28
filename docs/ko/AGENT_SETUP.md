# Agent 설정

[English](../AGENT_SETUP.md) · [한국어](./AGENT_SETUP.md)

이 문서는 clone-independent runtime의 설치를 다룹니다. Checkout 개발은 [`DEVELOPMENT.md`](./DEVELOPMENT.md), 설정 후 운영은 [`OPERATIONS.md`](./OPERATIONS.md)를 사용하세요.

## 불변 release 설치

Release는 버전이 지정된 source bundle과 짝을 이루는 SHA-256 asset입니다. 동일한 immutable tag의 checksum과 archive를 다운로드하고, 압축을 풀기 전에 archive를 검증한 다음 검증된 tree에서 설치하세요. 현재 release version은 `2.1.0`입니다.

```bash
VERSION=2.1.0
BASE="https://github.com/gkrtjd99/AgentOTelStack/releases/download/v${VERSION}"
curl -fLO "${BASE}/AgentOTelStack-v${VERSION}.tar.gz.sha256"
curl -fLO "${BASE}/AgentOTelStack-v${VERSION}.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum --check "AgentOTelStack-v${VERSION}.tar.gz.sha256"
else
  shasum -a 256 -c "AgentOTelStack-v${VERSION}.tar.gz.sha256"
fi
tar -xzf "AgentOTelStack-v${VERSION}.tar.gz"
cd "AgentOTelStack-v${VERSION}"
make install VERSION="${VERSION}"
```

`sha256sum --check`는 일반적인 Linux command이고, `shasum -a 256 -c`는 이식 가능한 macOS 대안입니다. checksum이 성공하면 다운로드한 archive가 짝을 이루는 checksum asset과 일치한다는 뜻입니다. Release tag와 hosting repository가 provenance 경계로 남습니다. 신뢰할 수 없는 mirror에서 복사한 checksum만으로는 authenticity를 증명할 수 없습니다.

Installer는 선택한 version을 `${XDG_DATA_HOME:-$HOME/.local/share}/agentotel/` 아래에 배치하고, `current` 및 `previous` pointer를 유지하며, global launcher를 `${XDG_BIN_HOME:-$HOME/.local/bin}/obs`에 설치합니다. launcher에 필요한 runtime asset은 복사하지만, checkout의 root `Makefile`, 일반 `scripts/` 또는 설치된 운영 dependency로서의 `docs/`는 복사하지 않습니다. 따라서 설치 후 checkout을 이동하거나 삭제할 수 있습니다.

MCP는 기본적으로 설치 중 build되며 Docker가 필요합니다. 읽기 전용 MCP adapter가 의도적으로 필요하지 않을 때만 `make install WITHOUT_MCP=1 VERSION="${VERSION}"`을 사용하세요. 존재하는 경우 설치된 binary는 `${XDG_DATA_HOME:-$HOME/.local/share}/agentotel/current/bin/agentotel-mcp`입니다.

## 최초 설정

어느 directory에서든 global launcher를 실행하세요.

```bash
obs setup
obs up
obs doctor
```

`obs setup`은 로컬 credential store와 label이 붙은 4개의 active telemetry volume을 생성합니다. Canonical credential file은 `${XDG_CONFIG_HOME:-$HOME/.config}/agentotel/credentials`이며, 정확히 서로 다른 `ingest_token` 및 `query_token` key를 담은 일반 0600 file입니다. Compose에는 child process에서만 이 역할을 전달합니다. 두 token을 source control이나 repository `.env` file에 넣지 마세요.

Stack의 workspace project는 Docker stack identity와 별개입니다. Checkout의 `.agentotel/project.toml`에는 로컬 UUIDv4 telemetry scope가 들어 있고 Git에서 ignore됩니다. `obs project ensure`가 이를 생성하거나 검증합니다. Checkout을 교체할 때 telemetry identity를 유지해야 한다면 해당 file을 별도로 보존하세요. Stack UUID는 `${XDG_STATE_HOME:-$HOME/.local/state}/agentotel/stack.uuid`에 저장되어 volume label을 제어하며, `AGENTOTEL_PROJECT_ID`로 대체되지 않습니다.

Core runtime이 올라온 뒤 `obs run --service NAME -- COMMAND`로 app을 연결하거나 [`CONNECT.md`](./CONNECT.md)를 참조하세요. Bundled sample app은 기본 runtime에서 꺼져 있으며, checkout demo에는 [`DEVELOPMENT.md`](./DEVELOPMENT.md)에 설명된 명시적인 source path를 사용합니다.

## MCP 범위

설치된 MCP adapter는 읽기 전용이며 정확히 세 가지 tool을 노출합니다: `agentotel_context`, `agentotel_correlate`, `agentotel_services`. Workspace에서 해석된 project와 Gateway query credential을 사용합니다. 임의의 project, backend URL, raw query, command 또는 telemetry write를 받지 않습니다. Configuration pointer와 credential store를 비공개로 유지하세요. 최소 stdio 설정은 [`CONNECT.md`](./CONNECT.md), trust boundary는 [`SECURITY.md`](./SECURITY.md)를 참조하세요.

## Source checkout은 다릅니다

Source checkout은 bare `./bin/obs` invocation으로 설치된 runtime을 의도적으로 override하지 않습니다. 명시적인 source prefix를 사용하세요.

```bash
make dev-setup
make demo
# or, for a single source command:
AGENTOTEL_DEV_MODE=1 ./bin/obs setup
AGENTOTEL_DEV_MODE=1 ./bin/obs up
```

Mutable branch archive를 production-style install에 복사하지 마세요. Clone-independent operation에는 검증된 release asset을, 개발에는 명시적인 checkout을 사용하세요.

## 다음 참고 문서

- [`OPERATIONS.md`](./OPERATIONS.md) — lifecycle, storage, credential 및 legacy-volume 처리
- [`QUERY.md`](./QUERY.md) — 인증된 bounded read
- [`SECURITY.md`](./SECURITY.md) — credential, project identity 및 local threat model

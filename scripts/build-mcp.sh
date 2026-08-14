#!/bin/sh
set -eu
ROOT=$(CDPATH=; cd -- "$(dirname -- "$0")/.." && pwd)
version=${VERSION:-$(cat "$ROOT/VERSION")}
out=${1:-}
goos=${2:-$(uname -s)}; goarch=${3:-$(uname -m)}
[ -n "$out" ] || { echo 'usage: build-mcp.sh OUTPUT [GOOS GOARCH]' >&2; exit 2; }
case "$version" in *[!A-Za-z0-9._-]*|'') echo 'invalid MCP build version' >&2; exit 2;; esac
goos=$(printf '%s' "$goos" | tr '[:upper:]' '[:lower:]')
case "$goos" in linux|darwin) :;; *) echo "unsupported MCP host OS: $goos (supported: linux, darwin)" >&2; exit 2;; esac
goarch=$(printf '%s' "$goarch" | tr '[:upper:]' '[:lower:]')
case "$goarch" in arm64|aarch64) goarch=arm64;; amd64|x86_64) goarch=amd64;; *) echo "unsupported MCP host architecture: $goarch (supported: arm64, amd64)" >&2; exit 2;; esac
command -v docker >/dev/null 2>&1 || { echo 'MCP build requires Docker (use --without-mcp to install without MCP)' >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
docker run --rm -v "$ROOT/src/mcp:/src:ro" -v "$tmp:/out" -w /src golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36 sh -c "CGO_ENABLED=0 GOOS=$goos GOARCH=$goarch go build -trimpath -ldflags '-X main.buildVersion=$version' -o /out/agentotel-mcp ." >/dev/null
[ -s "$tmp/agentotel-mcp" ] || { echo 'MCP build produced no executable' >&2; exit 1; }
if command -v file >/dev/null 2>&1; then
  desc=$(file -b "$tmp/agentotel-mcp")
  case "$goos/$goarch" in
    linux/amd64) case "$desc" in *"ELF 64-bit"*x86-64*) :;; *) echo "MCP build has unexpected file type: $desc" >&2; exit 1;; esac;;
    linux/arm64) case "$desc" in *"ELF 64-bit"*"ARM aarch64"*) :;; *) echo "MCP build has unexpected file type: $desc" >&2; exit 1;; esac;;
    darwin/amd64) case "$desc" in *"Mach-O 64-bit"*x86_64*) :;; *) echo "MCP build has unexpected file type: $desc" >&2; exit 1;; esac;;
    darwin/arm64) case "$desc" in *"Mach-O 64-bit"*arm64*) :;; *) echo "MCP build has unexpected file type: $desc" >&2; exit 1;; esac;;
  esac
fi
mkdir -p "$(dirname -- "$out")"
cp "$tmp/agentotel-mcp" "$out"; chmod 700 "$out"
shasum -a 256 "$out" >/dev/null

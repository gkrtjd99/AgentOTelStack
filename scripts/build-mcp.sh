#!/bin/sh
set -eu
ROOT=$(CDPATH=; cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-}
goos=${2:-$(uname -s)}; goarch=${3:-$(uname -m)}
[ -n "$out" ] || { echo 'usage: build-mcp.sh OUTPUT [GOOS GOARCH]' >&2; exit 2; }
goos=$(printf '%s' "$goos" | tr '[:upper:]' '[:lower:]')
case "$goos" in linux|darwin) :;; *) echo "unsupported MCP host OS: $goos (supported: linux, darwin)" >&2; exit 2;; esac
goarch=$(printf '%s' "$goarch" | tr '[:upper:]' '[:lower:]')
case "$goarch" in arm64|aarch64) goarch=arm64;; amd64|x86_64) goarch=amd64;; *) echo "unsupported MCP host architecture: $goarch (supported: arm64, amd64)" >&2; exit 2;; esac
command -v docker >/dev/null 2>&1 || { echo 'MCP build requires Docker (use --without-mcp to install without MCP)' >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
docker run --rm -v "$ROOT/mcp:/src:ro" -v "$tmp:/out" -w /src golang:1.26.5-bookworm@sha256:53eeac89074db483fdf0ab3be1df32bf6e47562263d2d0d6baa7f26acb4957dd sh -c "CGO_ENABLED=0 GOOS=$goos GOARCH=$goarch go build -trimpath -o /out/agentotel-mcp ." >/dev/null
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

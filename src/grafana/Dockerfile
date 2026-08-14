# syntax=docker/dockerfile:1.7

# The official Grafana image is an asset source only.  Its server binary,
# bundled plugins, and upstream entrypoint are not copied into the result.

# Grafana v13.1.3, commit 45a27d64b64a82d666b06aa5c5bb3521587edb0d.
FROM grafana/grafana@sha256:ab5cb380e3ff3172d6c8bd2e7cfd31cce977d2881b260e1f5bc089bf0b759b43 AS grafana-assets

# Go 1.26.6 is pinned by digest.  BUILDPLATFORM keeps the compiler native;
# TARGETOS/TARGETARCH/TARGETVARIANT select only the output architecture.
FROM --platform=$BUILDPLATFORM golang:1.26.6-alpine@sha256:af8d6740070b8906d12eae1c3e3ea0957fb63f492051ea05e354c38ef9fe88df AS grafana-builder

ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT

WORKDIR /src

# This tiny standard-library-only tool rewrites parsed ImportSpec paths and
# cannot touch arbitrary quoted strings in the downloaded source.
COPY tempo-import-rewrite.go /tmp/tempo-import-rewrite.go

# Use the Go module tooling itself to create local proxy archives.  A generic
# zip command does not apply module-zip rules (notably nested modules, vendor
# trees, symlinks, or the canonical module@version prefix).
COPY module-proxy-zip.go /tmp/module-proxy-zip.go

# Grafana source archive for the exact commit above.  The checksum is the
# provenance boundary for the server build.
ADD https://github.com/grafana/grafana/archive/45a27d64b64a82d666b06aa5c5bb3521587edb0d.tar.gz /tmp/grafana.tar.gz

RUN set -eux; \
    printf '%s  %s\n' \
      'ef2a9c6da7d6c3ffcd910d5aeb1d00f32f9a36ea49035145ae5bbf902f39567d' \
      /tmp/grafana.tar.gz | sha256sum -c -; \
    tar -xzf /tmp/grafana.tar.gz --strip-components=1 -C /src; \
    rm -f /tmp/grafana.tar.gz; \
    apk add --no-cache \
      bash=5.3.9-r1 \
      git=2.54.0-r0 \
      grep=3.12-r0 \
      make=4.4.1-r4

# Tempo v2.10.3 predates the /v2 module-path convention: its signed release
# tag still declares github.com/grafana/tempo.  Keep the reviewed release
# source and checksum, then expose that source through a local module-proxy
# record with the semver-correct path.  This avoids a Go module replacement and
# makes the resulting binary carry github.com/grafana/tempo/v2 v2.10.3.
ADD https://github.com/grafana/tempo/archive/4aeafc237b8d9a8d62e45735131e8a89eb741a00.tar.gz /tmp/tempo.tar.gz

RUN set -eux; \
    printf '%s  %s\n' \
      '6159f130af77216215137a1033e3f573cc83e7aba69a19d618b521b7ab41d81f' \
      /tmp/tempo.tar.gz | sha256sum -c -; \
    go build -trimpath -o /tmp/tempo-import-rewrite /tmp/tempo-import-rewrite.go; \
    mkdir -p /opt/tempo-v2; \
    tar -xzf /tmp/tempo.tar.gz --strip-components=1 -C /opt/tempo-v2; \
    rm -f /tmp/tempo.tar.gz; \
    sed -i 's#^module github.com/grafana/tempo$#module github.com/grafana/tempo/v2#' /opt/tempo-v2/go.mod; \
    /tmp/tempo-import-rewrite \
      --old-prefix github.com/grafana/tempo \
      --new-prefix github.com/grafana/tempo/v2 \
      --expected-files 613 \
      --expected-imports 2233 \
      --input /opt/tempo-v2; \
    grep -Fq 'statsPrefix   = "github.com/grafana/tempo/"' \
      /opt/tempo-v2/pkg/usagestats/stats.go; \
    # Grafana's Tempo adapter is deliberately an explicit allowlist.  The
    # AST tool rewrites only ImportSpec paths in these files.
    printf '%s\n' \
      pkg/extensions/enterprise_imports.go \
      pkg/tsdb/tempo/tempo.go \
      pkg/tsdb/tempo/grpc.go \
      pkg/tsdb/tempo/trace.go \
      pkg/tsdb/tempo/search.go \
      pkg/tsdb/tempo/search_stream.go \
      pkg/tsdb/tempo/metrics_stream.go \
      pkg/tsdb/tempo/trace_transform.go \
      pkg/tsdb/tempo/traceql_query.go \
      pkg/tsdb/tempo/traceql/exemplars.go \
      pkg/tsdb/tempo/traceql/metrics.go \
      pkg/tsdb/tempo/search_stream_test.go \
      pkg/tsdb/tempo/search_test.go \
      pkg/tsdb/tempo/trace_transform_test.go \
      pkg/tsdb/tempo/traceql/exemplars_test.go \
      pkg/tsdb/tempo/traceql/metrics_test.go \
      > /tmp/grafana-tempo-files; \
    while IFS= read -r grafana_file; do test -f "/src/$grafana_file"; done \
      < /tmp/grafana-tempo-files; \
    /tmp/tempo-import-rewrite \
      --old-prefix github.com/grafana/tempo \
      --new-prefix github.com/grafana/tempo/v2 \
      --expected-files 16 \
      --expected-imports 26 \
      --file-list /tmp/grafana-tempo-files; \
    test "$(grep -Fc 'statsPrefix   = "github.com/grafana/tempo/"' \
      /opt/tempo-v2/pkg/usagestats/stats.go)" = 1; \
    # Grafana keeps its first-party app packages as local modules.  Publish
    # those exact checked sources into the build-only proxy at v0.0.0 so the
    # binary records module identities instead of local devel replacements.
    # Every archive is made with the canonical Go module-zip writer below.
    internal_modules='apps/advisor apps/alerting/alertenrichment apps/alerting/historian apps/alerting/notifications apps/alerting/rules apps/annotation apps/collections apps/correlations apps/dashboard apps/dashvalidator apps/example apps/folder apps/iam apps/live apps/logsdrilldown apps/playlist apps/plugins apps/preferences apps/provisioning apps/quotas apps/scope apps/secret apps/shorturl pkg/aggregator pkg/apimachinery pkg/apiserver pkg/infra/features pkg/plugins pkg/storage/unified/resource/kv pkg/storage/unified/resourcepb pkg/util/sqlite'; \
    sed -i '/^\/\/ Replace references to internal workspaces$/,/^)$/d' go.mod; \
    mkdir -p /tmp/module-proxy-zip-build; \
    cp /tmp/module-proxy-zip.go /tmp/module-proxy-zip-build/main.go; \
    printf '%s\n' \
      'module agentotel/module-proxy-zip' \
      'go 1.26.0' \
      '' \
      'require golang.org/x/mod v0.40.0' \
      > /tmp/module-proxy-zip-build/go.mod; \
    (cd /tmp/module-proxy-zip-build && \
      GOMODCACHE=/tmp/module-proxy-zip-gomodcache \
      GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org \
      go mod download golang.org/x/mod@v0.40.0 && \
      GOMODCACHE=/tmp/module-proxy-zip-gomodcache \
      GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org \
      go build -trimpath -o /tmp/module-proxy-zip .); \
    mkdir -p /opt/grafana-proxy /opt/grafana-proxy-tree; \
    create_module_zip() { \
      module_path="$1"; \
      module_version="$2"; \
      module_dir="$3"; \
      module_zip="$4"; \
      first_zip="$module_zip.selfcheck-a"; \
      second_zip="$module_zip.selfcheck-b"; \
      /tmp/module-proxy-zip \
        --module "$module_path" \
        --version "$module_version" \
        --dir "$module_dir" \
        --output "$first_zip"; \
      /tmp/module-proxy-zip \
        --module "$module_path" \
        --version "$module_version" \
        --dir "$module_dir" \
        --output "$second_zip"; \
      cmp -s "$first_zip" "$second_zip"; \
      first_sha256="$(sha256sum "$first_zip" | cut -d' ' -f1)"; \
      second_sha256="$(sha256sum "$second_zip" | cut -d' ' -f1)"; \
      test "$first_sha256" = "$second_sha256"; \
      printf 'canonical module zip %s@%s sha256=%s\n' \
        "$module_path" "$module_version" "$first_sha256"; \
      mv "$first_zip" "$module_zip"; \
      rm -f "$second_zip"; \
    }; \
    for internal_module in $internal_modules; do \
      internal_path="github.com/grafana/grafana/$internal_module"; \
      internal_source="/src/$internal_module"; \
      test -f "$internal_source/go.mod"; \
      internal_target="/opt/grafana-proxy-tree/${internal_path}@v0.0.0"; \
      mkdir -p "$internal_target"; \
      cp -a "$internal_source/." "$internal_target/"; \
      for internal_dependency in $internal_modules; do \
        sed -i "s#^\\([[:space:]]*github.com/grafana/grafana/$internal_dependency\\)[[:space:]][^[:space:]]*#\\1 v0.0.0#" \
          "$internal_target/go.mod"; \
      done; \
      mkdir -p "/opt/grafana-proxy/$internal_path/@v"; \
      create_module_zip \
        "$internal_path" \
        v0.0.0 \
        "$internal_target" \
        "/opt/grafana-proxy/$internal_path/@v/v0.0.0.zip"; \
      printf '%s\n' \
        '{"Version":"v0.0.0","Time":"2026-08-07T00:43:24Z"}' \
        > "/opt/grafana-proxy/$internal_path/@v/v0.0.0.info"; \
      cp "$internal_target/go.mod" \
        "/opt/grafana-proxy/$internal_path/@v/v0.0.0.mod"; \
    done; \
    # Grafana 13.1.3 resolves x/mod indirectly.  v0.40.0 is the current
    # compatible release; the native build below is the compatibility gate.
    go mod edit -require=golang.org/x/mod@v0.40.0; \
    go mod edit -droprequire=github.com/grafana/tempo; \
    go mod edit -require=github.com/grafana/tempo/v2@v2.10.3; \
    sed -i '/^github.com\/grafana\/tempo /d' go.sum; \
    mkdir -p \
      /opt/tempo-proxy/github.com/grafana/tempo/v2/@v \
      /opt/tempo-proxy-tree/github.com/grafana/tempo/v2@v2.10.3; \
    cp -a /opt/tempo-v2/. /opt/tempo-proxy-tree/github.com/grafana/tempo/v2@v2.10.3/; \
    create_module_zip \
      github.com/grafana/tempo/v2 \
      v2.10.3 \
      /opt/tempo-proxy-tree/github.com/grafana/tempo/v2@v2.10.3 \
      /opt/tempo-proxy/github.com/grafana/tempo/v2/@v/v2.10.3.zip; \
    printf '%s\n' \
      '{"Version":"v2.10.3","Time":"2026-03-17T17:26:44Z"}' \
      > /opt/tempo-proxy/github.com/grafana/tempo/v2/@v/v2.10.3.info; \
    cp /opt/tempo-v2/go.mod \
      /opt/tempo-proxy/github.com/grafana/tempo/v2/@v/v2.10.3.mod; \
    sha256sum /opt/tempo-proxy/github.com/grafana/tempo/v2/@v/v2.10.3.zip \
      > /opt/tempo-proxy/tempo-v2.10.3.zip.sha256

# The legacy Tempo tag is checked against the pinned source archive above.  A
# scoped proxy entry supplies the valid /v2 semver identity; public modules
# continue to use the Go checksum database.  The adapted Grafana/Tempo source
# modules are excluded only from the public lookup because they are not
# published under these module paths; their source archives and proxy zips are
# generated from the checked source and verified locally.  The adapted Tempo
# proxy h1 values below are captured from this deterministic source transform;
# all public module h1 values are checked against sum.golang.org before use.
# Keep this verification run off BuildKit's persistent module cache: a legacy
# cached zip must never be able to satisfy the check before the local proxy is
# read into a fresh GOMODCACHE.
RUN set -eux; \
    export GOMODCACHE=/tmp/grafana-gomodcache GOCACHE=/tmp/grafana-gocache; \
    mkdir -p "$GOMODCACHE" "$GOCACHE"; \
    tempo_proxy='file:///opt/grafana-proxy,file:///opt/tempo-proxy,https://proxy.golang.org'; \
    synthetic_modules='github.com/grafana/grafana/*,github.com/grafana/tempo/v2'; \
    govuln_sum='h1:4MQBuhmXbz2uepNJrf3v+aaZLGDqw1JluwYboegA1qg='; \
    govuln_mod_sum='h1:Xw7zvU3e1bsCYYBXu+w4wcn2Kgn27f34WBCTw8LL5Us='; \
    xmod_sum='h1:hUv+3cXcdRHz08UmSiOob7sadHig73uo5bkXxQ/tvUs='; \
    xmod_mod_sum='h1:0/weTWkPWGBikyTWAX3dkjVztMmBA5hM0DH6BElSupE='; \
    tempo_sum='h1:uqrOf/EApSKMPRimRjSOwRejj7GfNTSZrUz30WH4ch0='; \
    tempo_mod_sum='h1:jz5yzhgEasfDkKu0qJFuW5r/DKUaenldMA6V4Cr8dEM='; \
    govuln_json="$(GOWORK=off GOPROXY="$tempo_proxy" GOSUMDB=sum.golang.org \
      go mod download -json golang.org/x/vuln@v1.7.0)"; \
    printf '%s\n' "$govuln_json" | grep -Fq "\"Sum\": \"$govuln_sum\""; \
    printf '%s\n' "$govuln_json" | grep -Fq "\"GoModSum\": \"$govuln_mod_sum\""; \
    xmod_json="$(GOWORK=off GOPROXY="$tempo_proxy" GOSUMDB=sum.golang.org \
      go mod download -json golang.org/x/mod@v0.40.0)"; \
    printf '%s\n' "$xmod_json" | grep -Fq "\"Sum\": \"$xmod_sum\""; \
    printf '%s\n' "$xmod_json" | grep -Fq "\"GoModSum\": \"$xmod_mod_sum\""; \
    grep -Fqx 'module github.com/grafana/tempo/v2' \
      /opt/tempo-proxy/github.com/grafana/tempo/v2/@v/v2.10.3.mod; \
    tempo_json="$(GOWORK=off GOPROXY="$tempo_proxy" GOSUMDB=sum.golang.org \
      GONOSUMDB="$synthetic_modules" \
      go mod download -json github.com/grafana/tempo/v2@v2.10.3)"; \
    printf '%s\n' "$tempo_json" | grep -Fq "\"Sum\": \"$tempo_sum\""; \
    printf '%s\n' "$tempo_json" | grep -Fq "\"GoModSum\": \"$tempo_mod_sum\""; \
    GOWORK=off GOPROXY="$tempo_proxy" GOSUMDB=sum.golang.org \
      GONOSUMDB="$synthetic_modules" go mod download; \
    internal_modules='apps/advisor apps/alerting/alertenrichment apps/alerting/historian apps/alerting/notifications apps/alerting/rules apps/annotation apps/collections apps/correlations apps/dashboard apps/dashvalidator apps/example apps/folder apps/iam apps/live apps/logsdrilldown apps/playlist apps/plugins apps/preferences apps/provisioning apps/quotas apps/scope apps/secret apps/shorturl pkg/aggregator pkg/apimachinery pkg/apiserver pkg/infra/features pkg/plugins pkg/storage/unified/resource/kv pkg/storage/unified/resourcepb pkg/util/sqlite'; \
    for internal_module in $internal_modules; do \
      GOWORK=off GOPROXY="$tempo_proxy" GOSUMDB=sum.golang.org \
        GONOSUMDB="$synthetic_modules" \
        go mod download "github.com/grafana/grafana/$internal_module@v0.0.0"; \
    done; \
    GOWORK=off GOPROXY="$tempo_proxy" GOSUMDB=sum.golang.org GONOSUMDB="$synthetic_modules" go mod download all; \
    GOWORK=off GOPROXY="$tempo_proxy" GOSUMDB=sum.golang.org GONOSUMDB="$synthetic_modules" go mod verify; \
    GOWORK=off GOPROXY="$tempo_proxy" GOSUMDB=sum.golang.org GONOSUMDB="$synthetic_modules" \
      go run golang.org/x/vuln/cmd/govulncheck@v1.7.0 -scan=module

RUN --mount=type=cache,target=/go/pkg/mod,id=agentotel-grafana-mod-v2.1.0 \
    --mount=type=cache,target=/root/.cache/go-build,id=agentotel-grafana-build-v2.1.0 \
    set -eux; \
    targetos="${TARGETOS:-$(go env GOOS)}"; \
    targetarch="${TARGETARCH:-$(go env GOARCH)}"; \
    targetvariant="${TARGETVARIANT:-}"; \
    test "$targetos" = linux; \
    case "$targetarch" in amd64|arm64) ;; *) echo "unsupported Grafana target: $targetarch" >&2; exit 1 ;; esac; \
    tempo_proxy='file:///opt/grafana-proxy,file:///opt/tempo-proxy,https://proxy.golang.org'; \
    synthetic_modules='github.com/grafana/grafana/*,github.com/grafana/tempo/v2'; \
    if [ "$targetarch" = arm64 ] && [ -n "$targetvariant" ]; then \
      case "$targetvariant" in \
        v8) targetvariant=v8.0 ;; \
        v8.*|v9.*) ;; \
        *) echo "unsupported arm64 variant: $targetvariant" >&2; exit 1 ;; \
      esac; \
      GOWORK=off GOPROXY="$tempo_proxy" GOSUMDB=sum.golang.org GONOSUMDB="$synthetic_modules" \
        GOOS="$targetos" GOARCH="$targetarch" GOARM64="$targetvariant" \
        CGO_ENABLED=0 make build-go GO_BUILD_TAGS=oss WIRE_TAGS=oss \
          COMMIT_SHA=45a27d64b64a82d666b06aa5c5bb3521587edb0d \
          BUILD_BRANCH=main SOURCE_DATE_EPOCH=1786031004; \
    else \
      GOWORK=off GOPROXY="$tempo_proxy" GOSUMDB=sum.golang.org GONOSUMDB="$synthetic_modules" \
        GOOS="$targetos" GOARCH="$targetarch" CGO_ENABLED=0 \
        make build-go GO_BUILD_TAGS=oss WIRE_TAGS=oss \
          COMMIT_SHA=45a27d64b64a82d666b06aa5c5bb3521587edb0d \
          BUILD_BRANCH=main SOURCE_DATE_EPOCH=1786031004; \
    fi; \
    mkdir -p /out; \
    cp "bin/$targetos/$targetarch/grafana" /out/grafana; \
    chmod 0555 /out/grafana; \
    go version -m /out/grafana | grep -Eq \
      '^[[:space:]]+dep[[:space:]]+github.com/grafana/tempo/v2[[:space:]]+v2\.10\.3([[:space:]]|$)'; \
    ! go version -m /out/grafana | grep -Fq '/opt/tempo-v2'; \
    go version -m /out/grafana

FROM --platform=$BUILDPLATFORM golang:1.26.6-alpine@sha256:af8d6740070b8906d12eae1c3e3ea0957fb63f492051ea05e354c38ef9fe88df AS victorialogs-builder

ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT

WORKDIR /src

# VictoriaLogs datasource v0.31.0 source at commit bb1f6d7b... .  The archive
# remains a checked source/release evidence boundary.  The backend itself is
# installed from the Go proxy at v0.31.0 so its build metadata is versioned.
ADD https://github.com/VictoriaMetrics/victorialogs-datasource/archive/bb1f6d7b0ec2bdf943c2d8c27f2cb17004b147e8.tar.gz /tmp/victorialogs-source.tar.gz

RUN set -eux; \
    printf '%s  %s\n' \
      'e748a9aa2f737952b7f02b0e69b671d1608c7ef765413cf1476a247e681a0245' \
      /tmp/victorialogs-source.tar.gz | sha256sum -c -; \
    tar -xzf /tmp/victorialogs-source.tar.gz --strip-components=1 -C /src; \
    rm -f /tmp/victorialogs-source.tar.gz; \
    apk add --no-cache ca-certificates=20260611-r0

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eux; \
    govuln_sum='h1:4MQBuhmXbz2uepNJrf3v+aaZLGDqw1JluwYboegA1qg='; \
    govuln_mod_sum='h1:Xw7zvU3e1bsCYYBXu+w4wcn2Kgn27f34WBCTw8LL5Us='; \
    govuln_json="$(GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org \
      go mod download -json golang.org/x/vuln@v1.7.0)"; \
    printf '%s\n' "$govuln_json" | grep -Fq "\"Sum\": \"$govuln_sum\""; \
    printf '%s\n' "$govuln_json" | grep -Fq "\"GoModSum\": \"$govuln_mod_sum\""; \
    GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org go mod download all; \
    GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org go mod verify; \
    GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org \
      go run golang.org/x/vuln/cmd/govulncheck@v1.7.0 ./pkg/...; \
    mkdir -p /tmp/victorialogs-build; \
    printf '%s\n' \
      'module agentotel/victorialogs-build' \
      'go 1.26.0' \
      > /tmp/victorialogs-build/go.mod; \
    victoria_sum='h1:/x8qZKXCHWtNPPvdUwW5cwT4v4QPSFyVj/oHMndTu8w='; \
    victoria_mod_sum='h1:2qIrpT3JSHqEKDElxm8rlbBX+DiwUBgV65zt1BeNBHw='; \
    victoria_json="$(cd /tmp/victorialogs-build && \
      GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org \
      go mod download -json github.com/VictoriaMetrics/victorialogs-datasource@v0.31.0)"; \
    printf '%s\n' "$victoria_json" | grep -Fq "\"Sum\": \"$victoria_sum\""; \
    printf '%s\n' "$victoria_json" | grep -Fq "\"GoModSum\": \"$victoria_mod_sum\""; \
    (cd /tmp/victorialogs-build && \
      GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org \
      go get github.com/VictoriaMetrics/victorialogs-datasource/pkg@v0.31.0); \
    targetos="${TARGETOS:-$(go env GOOS)}"; \
    targetarch="${TARGETARCH:-$(go env GOARCH)}"; \
    targetvariant="${TARGETVARIANT:-}"; \
    test "$targetos" = linux; \
    case "$targetarch" in amd64|arm64) ;; *) echo "unsupported VictoriaLogs target: $targetarch" >&2; exit 1 ;; esac; \
    if [ "$targetarch" = arm64 ] && [ -n "$targetvariant" ]; then \
      case "$targetvariant" in \
        v8) targetvariant=v8.0 ;; \
        v8.*|v9.*) ;; \
        *) echo "unsupported arm64 variant: $targetvariant" >&2; exit 1 ;; \
      esac; \
      (cd /tmp/victorialogs-build && \
        GOOS="$targetos" GOARCH="$targetarch" GOARM64="$targetvariant" CGO_ENABLED=0 \
        GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org \
        go build -trimpath -buildvcs=false -ldflags='-s -w' \
        -o /out/victoriametrics_logs_backend_plugin \
        github.com/VictoriaMetrics/victorialogs-datasource/pkg); \
    else \
      (cd /tmp/victorialogs-build && \
        GOOS="$targetos" GOARCH="$targetarch" CGO_ENABLED=0 \
        GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org \
        go build -trimpath -buildvcs=false -ldflags='-s -w' \
        -o /out/victoriametrics_logs_backend_plugin \
        github.com/VictoriaMetrics/victorialogs-datasource/pkg); \
    fi; \
    chmod 0555 /out/victoriametrics_logs_backend_plugin; \
    go version -m /out/victoriametrics_logs_backend_plugin | grep -Eq \
      '^[[:space:]]+mod[[:space:]]+github.com/VictoriaMetrics/victorialogs-datasource[[:space:]]+v0\.31\.0([[:space:]]|$)'; \
    go version -m /out/victoriametrics_logs_backend_plugin

# Verified release frontend/static assets only.  The release backend files are
# explicitly excluded; the backend in the final image comes from the module
# proxy build above.
FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS victorialogs-assets

ADD https://github.com/VictoriaMetrics/victorialogs-datasource/releases/download/v0.31.0/victoriametrics-logs-datasource-v0.31.0.tar.gz /tmp/victorialogs-release.tar.gz

RUN set -eux; \
    printf '%s  %s\n' \
      '6b6d7b27354ad972946318aac2a54f04363375e7cd5d1cad9d3bb74d00eb970b' \
      /tmp/victorialogs-release.tar.gz | sha256sum -c -; \
    mkdir -p /tmp/victorialogs-release; \
    tar -xzf /tmp/victorialogs-release.tar.gz \
      --strip-components=2 \
      -C /tmp/victorialogs-release; \
    mkdir -p /out/victoriametrics-logs-datasource; \
    cp /tmp/victorialogs-release/plugin.json \
      /tmp/victorialogs-release/module.js \
      /tmp/victorialogs-release/module.js.map \
      /tmp/victorialogs-release/LICENSE \
      /tmp/victorialogs-release/LICENSE.txt \
      /tmp/victorialogs-release/README.md \
      /tmp/victorialogs-release/CHANGELOG.md \
      /out/victoriametrics-logs-datasource/; \
    cp -R /tmp/victorialogs-release/img /out/victoriametrics-logs-datasource/img; \
    rm -f /tmp/victorialogs-release.tar.gz; \
    rm -f /out/victoriametrics-logs-datasource/MANIFEST.txt \
      /out/victoriametrics-logs-datasource/go_plugin_build_manifest; \
    test -f /out/victoriametrics-logs-datasource/plugin.json; \
    test -f /out/victoriametrics-logs-datasource/module.js; \
    test ! -e /out/victoriametrics-logs-datasource/victoriametrics_logs_backend_plugin_linux_amd64; \
    test ! -e /out/victoriametrics-logs-datasource/victoriametrics_logs_backend_plugin_linux_arm64

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS runtime

ARG TARGETARCH

# The existing base.name/digest labels identify the pinned Grafana asset
# image.  The com.agentotel.runtime.* labels identify the actual Alpine
# runtime and all source/toolchain provenance carried by this repack.
LABEL org.opencontainers.image.source="https://github.com/grafana/grafana" \
      org.opencontainers.image.version="13.1.3" \
      org.opencontainers.image.revision="45a27d64b64a82d666b06aa5c5bb3521587edb0d" \
      org.opencontainers.image.base.name="grafana/grafana" \
      org.opencontainers.image.base.digest="sha256:ab5cb380e3ff3172d6c8bd2e7cfd31cce977d2881b260e1f5bc089bf0b759b43" \
      org.opencontainers.image.licenses="AGPL-3.0-only AND Apache-2.0" \
      com.agentotel.runtime.base.name="alpine" \
      com.agentotel.runtime.base.version="3.24.1" \
      com.agentotel.runtime.base.digest="sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b" \
      com.agentotel.golang.version="1.26.6" \
      com.agentotel.golang.image="golang:1.26.6-alpine@sha256:af8d6740070b8906d12eae1c3e3ea0957fb63f492051ea05e354c38ef9fe88df" \
      com.agentotel.grafana.source.commit="45a27d64b64a82d666b06aa5c5bb3521587edb0d" \
      com.agentotel.grafana.source.sha256="ef2a9c6da7d6c3ffcd910d5aeb1d00f32f9a36ea49035145ae5bbf902f39567d" \
      com.agentotel.tempo.version="v2.10.3" \
      com.agentotel.tempo.commit="4aeafc237b8d9a8d62e45735131e8a89eb741a00" \
      com.agentotel.tempo.source.sha256="6159f130af77216215137a1033e3f573cc83e7aba69a19d618b521b7ab41d81f" \
      com.agentotel.victorialogs.version="v0.31.0" \
      com.agentotel.victorialogs.commit="bb1f6d7b0ec2bdf943c2d8c27f2cb17004b147e8" \
      com.agentotel.victorialogs.source.sha256="e748a9aa2f737952b7f02b0e69b671d1608c7ef765413cf1476a247e681a0245" \
      com.agentotel.victorialogs.release.sha256="6b6d7b27354ad972946318aac2a54f04363375e7cd5d1cad9d3bb74d00eb970b"

ENV PATH="/usr/share/grafana/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    GF_PATHS_CONFIG="/etc/grafana/grafana.ini" \
    GF_PATHS_DATA="/var/lib/grafana" \
    GF_PATHS_HOME="/usr/share/grafana" \
    GF_PATHS_LOGS="/var/log/grafana" \
    GF_PATHS_PLUGINS="/opt/grafana-plugins" \
    GF_PATHS_PROVISIONING="/etc/grafana/provisioning" \
    GF_PLUGINS_PREINSTALL_DISABLED="true" \
    GF_PLUGINS_PLUGIN_ADMIN_ENABLED="false" \
    GF_PLUGINS_PUBLIC_KEY_RETRIEVAL_DISABLED="true" \
    GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS="victoriametrics-logs-datasource" \
    GF_ANALYTICS_CHECK_FOR_UPDATES="false" \
    GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES="false"

WORKDIR /usr/share/grafana

# Only the certificates and timezone database are needed at runtime.  Busybox
# supplies the shell, env, find, and wget used by the owned entrypoint/probe.
RUN apk add --no-cache \
      ca-certificates=20260611-r0 \
      tzdata=2026c-r0 \
    && adduser -S -u 472 -G root grafana \
    && mkdir -p \
      /etc/grafana \
      /var/lib/grafana \
      /var/log/grafana \
      /opt/grafana-plugins \
      /etc/grafana/provisioning/datasources \
      /etc/grafana/provisioning/dashboards \
      /etc/grafana/provisioning/notifiers \
      /etc/grafana/provisioning/plugins \
      /etc/grafana/provisioning/access-control \
      /etc/grafana/provisioning/alerting \
      /usr/share/grafana/.aws \
    && chown -R 472:0 \
      /etc/grafana \
      /var/lib/grafana \
      /var/log/grafana \
      /opt/grafana-plugins \
      /etc/grafana/provisioning \
      /usr/share/grafana/.aws \
    && chmod 0750 /etc/grafana /opt/grafana-plugins \
    && chmod 0700 /usr/share/grafana/.aws

# Copy only exact official frontend/config/license assets.  No official
# /usr/share/grafana/bin, data, or bundled plugin path is copied.
COPY --from=grafana-assets /usr/share/grafana/conf /usr/share/grafana/conf
COPY --from=grafana-assets /usr/share/grafana/public /usr/share/grafana/public
COPY --from=grafana-assets /usr/share/grafana/LICENSE /usr/share/grafana/licenses/grafana/LICENSE
COPY run.sh /run.sh
COPY NOTICE /usr/share/grafana/NOTICE
COPY --from=grafana-builder /out/grafana /usr/share/grafana/bin/grafana
COPY --from=grafana-builder /opt/tempo-v2/LICENSE /usr/share/grafana/licenses/tempo/LICENSE
COPY --from=grafana-builder /opt/tempo-v2/LICENSING.md /usr/share/grafana/licenses/tempo/LICENSING.md
COPY --from=grafana-builder /opt/tempo-v2/pkg/tempopb/LICENSE_APACHE2 /usr/share/grafana/licenses/tempo/pkg/tempopb/LICENSE_APACHE2
COPY --from=victorialogs-builder /src/LICENSE /usr/share/grafana/licenses/victorialogs/LICENSE
COPY --from=victorialogs-assets /out/victoriametrics-logs-datasource/LICENSE /usr/share/grafana/licenses/victorialogs-datasource/LICENSE
COPY --from=victorialogs-assets /out/victoriametrics-logs-datasource/LICENSE.txt /usr/share/grafana/licenses/victorialogs-datasource/LICENSE.txt

# Replace the upstream sample with a locked-down local configuration.  Runtime
# credentials may still be provided through the normal Grafana environment.
RUN printf '%s\n' \
      '[feature_toggles]' \
      'externalCorePlugins = false' \
      '[plugins]' \
      'plugin_admin_enabled = false' \
      'plugin_catalog_url =' \
      'public_key_retrieval_disabled = true' \
      'public_key_retrieval_on_startup = false' \
      'preinstall =' \
      'preinstall_sync =' \
      'preinstall_disabled = true' \
      'preinstall_auto_update = false' \
      'allow_loading_unsigned_plugins = victoriametrics-logs-datasource' \
      '[analytics]' \
      'check_for_updates = false' \
      'check_for_plugin_updates = false' \
      '[auth.anonymous]' \
      'enabled = false' \
      '[users]' \
      'allow_sign_up = false' \
    > "$GF_PATHS_CONFIG" \
    && chown 472:0 "$GF_PATHS_CONFIG" \
    && chmod 0444 "$GF_PATHS_CONFIG" \
    && chmod 0555 /run.sh /usr/share/grafana/bin/grafana

# The datasource frontend comes from the verified v0.31.0 release.  Its Linux
# backend is the module-versioned source build for this target architecture.
COPY --from=victorialogs-assets /out/victoriametrics-logs-datasource /opt/grafana-plugins/victoriametrics-logs-datasource
COPY --from=victorialogs-builder /out/victoriametrics_logs_backend_plugin \
  /opt/grafana-plugins/victoriametrics-logs-datasource/victoriametrics_logs_backend_plugin_linux_amd64

RUN set -eux; \
    case "${TARGETARCH:-}" in \
      amd64) backend_arch=amd64 ;; \
      arm64) \
        mv /opt/grafana-plugins/victoriametrics-logs-datasource/victoriametrics_logs_backend_plugin_linux_amd64 \
          /opt/grafana-plugins/victoriametrics-logs-datasource/victoriametrics_logs_backend_plugin_linux_arm64; \
        backend_arch=arm64 ;; \
      *) echo "unsupported runtime architecture: ${TARGETARCH:-unset}" >&2; exit 1 ;; \
    esac; \
    plugin_dir=/opt/grafana-plugins/victoriametrics-logs-datasource; \
    backend_path="$(find "$plugin_dir" -maxdepth 1 -type f -name "victoriametrics_logs_backend_plugin_linux_${backend_arch}" -print -quit)"; \
    test -n "$backend_path"; \
    test -f "$backend_path"; \
    test -x "$backend_path"; \
    backend_name="$(basename "$backend_path")"; \
    ln -s "$backend_name" "$plugin_dir/victoriametrics_logs_backend_plugin"; \
    chown -R 472:0 /opt/grafana-plugins; \
    find /opt/grafana-plugins -type d -exec chmod 0550 {} +; \
    find /opt/grafana-plugins -type f -exec chmod 0440 {} +; \
    chmod 0550 "$backend_path" "$plugin_dir/victoriametrics_logs_backend_plugin"; \
    test -L "$plugin_dir/victoriametrics_logs_backend_plugin"; \
    test "$(readlink "$plugin_dir/victoriametrics_logs_backend_plugin")" = "$backend_name"

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["/bin/busybox", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:3000/api/health"]

USER 472
ENTRYPOINT ["/run.sh"]

package ui

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"io/fs"
	"mime"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
)

// Files are immutable and compiled into the binary; no runtime filesystem path
// is accepted from a browser request. The bytes and strong validators are
// loaded once at package initialization, not read from the embed filesystem per
// request.
//
//go:embed static/index.html static/assets/*
var files embed.FS

type asset struct {
	data        []byte
	etag        string
	contentType string
}

var embeddedAssets = loadAssets()

func loadAssets() map[string]asset {
	assets := make(map[string]asset, 4)
	for _, name := range []string{"static/index.html", "static/assets/app.js", "static/assets/request-state.js", "static/assets/styles.css"} {
		data, err := fs.ReadFile(files, name)
		if err != nil {
			panic("embedded dashboard asset: " + name + ": " + err.Error())
		}
		hash := sha256.Sum256(data)
		ext := path.Ext(name)
		contentType := mime.TypeByExtension(ext)
		if contentType == "" {
			contentType = "application/octet-stream"
		}
		assets[name] = asset{
			data:        data,
			etag:        `"` + hex.EncodeToString(hash[:]) + `"`,
			contentType: contentType,
		}
	}
	return assets
}

func Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, http.StatusText(http.StatusMethodNotAllowed), http.StatusMethodNotAllowed)
			return
		}
		name, ok := assetName(r.URL.Path)
		if !ok {
			http.NotFound(w, r)
			return
		}
		asset, ok := embeddedAssets[name]
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Cache-Control", "public, max-age=0, must-revalidate")
		w.Header().Set("Content-Type", asset.contentType)
		w.Header().Set("Content-Length", strconv.Itoa(len(asset.data)))
		w.Header().Set("ETag", asset.etag)
		if etagMatches(r.Header.Get("If-None-Match"), asset.etag) {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(asset.data)
	})
}

func etagMatches(header, etag string) bool {
	for _, candidate := range strings.Split(header, ",") {
		candidate = strings.TrimSpace(candidate)
		if candidate == "*" || candidate == etag {
			return true
		}
	}
	return false
}

func assetName(requestPath string) (string, bool) {
	decoded, err := url.PathUnescape(requestPath)
	if err != nil {
		return "", false
	}
	requestPath = decoded
	if requestPath == "/" {
		return "static/index.html", true
	}
	if !strings.HasPrefix(requestPath, "/assets/") {
		return "", false
	}
	rel := strings.TrimPrefix(requestPath, "/assets/")
	if rel == "" || strings.Contains(rel, "\\") {
		return "", false
	}
	parts := strings.Split(rel, "/")
	for _, part := range parts {
		if part == "" || part == "." || part == ".." {
			return "", false
		}
	}
	clean := path.Clean(rel)
	if clean != rel || !fs.ValidPath(clean) {
		return "", false
	}
	return "static/assets/" + clean, true
}

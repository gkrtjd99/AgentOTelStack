package ui

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAssetNameRejectsTraversal(t *testing.T) {
	for _, path := range []string{"/assets/../index.html", "/assets/%2e%2e/%2e%2e/secret", "/assets/..", "/assets//app.js", "/other"} {
		if name, ok := assetName(path); ok {
			t.Fatalf("path %q accepted as %q", path, name)
		}
	}
	if name, ok := assetName("/"); !ok || name != "static/index.html" {
		t.Fatalf("root = %q, %t", name, ok)
	}
}

func TestHandlerServesEmbeddedAssetsOnly(t *testing.T) {
	h := Handler()
	for _, path := range []string{"/", "/assets/app.js", "/assets/request-state.js", "/assets/styles.css"} {
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, path, nil))
		if rr.Code != http.StatusOK || rr.Body.Len() == 0 {
			t.Fatalf("path=%s status=%d len=%d", path, rr.Code, rr.Body.Len())
		}
	}
	for _, path := range []string{"/assets/../index.html", "/assets/%2e%2e/%2e%2e/etc/passwd", "/missing"} {
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, path, nil))
		if rr.Code == http.StatusOK {
			t.Fatalf("path=%s unexpectedly served", path)
		}
	}
}

func TestHandlerSupportsHeadETagAndSafeRevalidation(t *testing.T) {
	h := Handler()
	get := httptest.NewRecorder()
	h.ServeHTTP(get, httptest.NewRequest(http.MethodGet, "/assets/app.js", nil))
	if get.Code != http.StatusOK || get.Header().Get("ETag") == "" {
		t.Fatalf("GET status=%d etag=%q", get.Code, get.Header().Get("ETag"))
	}
	if got := get.Header().Get("Cache-Control"); got != "public, max-age=0, must-revalidate" {
		t.Fatalf("cache-control=%q", got)
	}
	if get.Header().Get("Cache-Control") == "no-store" {
		t.Fatal("static asset unexpectedly marked no-store")
	}

	conditional := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/assets/app.js", nil)
	r.Header.Set("If-None-Match", get.Header().Get("ETag"))
	h.ServeHTTP(conditional, r)
	if conditional.Code != http.StatusNotModified || conditional.Body.Len() != 0 {
		t.Fatalf("conditional status=%d body=%d", conditional.Code, conditional.Body.Len())
	}

	head := httptest.NewRecorder()
	h.ServeHTTP(head, httptest.NewRequest(http.MethodHead, "/assets/app.js", nil))
	if head.Code != http.StatusOK || head.Body.Len() != 0 || head.Header().Get("ETag") != get.Header().Get("ETag") {
		t.Fatalf("HEAD status=%d body=%d etag=%q", head.Code, head.Body.Len(), head.Header().Get("ETag"))
	}
}

func BenchmarkEmbeddedAssetHandler(b *testing.B) {
	h := Handler()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/assets/app.js", nil))
	}
}

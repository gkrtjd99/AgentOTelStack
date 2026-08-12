package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestProjectIsSafeForUntrustedTelemetry(t *testing.T) {
	secret := "Bearer live-secret-cookie password=do-not-leak"
	in := map[string]any{
		"message":       "hello\x1b[31m world",
		"authorization": secret, "cookie": secret, "api_key": secret,
		"password": secret, "http.url": "https://example.test/pay?token=" + secret + "#frag",
		"db.statement": "select password from users", "gen_ai.prompt": secret,
		"body": secret, "trace_id": "abc",
	}
	b, _ := json.Marshal(project(in))
	out := string(b)
	if strings.Contains(out, "live-secret") || strings.Contains(out, "password=do-not-leak") || strings.Contains(out, "gen_ai") {
		t.Fatalf("secret or forbidden field escaped projection: %s", out)
	}
	if strings.ContainsAny(out, "\x00\x1b") {
		t.Fatalf("control character escaped projection: %q", out)
	}
}

func request(path, method, token, body string) *http.Request {
	r := httptest.NewRequest(method, "http://gateway"+path, strings.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("Content-Type", "application/x-protobuf")
	return r
}

func TestAuthIsUniformAndEndpointsArePOSTOnly(t *testing.T) {
	c := config{token: "secret", maxConcurrent: 1}
	sem := make(chan struct{}, 1)
	for _, path := range ingestPaths {
		for _, token := range []string{"", "wrong", "secretx"} {
			rr := httptest.NewRecorder()
			handleIngest(c, sem, path, rr, request(path, http.MethodPost, token, "x"))
			if rr.Code != http.StatusUnauthorized || rr.Body.String() != "Unauthorized\n" {
				t.Fatalf("%s token %q: got %d %q", path, token, rr.Code, rr.Body.String())
			}
		}
		rr := httptest.NewRecorder()
		handleIngest(c, sem, path, rr, request(path, http.MethodGet, "secret", ""))
		if rr.Code != http.StatusMethodNotAllowed {
			t.Fatalf("%s GET: got %d", path, rr.Code)
		}
	}
}

func TestQueryHealthRequiresQueryToken(t *testing.T) {
	c := config{queryToken: "query-secret"}
	for _, token := range []string{"", "wrong"} {
		rr := httptest.NewRecorder()
		queryHealth(c)(rr, request("/v1/health", http.MethodGet, token, ""))
		if rr.Code != http.StatusUnauthorized {
			t.Fatalf("token %q: got %d", token, rr.Code)
		}
	}
	rr := httptest.NewRecorder()
	queryHealth(c)(rr, request("/v1/health", http.MethodGet, "query-secret", ""))
	if rr.Code != http.StatusOK || !strings.Contains(rr.Body.String(), `"status":"ok"`) {
		t.Fatalf("valid token: got %d %q", rr.Code, rr.Body.String())
	}
}

func TestIngestForwardsOnlyProtobufAndMapsUpstream(t *testing.T) {
	var got *http.Request
	var gotBody string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r
		body, _ := io.ReadAll(r.Body)
		gotBody = string(body)
		if r.URL.Path != "/v1/logs" {
			t.Errorf("upstream path = %s", r.URL.Path)
		}
		w.WriteHeader(http.StatusAccepted)
	}))
	defer upstream.Close()
	c := config{token: "secret", upstream: upstream.URL, maxConcurrent: 1}
	sem := make(chan struct{}, 1)
	r := request("/v1/logs", http.MethodPost, "secret", "protobuf")
	for _, key := range []string{"Cookie", "Set-Cookie", "Proxy-Authorization", "X-Forwarded-For"} {
		r.Header.Set(key, "must-not-forward")
	}
	rr := httptest.NewRecorder()
	if status := handleIngest(c, sem, "/v1/logs", rr, r); status != http.StatusAccepted {
		t.Fatalf("status = %d", status)
	}
	if got == nil || got.Header.Get("Content-Type") != "application/x-protobuf" || got.Header.Get("Authorization") != "" || got.Header.Get("Cookie") != "" {
		t.Fatalf("sensitive headers forwarded: %#v", got)
	}
	if gotBody != "protobuf" {
		t.Fatalf("body = %q", gotBody)
	}
}

func TestBodyAndContentContract(t *testing.T) {
	c := config{token: "secret", upstream: "http://127.0.0.1:1", maxConcurrent: 1}
	sem := make(chan struct{}, 1)
	for _, contentType := range []string{"", "application/json", "application/x-protobuf; charset=binary"} {
		r := request("/v1/traces", http.MethodPost, "secret", "x")
		r.Header.Set("Content-Type", contentType)
		rr := httptest.NewRecorder()
		status := handleIngest(c, sem, "/v1/traces", rr, r)
		if contentType == "application/x-protobuf; charset=binary" {
			if status != http.StatusBadGateway { // valid content type reaches the unavailable upstream
				t.Fatalf("valid content type status = %d", status)
			}
		} else if status != http.StatusBadRequest {
			t.Fatalf("content type %q status = %d", contentType, status)
		}
	}
	r := request("/v1/metrics", http.MethodPost, "secret", strings.Repeat("x", maxBody+1))
	rr := httptest.NewRecorder()
	if status := handleIngest(c, sem, "/v1/metrics", rr, r); status != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversize status = %d", status)
	}
}

func TestLoadRejectsUnsafeUpstream(t *testing.T) {
	t.Setenv("GATEWAY_INGEST_TOKEN", "secret")
	t.Setenv("GATEWAY_QUERY_TOKEN", "different-secret")
	for _, upstream := range []string{"https://collector:4318", "http://collector:4318/path", "http://collector:4318?x=1", "collector:4318"} {
		t.Setenv("GATEWAY_COLLECTOR_URL", upstream)
		if _, err := load(); err == nil {
			t.Fatalf("upstream %q accepted", upstream)
		}
	}
}

func TestLoadRejectsMissingOrEqualTokens(t *testing.T) {
	t.Setenv("GATEWAY_COLLECTOR_URL", "http://collector:4318")
	t.Setenv("GATEWAY_INGEST_TOKEN", "")
	t.Setenv("GATEWAY_QUERY_TOKEN", "query-secret")
	if _, err := load(); err == nil {
		t.Fatal("missing ingest token accepted")
	}
	t.Setenv("GATEWAY_INGEST_TOKEN", "same-secret")
	t.Setenv("GATEWAY_QUERY_TOKEN", "same-secret")
	if _, err := load(); err == nil {
		t.Fatal("equal ingest/query tokens accepted")
	}
}

func TestTokenFileSupportsRawAndXDGJSON(t *testing.T) {
	raw := t.TempDir() + "/raw"
	if err := os.WriteFile(raw, []byte(" raw-secret\n"), 0600); err != nil {
		t.Fatal(err)
	}
	got, err := tokenFile(raw, "ingest_token")
	if err != nil || got != "raw-secret" {
		t.Fatalf("raw token = %q, err = %v", got, err)
	}
	jsonFile := t.TempDir() + "/credentials"
	if err := os.WriteFile(jsonFile, []byte(`{"ingest_token":"ingest-secret","query_token":"query-secret"}`), 0600); err != nil {
		t.Fatal(err)
	}
	got, err = tokenFile(jsonFile, "query_token")
	if err != nil || got != "query-secret" {
		t.Fatalf("JSON token = %q, err = %v", got, err)
	}
}

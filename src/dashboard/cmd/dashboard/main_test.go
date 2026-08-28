package main

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

var testClientToken = strings.Repeat("0123456789abcdef", 4)

func localDashboardRequest(method, path, body string) *http.Request {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Host = "localhost"
	return r
}

func testDashboardConfig() config {
	return config{gatewayURL: "http://gateway:17777", queryToken: "query", clientToken: testClientToken, projectID: "550e8400-e29b-41d4-a716-446655440000"}
}

func authorizedDashboardRequest(method, path, body string) *http.Request {
	r := localDashboardRequest(method, path, body)
	r.Header.Set("Authorization", "Dashboard "+testClientToken)
	return r
}

func TestLoadRequiresTokenAndUUIDv4Project(t *testing.T) {
	t.Setenv("DASHBOARD_GATEWAY_URL", "http://gateway:17777")
	t.Setenv("DASHBOARD_LISTEN_ADDR", "")
	t.Setenv("DASHBOARD_QUERY_TOKEN", "")
	t.Setenv("DASHBOARD_CLIENT_TOKEN", "")
	t.Setenv("DASHBOARD_PROJECT_ID", "")
	if _, err := load(); err == nil {
		t.Fatal("missing dashboard credentials accepted")
	}
	t.Setenv("DASHBOARD_QUERY_TOKEN", "query-secret")
	for _, client := range []string{"", "ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789", strings.Repeat("q", 64), "query-secret"} {
		t.Setenv("DASHBOARD_CLIENT_TOKEN", client)
		if _, err := load(); err == nil {
			t.Fatalf("invalid or equal client token accepted: %q", client)
		}
	}
	t.Setenv("DASHBOARD_CLIENT_TOKEN", testClientToken)
	for _, project := range []string{
		"550e8400-e29b-11d4-a716-446655440000",
		"550e8400-e29b-51d4-a716-446655440000",
		"not-a-project",
	} {
		t.Setenv("DASHBOARD_PROJECT_ID", project)
		if _, err := load(); err == nil {
			t.Fatalf("invalid project accepted: %s", project)
		}
	}
	t.Setenv("DASHBOARD_PROJECT_ID", "550e8400-e29b-41d4-a716-446655440000")
	c, err := load()
	if err != nil {
		t.Fatal(err)
	}
	if c.listenAddr != defaultListenAddr || c.gatewayURL != defaultGatewayURL {
		t.Fatalf("defaults = %#v", c)
	}
	_ = os.Unsetenv("DASHBOARD_LISTEN_ADDR")
}

func TestSecurityHeadersAndLocalHealth(t *testing.T) {
	h, err := newHandler(testDashboardConfig())
	if err != nil {
		t.Fatal(err)
	}
	local := localDashboardRequest(http.MethodGet, "/health", "")
	local.RemoteAddr = "127.0.0.1:1234"
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, local)
	if rr.Code != http.StatusOK {
		t.Fatalf("health status=%d body=%s", rr.Code, rr.Body.String())
	}
	for key, want := range map[string]string{
		"Cache-Control":           "no-store",
		"X-Content-Type-Options":  "nosniff",
		"Referrer-Policy":         "no-referrer",
		"Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
	} {
		if got := rr.Header().Get(key); got != want {
			t.Fatalf("%s=%q want %q", key, got, want)
		}
	}
	var body map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil || body["status"] != "ok" {
		t.Fatalf("health body=%s err=%v", rr.Body.String(), err)
	}

	remote := localDashboardRequest(http.MethodGet, "/health", "")
	remote.RemoteAddr = "192.0.2.10:1234"
	rr = httptest.NewRecorder()
	h.ServeHTTP(rr, remote)
	if rr.Code != http.StatusForbidden || !strings.Contains(rr.Body.String(), "local_only") {
		t.Fatalf("remote health status=%d body=%s", rr.Code, rr.Body.String())
	}
	forwarded := localDashboardRequest(http.MethodGet, "/health", "")
	forwarded.RemoteAddr = "192.0.2.10:1234"
	forwarded.Header.Set("X-Forwarded-For", "127.0.0.1")
	rr = httptest.NewRecorder()
	h.ServeHTTP(rr, forwarded)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("forwarded health status=%d", rr.Code)
	}
}

func TestDashboardClientBoundaryRejectsForgedOrMissingCredentials(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"schema_version":"1.0","data":{"services":[]},"partial":false,"backends":[{"name":"logs","status":"ok"}]}`))
	}))
	defer server.Close()
	c := testDashboardConfig()
	c.gatewayURL = server.URL
	h, err := newHandler(c)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name  string
		value string
		add   bool
	}{
		{name: "missing"},
		{name: "wrong scheme", value: "Bearer " + testClientToken},
		{name: "wrong token", value: "Dashboard " + strings.Repeat("a", 64)},
		{name: "ingest bearer", value: "Bearer ingest-token"},
		{name: "duplicate", value: "Dashboard " + testClientToken, add: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := localDashboardRequest(http.MethodGet, "/api/services", "")
			r.RemoteAddr = "192.0.2.10:1234"
			r.Header.Set("Origin", "http://attacker.example")
			r.Header.Set("Referer", "http://attacker.example/")
			r.Header.Set("Cookie", "dashboard="+testClientToken)
			if tc.value != "" {
				r.Header.Set("Authorization", tc.value)
			}
			if tc.add {
				r.Header.Add("Authorization", "Dashboard "+strings.Repeat("b", 64))
			}
			before := calls.Load()
			rr := httptest.NewRecorder()
			h.ServeHTTP(rr, r)
			if rr.Code != http.StatusUnauthorized || rr.Body.String() != `{"error":"unauthorized"}`+"\n" {
				t.Fatalf("status=%d body=%q", rr.Code, rr.Body.String())
			}
			if calls.Load() != before {
				t.Fatal("unauthorized request reached upstream")
			}
			if strings.Contains(rr.Body.String(), testClientToken) {
				t.Fatal("unauthorized response echoed client token")
			}
		})
	}
	contextRequest := localDashboardRequest(http.MethodGet, "/api/context", "")
	contextRequest.RemoteAddr = "192.0.2.10:1234"
	contextRequest.Header.Set("Origin", "http://attacker.example")
	contextRequest.Header.Set("Referer", "http://attacker.example/")
	contextRequest.Header.Set("Cookie", "dashboard="+testClientToken)
	contextRequest.Header.Set("Authorization", "Bearer ingest-token")
	contextResponse := httptest.NewRecorder()
	beforeContext := calls.Load()
	h.ServeHTTP(contextResponse, contextRequest)
	if contextResponse.Code != http.StatusUnauthorized || calls.Load() != beforeContext {
		t.Fatalf("forged context request status=%d calls_before=%d calls_after=%d", contextResponse.Code, beforeContext, calls.Load())
	}

	root := localDashboardRequest(http.MethodGet, "/", "")
	root.RemoteAddr = "192.0.2.10:1234"
	rootResponse := httptest.NewRecorder()
	h.ServeHTTP(rootResponse, root)
	if rootResponse.Code != http.StatusOK {
		t.Fatalf("public root status=%d", rootResponse.Code)
	}
	valid := localDashboardRequest(http.MethodGet, "/api/services", "")
	valid.RemoteAddr = "192.0.2.10:1234"
	valid.Header.Set("Authorization", "Dashboard "+testClientToken)
	validResponse := httptest.NewRecorder()
	h.ServeHTTP(validResponse, valid)
	if validResponse.Code != http.StatusOK {
		t.Fatalf("valid client token status=%d body=%s", validResponse.Code, validResponse.Body.String())
	}
	forgedHost := authorizedDashboardRequest(http.MethodGet, "/api/services", "")
	forgedHost.Host = "attacker.example"
	forgedHostResponse := httptest.NewRecorder()
	h.ServeHTTP(forgedHostResponse, forgedHost)
	if forgedHostResponse.Code != http.StatusForbidden {
		t.Fatalf("invalid host status=%d body=%s", forgedHostResponse.Code, forgedHostResponse.Body.String())
	}
}

func TestNonLoopbackNumericHostIsRejected(t *testing.T) {
	h, err := newHandler(testDashboardConfig())
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Host = "192.0.2.10:3000"
	r.RemoteAddr = "192.0.2.10:1234"
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, r)
	if rr.Code != http.StatusForbidden || !strings.Contains(rr.Body.String(), "host_not_allowed") {
		t.Fatalf("numeric host status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestHostBoundaryAllowsOnlyLocalForms(t *testing.T) {
	for _, tc := range []struct {
		host string
		want bool
	}{
		{host: "localhost", want: true},
		{host: "LOCALHOST:3000", want: true},
		{host: "127.0.0.1", want: true},
		{host: "127.255.10.20:65535", want: true},
		{host: "[::1]", want: true},
		{host: "[::1]:3000", want: true},
		{host: "attacker.example", want: false},
		{host: "host.docker.internal", want: false},
		{host: "", want: false},
		{host: "localhost:bad", want: false},
		{host: "127.0.0.1:99999", want: false},
		{host: "192.0.2.10:3000", want: false},
		{host: "[::2]:3000", want: false},
		{host: "::1", want: false},
		{host: "[::1", want: false},
	} {
		t.Run(tc.host, func(t *testing.T) {
			if got := allowedHost(tc.host); got != tc.want {
				t.Fatalf("allowedHost(%q)=%t, want %t", tc.host, got, tc.want)
			}
		})
	}

	h, err := newHandler(testDashboardConfig())
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/", "/health", "/api/services", "/api/context", "/api/errors", "/api/correlate"} {
		r := httptest.NewRequest(http.MethodGet, path, nil)
		r.Host = "attacker.example"
		r.RemoteAddr = "127.0.0.1:1234"
		if path == "/api/correlate" {
			r.Method = http.MethodPost
		}
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, r)
		if rr.Code != http.StatusForbidden || !strings.Contains(rr.Body.String(), "host_not_allowed") {
			t.Fatalf("path=%s status=%d body=%s", path, rr.Code, rr.Body.String())
		}
	}
}

func TestStaticRoutesAndTraversal(t *testing.T) {
	h, err := newHandler(testDashboardConfig())
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/", "/assets/app.js", "/assets/styles.css"} {
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, localDashboardRequest(http.MethodGet, path, ""))
		if rr.Code != http.StatusOK || rr.Body.Len() == 0 {
			t.Fatalf("static %s status=%d bytes=%d", path, rr.Code, rr.Body.Len())
		}
	}
	first := httptest.NewRecorder()
	h.ServeHTTP(first, localDashboardRequest(http.MethodGet, "/assets/app.js", ""))
	if first.Code != http.StatusOK || first.Header().Get("ETag") == "" || first.Header().Get("Cache-Control") != "public, max-age=0, must-revalidate" {
		t.Fatalf("static cache contract status=%d etag=%q cache=%q", first.Code, first.Header().Get("ETag"), first.Header().Get("Cache-Control"))
	}
	conditional := localDashboardRequest(http.MethodGet, "/assets/app.js", "")
	conditional.Header.Set("If-None-Match", first.Header().Get("ETag"))
	cached := httptest.NewRecorder()
	h.ServeHTTP(cached, conditional)
	if cached.Code != http.StatusNotModified || cached.Body.Len() != 0 {
		t.Fatalf("static conditional status=%d body=%d", cached.Code, cached.Body.Len())
	}
	for _, path := range []string{"/../go.mod", "/assets/../index.html", "/assets/%2e%2e/%2e%2e/go.mod", "/assets/"} {
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, localDashboardRequest(http.MethodGet, path, ""))
		if rr.Code == http.StatusOK {
			t.Fatalf("traversal %s served successfully", path)
		}
	}
	post := httptest.NewRecorder()
	h.ServeHTTP(post, localDashboardRequest(http.MethodPost, "/", "x"))
	if post.Code != http.StatusMethodNotAllowed {
		t.Fatalf("static POST status=%d", post.Code)
	}
}

func TestDashboardListenerRejectsMalformedAndOccupiedAddresses(t *testing.T) {
	for _, address := range []string{"", "not-an-address", "127.0.0.1:-1", "127.0.0.1:bad"} {
		if listener, err := bindListener(address); err == nil {
			_ = listener.Close()
			t.Fatalf("malformed address %q accepted", address)
		}
	}
	occupied, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	if listener, err := bindListener(occupied.Addr().String()); err == nil {
		_ = listener.Close()
		t.Fatalf("occupied address %q accepted", occupied.Addr())
	}
}

func TestHealthcheckIsBoundedAndChecksStatus(t *testing.T) {
	ok := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) }))
	if got := runHealthcheck(ok.URL + "/health"); got != 0 {
		t.Fatalf("healthy probe exit=%d", got)
	}
	ok.Close()

	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusServiceUnavailable) }))
	if got := runHealthcheck(bad.URL + "/health"); got != 1 {
		t.Fatalf("unhealthy probe exit=%d", got)
	}
	bad.Close()

	blocked := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	defer blocked.Close()
	start := time.Now()
	if got := runHealthcheck(blocked.URL + "/health"); got != 1 {
		t.Fatalf("blocked probe exit=%d", got)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("healthcheck exceeded bound: %s", elapsed)
	}
}

func TestHealthcheckTargetFollowsConfiguredListener(t *testing.T) {
	for _, tc := range []struct {
		addr string
		want string
	}{
		{addr: ":3000", want: "http://127.0.0.1:3000/health"},
		{addr: "0.0.0.0:31000", want: "http://127.0.0.1:31000/health"},
		{addr: "[::]:31000", want: "http://[::1]:31000/health"},
		{addr: "localhost:31000", want: "http://127.0.0.1:31000/health"},
		{addr: "127.0.0.1:31000", want: "http://127.0.0.1:31000/health"},
		{addr: "[::1]:31000", want: "http://[::1]:31000/health"},
	} {
		t.Run(tc.addr, func(t *testing.T) {
			got, err := healthcheckTarget(tc.addr)
			if err != nil || got != tc.want {
				t.Fatalf("target=%q err=%v, want %q", got, err, tc.want)
			}
		})
	}
	for _, addr := range []string{"attacker.example:31000", "127.0.0.1:bad", "127.0.0.1:0", "[::1"} {
		if _, err := healthcheckTarget(addr); err == nil {
			t.Fatalf("unsafe health target accepted: %q", addr)
		}
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/health" {
			t.Errorf("health path=%q", r.URL.Path)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()
	target, err := healthcheckTarget(server.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	if got := runHealthcheck(target); got != 0 {
		t.Fatalf("custom-port healthcheck exit=%d target=%s", got, target)
	}
}

func TestDashboardStartupFailureSubprocess(t *testing.T) {
	if os.Getenv("TASK30_DASHBOARD_STARTUP_HELPER") == "1" {
		main()
		return
	}
	cases := []struct {
		name string
		env  string
	}{
		{name: "malformed", env: "not-an-address"},
	}
	occupied, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	cases = append(cases, struct {
		name string
		env  string
	}{name: "occupied", env: occupied.Addr().String()})
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestDashboardStartupFailureSubprocess$")
			cmd.Env = append(os.Environ(),
				"TASK30_DASHBOARD_STARTUP_HELPER=1",
				"DASHBOARD_QUERY_TOKEN=query-secret",
				"DASHBOARD_CLIENT_TOKEN="+testClientToken,
				"DASHBOARD_PROJECT_ID=550e8400-e29b-41d4-a716-446655440000",
				"DASHBOARD_LISTEN_ADDR="+tc.env,
			)
			if err := cmd.Run(); err == nil {
				t.Fatal("startup failure subprocess exited successfully")
			}
			if ctx.Err() != nil {
				t.Fatalf("startup failure subprocess exceeded bound: %v", ctx.Err())
			}
		})
	}
}

package proxy

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const testProject = "550e8400-e29b-41d4-a716-446655440000"
const testTrace = "0123456789abcdef0123456789abcdef"

var testDashboardClientToken = strings.Repeat("0123456789abcdef", 4)

func testHandler(t *testing.T, server *httptest.Server) *Handler {
	t.Helper()
	h, err := New(Config{GatewayURL: server.URL, QueryToken: "server-query-secret", ProjectID: testProject})
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func envelope(data string) string {
	return `{"schema_version":"1.0","kind":"gateway.context.v1","freshness":"2000-01-01T00:00:00Z","scope":{"project":"` + testProject + `"},"data":` + data + `,"partial":false,"truncated":false,"content_trust":"untrusted_telemetry","backends":[{"name":"logs","status":"ok"}]}`
}

func TestValidateConfigRequiresFixedProjectAndSafeGateway(t *testing.T) {
	valid := Config{GatewayURL: "http://gateway:17777", QueryToken: "query", ProjectID: testProject}
	if err := ValidateConfig(valid); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}
	if err := ValidateConfig(Config{GatewayURL: "https://gateway:17777", QueryToken: "query", ProjectID: testProject}); err != nil {
		t.Fatalf("HTTPS config rejected: %v", err)
	}
	for _, tc := range []Config{
		{GatewayURL: valid.GatewayURL, QueryToken: "", ProjectID: valid.ProjectID},
		{GatewayURL: valid.GatewayURL, QueryToken: "query", ProjectID: ""},
		{GatewayURL: "http://gateway:17777/path", QueryToken: "query", ProjectID: testProject},
		{GatewayURL: "http://gateway:17777?x=1", QueryToken: "query", ProjectID: testProject},
		{GatewayURL: "ftp://gateway:17777", QueryToken: "query", ProjectID: testProject},
	} {
		if err := ValidateConfig(tc); err == nil {
			t.Fatalf("unsafe config accepted: %#v", tc)
		}
	}
}

func TestFixedScopeAndHeadersAreApplied(t *testing.T) {
	var seen atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen.Store(true)
		if r.Header.Get("Authorization") != "Bearer server-query-secret" {
			t.Errorf("authorization = %q", r.Header.Get("Authorization"))
		}
		for _, key := range []string{"Cookie", "Proxy-Authorization", "X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto", "X-Real-IP"} {
			if got := r.Header.Get(key); got != "" {
				t.Errorf("forwarded %s = %q", key, got)
			}
		}
		if r.URL.Path != "/v1/context" || r.URL.Query().Get("project") != testProject || r.URL.Query().Get("service") != "checkout" || r.URL.Query().Get("limit") != "4" {
			t.Errorf("upstream request = %s", r.URL.String())
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, envelope(`{"logs":[],"metrics":[]}`))
	}))
	defer server.Close()
	h := testHandler(t, server)
	r := httptest.NewRequest(http.MethodGet, "/api/context?service=checkout&lookback=15m&limit=4", nil)
	r.Header.Set("Authorization", "Dashboard "+testDashboardClientToken)
	r.Header.Set("Cookie", "session=browser-cookie")
	r.Header.Set("X-Forwarded-For", "192.0.2.1")
	r.Header.Set("X-Real-IP", "192.0.2.1")
	r.RemoteAddr = "127.0.0.1:1234"
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, r)
	if rr.Code != http.StatusOK || !seen.Load() {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	if strings.Contains(rr.Body.String(), testProject) || strings.Contains(rr.Body.String(), "server-query-secret") || strings.Contains(rr.Body.String(), "browser-secret") {
		t.Fatalf("credential or project escaped browser response: %s", rr.Body.String())
	}
	if strings.Contains(rr.Body.String(), "2000-01-01T00:00:00Z") || strings.Contains(rr.Body.String(), "gateway.context.v1") {
		t.Fatalf("raw Gateway metadata escaped Dashboard response: %s", rr.Body.String())
	}
	var view View
	if err := json.Unmarshal(rr.Body.Bytes(), &view); err != nil {
		t.Fatal(err)
	}
	if view.SchemaVersion != DashboardSchema || !view.Scope.ProjectBound || view.Scope.Service != "checkout" {
		t.Fatalf("view scope = %#v", view.Scope)
	}
}

func TestCorrelateInjectsFixedProjectAndExactBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/correlate" {
			t.Errorf("upstream request = %s %s", r.Method, r.URL.Path)
		}
		if r.Header.Get("Content-Type") != "application/json" || r.Header.Get("Authorization") != "Bearer server-query-secret" {
			t.Errorf("upstream headers = %#v", r.Header)
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if body["trace_id"] != testTrace || body["project"] != testProject || body["limit"] != float64(7) {
			t.Errorf("upstream body = %#v", body)
		}
		_, _ = io.WriteString(w, envelope(`{"correlation":{"trace_id":"`+testTrace+`","spans":[]}}`))
	}))
	defer server.Close()
	h := testHandler(t, server)
	r := httptest.NewRequest(http.MethodPost, "/api/correlate", strings.NewReader(`{"trace_id":"`+testTrace+`","limit":7}`))
	r.Header.Set("Content-Type", "application/json; charset=utf-8")
	r.Header.Set("Authorization", "Dashboard "+testDashboardClientToken)
	r.Header.Set("Cookie", "browser-cookie")
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, r)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestCorrelateRejectsExplicitZeroLimitWithoutUpstreamCall(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		_, _ = io.WriteString(w, envelope(`{"correlation":{"trace_id":"`+testTrace+`","spans":[]}}`))
	}))
	defer server.Close()
	h := testHandler(t, server)
	for _, body := range []string{
		`{"trace_id":"` + testTrace + `","limit":0}`,
		`{"trace_id":"` + testTrace + `","limit":-0}`,
	} {
		r := httptest.NewRequest(http.MethodPost, "/api/correlate", strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, r)
		if rr.Code != http.StatusBadRequest || !strings.Contains(rr.Body.String(), `"invalid_limit"`) {
			t.Fatalf("body=%s status=%d", rr.Body.String(), rr.Code)
		}
	}
	if got := calls.Load(); got != 0 {
		t.Fatalf("explicit zero limits reached upstream %d times", got)
	}
}

func TestRoutesRejectMethodsAndParams(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, envelope(`{"services":["api"]}`))
	}))
	defer server.Close()
	h := testHandler(t, server)
	for _, tc := range []struct {
		name, path, method, body, contentType string
	}{
		{"services project", "/api/services?project=" + testProject, http.MethodGet, "", ""},
		{"services duplicate", "/api/services?x=1&x=2", http.MethodGet, "", ""},
		{"context unknown", "/api/context?project=" + testProject, http.MethodGet, "", ""},
		{"context duplicate", "/api/context?service=api&service=worker", http.MethodGet, "", ""},
		{"context bad lookback", "/api/context?lookback=2m", http.MethodGet, "", ""},
		{"correlate method", "/api/correlate", http.MethodGet, "", ""},
		{"correlate project", "/api/correlate", http.MethodPost, `{"trace_id":"` + testTrace + `","project":"` + testProject + `"}`, "application/json"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
			if tc.contentType != "" {
				r.Header.Set("Content-Type", tc.contentType)
			}
			rr := httptest.NewRecorder()
			h.ServeHTTP(rr, r)
			if rr.Code < 400 || rr.Code >= 500 {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
		})
	}
}

func TestNormalizePreservesTrustAndStatusesWithoutUnsafeText(t *testing.T) {
	raw := map[string]any{
		"schema_version": "1.0", "partial": true, "truncated": true,
		"content_trust": "untrusted_telemetry", "warnings": []any{"warn\x1b[31m"},
		"backends": []any{map[string]any{"name": "logs", "status": "timeout", "error": "backend timeout"}},
		"data": map[string]any{"logs": map[string]any{"data": []any{map[string]any{
			"trace_id": testTrace, "service.name": "api", "severity_text": "error", "message": "hello\x1b[31m\x00world",
		}}}},
	}
	view := Normalize("context", raw, Scope{ProjectBound: true})
	if !view.Partial || !view.Truncated || view.ContentTrust != UntrustedTelemetry || len(view.Backends) != 1 || view.Backends[0].Status != "timeout" {
		t.Fatalf("envelope metadata = %#v", view)
	}
	encoded, _ := json.Marshal(view)
	if strings.Contains(string(encoded), "\x1b") || strings.Contains(string(encoded), testProject) {
		t.Fatalf("unsafe/secret content escaped: %s", encoded)
	}
	data, ok := view.Data.(ContextData)
	if !ok || !data.Supported || len(data.Logs) != 1 || strings.Contains(data.Logs[0].Message, "\x1b") {
		t.Fatalf("normalized data = %#v", view.Data)
	}
}

func TestNormalizeCanonicalFields(t *testing.T) {
	const logTime = "2026-08-23T12:34:56.789Z"
	view := Normalize("errors", map[string]any{"data": map[string]any{"logs": map[string]any{"data": []any{map[string]any{"_time": logTime, "service.name": "checkout", "message": "payment failed"}}}}}, Scope{})
	data, ok := view.Data.(ErrorsData)
	if !ok || len(data.Errors) != 1 || data.Errors[0].Service != "checkout" || data.Errors[0].Timestamp != logTime {
		t.Fatalf("canonical fields = %#v", view.Data)
	}
	correlation := Normalize("correlate", map[string]any{"data": map[string]any{"correlation": map[string]any{"trace_id": testTrace, "spans": []any{map[string]any{"spanID": "span-1", "processID": "p1", "operationName": "checkout", "startTime": float64(1700000000000), "duration": float64(1000)}}, "processes": map[string]any{"p1": map[string]any{"serviceName": "checkout"}}}}}, Scope{})
	cdata, ok := correlation.Data.(CorrelationData)
	if !ok || len(cdata.Spans) != 1 || cdata.Spans[0].Service != "checkout" || cdata.Spans[0].StartTime != "1700000000000" {
		t.Fatalf("canonical span = %#v", correlation.Data)
	}
}

func TestRedactViewIsCopyOnWriteAndPreservesViewSemantics(t *testing.T) {
	original := View{SchemaVersion: DashboardSchema, Kind: "context", FetchedAt: "2026-08-24T00:00:00Z", Partial: true, Truncated: true, Warnings: []string{"query-secret warning"}, ContentTrust: UntrustedTelemetry, Backends: []BackendStatus{{Name: "logs", Status: "timeout", Error: "query-secret"}}, Scope: Scope{Service: "checkout", Lookback: "15m", Limit: 4, ProjectBound: true}, Data: ContextData{Supported: true, Logs: []LogRecord{{Service: "checkout", Message: "query-secret failed"}}, Metrics: []MetricRecord{{Service: "checkout", Value: "1"}}}}
	before := original
	redacted := redactView(original, "query-secret")
	if !reflect.DeepEqual(original, before) {
		t.Fatalf("redaction mutated input")
	}
	if !redacted.Partial || !redacted.Truncated || redacted.ContentTrust != UntrustedTelemetry || redacted.Backends[0].Status != "timeout" || !redacted.Scope.ProjectBound {
		t.Fatalf("view semantics changed: %#v", redacted)
	}
	data, ok := redacted.Data.(ContextData)
	if !ok || data.Logs[0].Message != "[redacted] failed" || data.Metrics[0].Value != "1" {
		t.Fatalf("typed redaction = %#v", redacted.Data)
	}
	if original.Data.(ContextData).Logs[0].Message != "query-secret failed" || original.Backends[0].Error != "query-secret" {
		t.Fatal("original nested values changed")
	}
	unknown := View{Data: map[string]any{"items": []any{map[string]any{"message": "query-secret"}}}}
	unknownBefore := unknown
	unknownRedacted := redactView(unknown, "query-secret")
	if !reflect.DeepEqual(unknown, unknownBefore) {
		t.Fatal("unknown data was mutated")
	}
	encoded, err := json.Marshal(unknownRedacted)
	if err != nil || strings.Contains(string(encoded), "query-secret") {
		t.Fatalf("unknown data redaction failed: err=%v body=%s", err, encoded)
	}
}

func TestNormalizeBoundsServicesAndBackends(t *testing.T) {
	services := make([]any, maxNormalizedServices+25)
	for i := range services {
		services[i] = "service-" + strconv.Itoa(i)
	}
	backends := make([]any, maxNormalizedBackends+25)
	for i := range backends {
		backends[i] = map[string]any{"name": "backend-" + strconv.Itoa(i), "status": "ok"}
	}
	view := Normalize("services", map[string]any{"data": map[string]any{"services": services}, "backends": backends}, Scope{})
	if !view.Truncated || len(view.Data.(ServicesData).Services) != maxNormalizedServices || len(view.Backends) != maxNormalizedBackends {
		t.Fatalf("bounded projection = truncated=%t services=%d backends=%d", view.Truncated, len(view.Data.(ServicesData).Services), len(view.Backends))
	}
	if !reflect.DeepEqual(view.Data.(ServicesData).Services[:2], []string{"service-0", "service-1"}) {
		t.Fatalf("service order changed")
	}
	if !reflect.DeepEqual(view.Warnings, []string{"backend_status_limit", "service_list_limit"}) {
		t.Fatalf("bounded warnings = %#v", view.Warnings)
	}
	warnings := make([]any, 16)
	for i := range warnings {
		warnings[i] = "upstream-warning"
	}
	withFullWarnings := Normalize("services", map[string]any{"warnings": warnings, "data": map[string]any{"services": services}}, Scope{})
	if len(withFullWarnings.Warnings) != 16 || withFullWarnings.Warnings[15] != "service_list_limit" {
		t.Fatalf("truncation warning was hidden: %#v", withFullWarnings.Warnings)
	}
}

func TestNormalizeAdversarialFixtureRemainsBounded(t *testing.T) {
	items := make([]any, 8000)
	for i := range items {
		items[i] = map[string]any{"message": strings.Repeat("x", 16), "service.name": "api"}
	}
	raw := map[string]any{"data": map[string]any{"services": items}, "backends": items}
	encoded, err := json.Marshal(raw)
	if err != nil || len(encoded) > 1<<20 {
		t.Fatalf("fixture size=%d err=%v", len(encoded), err)
	}
	view := Normalize("services", raw, Scope{})
	if !view.Truncated || len(view.Backends) != maxNormalizedBackends || len(view.Data.(ServicesData).Services) != 0 {
		t.Fatalf("adversarial bounds = %#v", view)
	}
}

func TestHTTPSGatewayProxyUsesConfiguredTLSClient(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, envelope(`{"services":["api"]}`))
	}))
	defer server.Close()
	h, err := New(Config{GatewayURL: server.URL, QueryToken: "query", ProjectID: testProject, HTTPClient: server.Client()})
	if err != nil {
		t.Fatal(err)
	}
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/services", nil))
	if rr.Code != http.StatusOK || !strings.Contains(rr.Body.String(), "api") {
		t.Fatalf("HTTPS proxy status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestCanceledRequestReturnsUpstreamTimeout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	defer server.Close()
	h := testHandler(t, server)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r := httptest.NewRequest(http.MethodGet, "/api/services", nil).WithContext(ctx)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, r)
	if rr.Code != http.StatusGatewayTimeout {
		t.Fatalf("canceled request status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestProxyRejectsBrowserProjectOverrideAndForbiddenHeaders(t *testing.T) {
	var sawForbidden atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for _, key := range []string{
			"Authorization", "Cookie", "Proxy-Authorization", "Referer", "X-Forwarded-For",
			"X-Forwarded-Host", "X-Forwarded-Proto", "X-Forwarded-Port", "X-Real-IP",
		} {
			if key == "Authorization" {
				if r.Header.Get(key) != "Bearer server-query-secret" {
					t.Errorf("upstream authorization = %q", r.Header.Get(key))
				}
				continue
			}
			if r.Header.Get(key) != "" {
				sawForbidden.Store(true)
				t.Errorf("browser header %s was forwarded as %q", key, r.Header.Get(key))
			}
		}
		_, _ = io.WriteString(w, envelope(`{"logs":[],"metrics":[]}`))
	}))
	defer server.Close()
	h := testHandler(t, server)
	r := httptest.NewRequest(http.MethodGet, "/api/context?service=checkout&lookback=15m&limit=4", nil)
	for _, key := range []string{"Authorization", "Cookie", "Proxy-Authorization", "Referer", "X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto", "X-Forwarded-Port", "X-Real-IP"} {
		if key == "Authorization" {
			r.Header.Set(key, "Dashboard "+testDashboardClientToken)
		} else {
			r.Header.Set(key, "browser-secret")
		}
	}
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, r)
	if rr.Code != http.StatusOK || sawForbidden.Load() {
		t.Fatalf("fixed proxy request status=%d body=%s", rr.Code, rr.Body.String())
	}
	for _, tc := range []struct {
		name   string
		path   string
		body   string
		method string
	}{
		{"services", "/api/services?project=" + testProject, "", http.MethodGet},
		{"context", "/api/context?project=" + testProject, "", http.MethodGet},
		{"errors", "/api/errors?project=" + testProject, "", http.MethodGet},
		{"correlate", "/api/correlate", `{"trace_id":"` + testTrace + `","project":"` + testProject + `"}`, http.MethodPost},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
			if tc.method == http.MethodPost {
				r.Header.Set("Content-Type", "application/json")
			}
			rr := httptest.NewRecorder()
			h.ServeHTTP(rr, r)
			if rr.Code != http.StatusBadRequest {
				t.Fatalf("project override status=%d body=%s", rr.Code, rr.Body.String())
			}
		})
	}
}

func TestProxyRejectsDuplicateUnknownAndWrongRouteInputs(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, envelope(`{"logs":[],"metrics":[]}`))
	}))
	defer server.Close()
	h := testHandler(t, server)
	cases := []struct {
		name        string
		method      string
		path        string
		body        string
		contentType string
		want        int
	}{
		{"services unknown", http.MethodGet, "/api/services?unexpected=1", "", "", http.StatusBadRequest},
		{"services duplicate", http.MethodGet, "/api/services?unexpected=1&unexpected=2", "", "", http.StatusBadRequest},
		{"context duplicate service", http.MethodGet, "/api/context?service=api&service=worker", "", "", http.StatusBadRequest},
		{"context duplicate lookback", http.MethodGet, "/api/context?lookback=5m&lookback=1h", "", "", http.StatusBadRequest},
		{"context duplicate limit", http.MethodGet, "/api/context?limit=4&limit=5", "", "", http.StatusBadRequest},
		{"errors unknown", http.MethodGet, "/api/errors?query=raw", "", "", http.StatusBadRequest},
		{"correlate duplicate field", http.MethodPost, "/api/correlate", `{"trace_id":"` + testTrace + `","trace_id":"` + testTrace + `"}`, "application/json", http.StatusBadRequest},
		{"correlate unknown field", http.MethodPost, "/api/correlate", `{"trace_id":"` + testTrace + `","raw_query":"secret"}`, "application/json", http.StatusBadRequest},
		{"correlate trailing value", http.MethodPost, "/api/correlate", `{"trace_id":"` + testTrace + `"} {}`, "application/json", http.StatusBadRequest},
		{"correlate array", http.MethodPost, "/api/correlate", `[]`, "application/json", http.StatusBadRequest},
		{"correlate malformed", http.MethodPost, "/api/correlate", `{"trace_id":}`, "application/json", http.StatusBadRequest},
		{"correlate wrong media", http.MethodPost, "/api/correlate", `{"trace_id":"` + testTrace + `"}`, "text/plain", http.StatusBadRequest},
		{"services wrong method", http.MethodPost, "/api/services", "", "", http.StatusMethodNotAllowed},
		{"context wrong method", http.MethodPost, "/api/context", "{}", "application/json", http.StatusMethodNotAllowed},
		{"errors wrong method", http.MethodPost, "/api/errors", "{}", "application/json", http.StatusMethodNotAllowed},
		{"correlate wrong method", http.MethodGet, "/api/correlate", "", "", http.StatusMethodNotAllowed},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
			if tc.contentType != "" {
				r.Header.Set("Content-Type", tc.contentType)
			}
			rr := httptest.NewRecorder()
			h.ServeHTTP(rr, r)
			if rr.Code != tc.want {
				t.Fatalf("status=%d want=%d body=%s", rr.Code, tc.want, rr.Body.String())
			}
		})
	}
}

func TestProxyRejectsRedirectsWithoutForwarding(t *testing.T) {
	var targetHits atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		targetHits.Add(1)
	}))
	defer target.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusTemporaryRedirect)
	}))
	defer redirect.Close()
	h, err := New(Config{GatewayURL: redirect.URL, QueryToken: "query", ProjectID: testProject})
	if err != nil {
		t.Fatal(err)
	}
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/services", nil))
	if rr.Code != http.StatusBadGateway || targetHits.Load() != 0 {
		t.Fatalf("redirect status=%d target_hits=%d body=%s", rr.Code, targetHits.Load(), rr.Body.String())
	}
}

func TestProxyEnforcesRequestAndUpstreamSizeLimits(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, envelope(`{"correlation":{"trace_id":"`+testTrace+`"}}`))
	}))
	defer server.Close()
	h := testHandler(t, server)
	body := `{"trace_id":"` + testTrace + `","limit":1,"padding":"` + strings.Repeat("x", MaxBodyBytes) + `"}`
	r := httptest.NewRequest(http.MethodPost, "/api/correlate", strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, r)
	if rr.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized request status=%d body=%s", rr.Code, rr.Body.String())
	}

	large := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"data":"`+strings.Repeat("x", MaxUpstreamBytes)+`"}`)
	}))
	defer large.Close()
	largeHandler := testHandler(t, large)
	rr = httptest.NewRecorder()
	largeHandler.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/services", nil))
	if rr.Code != http.StatusBadGateway || !strings.Contains(rr.Body.String(), "upstream_response_too_large") {
		t.Fatalf("oversized response status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestProxyTimeoutIsBoundedAndDoesNotLeakServerValues(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-time.After(250 * time.Millisecond):
			_, _ = io.WriteString(w, envelope(`{"services":["server-query-secret"]}`))
		case <-r.Context().Done():
		}
	}))
	defer server.Close()
	h := testHandler(t, server)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	r := httptest.NewRequest(http.MethodGet, "/api/services", nil).WithContext(ctx)
	rr := httptest.NewRecorder()
	start := time.Now()
	h.ServeHTTP(rr, r)
	if rr.Code != http.StatusGatewayTimeout {
		t.Fatalf("timeout status=%d body=%s", rr.Code, rr.Body.String())
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("timeout exceeded bound: %s", elapsed)
	}
	if strings.Contains(rr.Body.String(), "server-query-secret") || strings.Contains(rr.Body.String(), testProject) {
		t.Fatalf("server values leaked on timeout: %s", rr.Body.String())
	}
}

func TestNormalizeAllDashboardRoutesAndUnknownShapesFailSafe(t *testing.T) {
	services := Normalize("services", map[string]any{"data": map[string]any{"services": []any{"api", "worker"}}}, Scope{})
	if data, ok := services.Data.(ServicesData); !ok || !data.Supported || !reflect.DeepEqual(data.Services, []string{"api", "worker"}) {
		t.Fatalf("services view = %#v", services.Data)
	}
	contextView := Normalize("context", map[string]any{"data": map[string]any{"logs": []any{map[string]any{"message": "failure"}}, "metrics": []any{map[string]any{"value": "1"}}}}, Scope{})
	if data, ok := contextView.Data.(ContextData); !ok || !data.Supported || len(data.Logs) != 1 || len(data.Metrics) != 1 {
		t.Fatalf("context view = %#v", contextView.Data)
	}
	errorsView := Normalize("errors", map[string]any{"data": map[string]any{"logs": []any{map[string]any{"message": "failure"}}}}, Scope{})
	if data, ok := errorsView.Data.(ErrorsData); !ok || !data.Supported || len(data.Errors) != 1 {
		t.Fatalf("errors view = %#v", errorsView.Data)
	}
	correlation := Normalize("correlate", map[string]any{"data": map[string]any{"correlation": map[string]any{"trace_id": testTrace, "spans": []any{map[string]any{"spanID": "span-1"}}}}}, Scope{})
	if data, ok := correlation.Data.(CorrelationData); !ok || !data.Supported || len(data.Spans) != 1 {
		t.Fatalf("correlation view = %#v", correlation.Data)
	}
	for _, kind := range []string{"services", "context", "errors", "correlate"} {
		view := Normalize(kind, map[string]any{"data": map[string]any{"future": map[string]any{"secret": "query-secret"}}}, Scope{})
		switch data := view.Data.(type) {
		case ServicesData:
			if data.Supported {
				t.Fatalf("unknown services shape marked supported: %#v", data)
			}
		case ContextData:
			if data.Supported {
				t.Fatalf("unknown context shape marked supported: %#v", data)
			}
		case ErrorsData:
			if data.Supported {
				t.Fatalf("unknown errors shape marked supported: %#v", data)
			}
		case CorrelationData:
			if data.Supported {
				t.Fatalf("unknown correlate shape marked supported: %#v", data)
			}
		default:
			t.Fatalf("unexpected data type for %s: %T", kind, view.Data)
		}
	}
}

func TestNormalizeDistinguishesNoDataFromUnavailable(t *testing.T) {
	noData := Normalize("errors", map[string]any{
		"partial":       false,
		"content_trust": UntrustedTelemetry,
		"backends": []any{
			map[string]any{"name": "logs", "status": "no_matching_data"},
			map[string]any{"name": "traces", "status": "trace_not_stored"},
		},
		"data": map[string]any{"logs": []any{}},
	}, Scope{})
	if noData.Partial || noData.Backends[0].Status != "no_matching_data" || noData.Backends[1].Status != "trace_not_stored" {
		t.Fatalf("no-data semantics changed: %#v", noData)
	}
	unavailable := Normalize("errors", map[string]any{
		"partial":       true,
		"content_trust": UntrustedTelemetry,
		"backends":      []any{map[string]any{"name": "logs", "status": "backend_unavailable", "error": "backend down"}},
		"data":          map[string]any{"logs": []any{}},
	}, Scope{})
	if !unavailable.Partial || unavailable.Backends[0].Status != "backend_unavailable" || unavailable.ContentTrust != UntrustedTelemetry {
		t.Fatalf("unavailable semantics changed: %#v", unavailable)
	}
}

func TestNormalizeHealthyNoDataUsesTypedEmptyViews(t *testing.T) {
	cases := []struct {
		kind     string
		backends []any
		check    func(t *testing.T, data any)
	}{
		{
			kind: "context",
			backends: []any{
				map[string]any{"name": "logs", "status": "no_matching_data"},
				map[string]any{"name": "metrics", "status": "no_matching"},
			},
			check: func(t *testing.T, data any) {
				value, ok := data.(ContextData)
				if !ok || !value.Supported || len(value.Logs) != 0 || len(value.Metrics) != 0 {
					t.Fatalf("context no-data = %#v", data)
				}
			},
		},
		{
			kind: "errors",
			backends: []any{
				map[string]any{"name": "logs", "status": "no_matching"},
				map[string]any{"name": "traces", "status": "trace_not_stored"},
			},
			check: func(t *testing.T, data any) {
				value, ok := data.(ErrorsData)
				if !ok || !value.Supported || len(value.Errors) != 0 {
					t.Fatalf("errors no-data = %#v", data)
				}
			},
		},
		{
			kind: "correlate",
			backends: []any{
				map[string]any{"name": "traces", "status": "trace_not_stored"},
				map[string]any{"name": "logs", "status": "signal_not_observed"},
				map[string]any{"name": "metrics", "status": "no_matching_data"},
			},
			check: func(t *testing.T, data any) {
				value, ok := data.(CorrelationData)
				if !ok || !value.Supported || len(value.Spans) != 0 || len(value.Logs) != 0 || len(value.Metrics) != 0 {
					t.Fatalf("correlation no-data = %#v", data)
				}
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.kind, func(t *testing.T) {
			view := Normalize(tc.kind, map[string]any{
				"schema_version": "1.0",
				"partial":        false,
				"truncated":      false,
				"content_trust":  UntrustedTelemetry,
				"backends":       tc.backends,
				"data":           map[string]any{"items": []any{}},
			}, Scope{})
			if view.Partial {
				t.Fatal("healthy no-data view marked partial")
			}
			tc.check(t, view.Data)
		})
	}
}

func BenchmarkRedactView100Records(b *testing.B) {
	logs := make([]LogRecord, 100)
	for i := range logs {
		logs[i] = LogRecord{Service: "api", Message: "telemetry query-secret", Timestamp: "2026-08-24T00:00:00Z"}
	}
	view := View{Data: ContextData{Supported: true, Logs: logs}, Backends: []BackendStatus{{Name: "logs", Status: "ok"}}}
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = redactView(view, "query-secret")
	}
}

func BenchmarkNormalizeAdversarial(b *testing.B) {
	items := make([]any, maxNormalizedServices+1000)
	for i := range items {
		items[i] = "service-" + strconv.Itoa(i)
	}
	raw := map[string]any{"data": map[string]any{"services": items}, "backends": items}
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = Normalize("services", raw, Scope{})
	}
}

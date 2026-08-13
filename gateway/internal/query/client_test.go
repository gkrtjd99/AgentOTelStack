package query

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestDecodeBodyStrictNDJSON(t *testing.T) {
	v, err := decodeBody(strings.NewReader("{\"trace_id\":\"abc\"}\n{\"message\":\"ok\"}\n"))
	if err != nil || len(v.([]any)) != 2 {
		t.Fatalf("strict NDJSON decode: %#v %v", v, err)
	}
	if _, err := decodeBody(strings.NewReader("{\"ok\":true}\nnot-json\n")); err != ErrBackendDecode {
		t.Fatalf("expected backend_decode_error, got %v", err)
	}
}

func TestDecodeBodyVariantsAndBounds(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		wantErr    error
	}{
		{"empty", "", nil},
		{"json-array", `[{"message":"ok"}]`, nil},
		{"trailing-garbage", `{"ok":true} nope`, ErrBackendDecode},
		{"scalar", `true`, ErrBackendDecode},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := decodeBody(strings.NewReader(tc.body))
			if err != tc.wantErr {
				t.Fatalf("err=%v want %v", err, tc.wantErr)
			}
		})
	}
	if _, err := decodeBody(strings.NewReader(strings.Repeat("x", 2<<20+1))); err != ErrBackendDecode {
		t.Fatalf("oversize err=%v", err)
	}
}

func TestLogsQueryUsesAbsoluteWindowAndOmitsEmptyService(t *testing.T) {
	var got url.Values
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.URL.Query()
		fmt.Fprint(w, `[{"message":"ok"}]`)
	}))
	defer s.Close()
	c := Client{Logs: s.URL}
	start := time.Unix(1700000000, 0)
	end := time.Unix(1700000060, 0)
	if _, err := c.LogsQueryScoped(tContext(), "", "proj", start, end, 25); err != nil {
		t.Fatal(err)
	}
	if got.Get("query") != `project:"proj"` {
		t.Fatalf("query = %q", got.Get("query"))
	}
	if got.Get("start") != "2023-11-14T22:13:20Z" || got.Get("end") != "2023-11-14T22:14:20Z" || got.Get("limit") != "25" {
		t.Fatalf("window params = %#v", got)
	}
}

func TestLogsErrorsAndTracesCarryErrorAndScopePredicates(t *testing.T) {
	var logQuery url.Values
	var traceQuery url.Values
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/select/logsql/query":
			logQuery = r.URL.Query()
			fmt.Fprint(w, `[{"severity_text":"error"}]`)
		case "/select/jaeger/api/traces":
			traceQuery = r.URL.Query()
			fmt.Fprint(w, `{"data":[]}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer s.Close()
	c := Client{Logs: s.URL, Traces: s.URL}
	start, end := time.Unix(1700000000, 0), time.Unix(1700000060, 0)
	project := "123e4567-e89b-42d3-a456-426614174000"
	if _, err := c.LogsErrorsScoped(tContext(), "checkout", project, start, end, 25); err != nil {
		t.Fatal(err)
	}
	if got := logQuery.Get("query"); got != `severity_text:"error" service.name:"checkout" project:"123e4567-e89b-42d3-a456-426614174000"` {
		t.Fatalf("error log query = %q", got)
	}
	if _, err := c.TracesQueryScoped(tContext(), "checkout", project, 25); err != nil {
		t.Fatal(err)
	}
	var tags map[string]string
	if err := json.Unmarshal([]byte(traceQuery.Get("tags")), &tags); err != nil {
		t.Fatalf("error trace tags are not JSON: %v", err)
	}
	if tags["error"] != "true" || tags["resource_attr:project"] != project {
		t.Fatalf("error trace tags = %#v", tags)
	}
}

func TestMetricsQueryScopedEscapesAndFiltersProject(t *testing.T) {
	var gotPath string
	var got url.Values
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		got = r.URL.Query()
		fmt.Fprint(w, `{"status":"success","data":{"resultType":"vector","result":[{"metric":{"service_name":"api"},"value":[1700000060,"1"]}]}}`)
	}))
	defer s.Close()
	if _, err := (Client{Metrics: s.URL}).MetricsQueryScoped(tContext(), "api", "project\"\\name", time.Unix(1700000000, 0), time.Unix(1700000060, 0), time.Second); err != nil {
		t.Fatal(err)
	}
	want := `project="project\"\\name"`
	if gotPath != "/api/v1/query" {
		t.Fatalf("metrics path = %q, want instant query", gotPath)
	}
	if got.Get("time") != "1700000060" || got.Get("start") != "" || got.Get("end") != "" || got.Get("step") != "" {
		t.Fatalf("instant query params = %#v", got)
	}
	if !strings.Contains(got.Get("query"), want) {
		t.Fatalf("project selector = %q, want escaped %q", got.Get("query"), want)
	}
}

func TestBackendQueriesDoNotFollowRedirects(t *testing.T) {
	var targetHits int
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		targetHits++
		fmt.Fprint(w, `[{"message":"redirect target"}]`)
	}))
	defer target.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusTemporaryRedirect)
	}))
	defer redirect.Close()
	if _, err := (Client{Logs: redirect.URL}).LogsQuery(tContext(), "api", time.Unix(1700000000, 0), time.Unix(1700000060, 0), 10); err == nil {
		t.Fatal("redirect response accepted")
	}
	if targetHits != 0 {
		t.Fatalf("redirect target received query: %d hits", targetHits)
	}
}

func TestLogsTraceUsesFixedTraceQueryAndAbsoluteWindow(t *testing.T) {
	var got url.Values
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.URL.Query()
		fmt.Fprint(w, `[{"trace_id":"abc"}]`)
	}))
	defer s.Close()
	if _, err := (Client{Logs: s.URL}).LogsTrace(tContext(), "abc", time.Unix(1700000000, 0), time.Unix(1700000060, 0), 10); err != nil {
		t.Fatal(err)
	}
	if got.Get("query") != "trace_id:abc" || got.Get("start") != "2023-11-14T22:13:20Z" || got.Get("end") != "2023-11-14T22:14:20Z" {
		t.Fatalf("request params = %#v", got)
	}
}

func TestCorrelateScopedLogsAndMetricsCarryProject(t *testing.T) {
	var logQuery, metricsQuery string
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/select/logsql/query":
			logQuery = r.URL.Query().Get("query")
			fmt.Fprint(w, `[{"trace_id":"abc"}]`)
		case "/api/v1/query":
			metricsQuery = r.URL.Query().Get("query")
			fmt.Fprint(w, `{"status":"success","data":{"resultType":"vector","result":[{"metric":{"service_name":"api"},"value":[1700000060,"1"]}]}}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer s.Close()
	project := "123e4567-e89b-42d3-a456-426614174000"
	start, end := time.Unix(1700000000, 0), time.Unix(1700000060, 0)
	c := Client{Logs: s.URL, Metrics: s.URL}
	if _, err := c.LogsTraceScoped(tContext(), "0123456789abcdef0123456789abcdef", project, start, end, 10); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(logQuery, `project:"`+project+`"`) {
		t.Fatalf("scoped log query = %q", logQuery)
	}
	if _, err := c.MetricsTraceScoped(tContext(), []string{"api"}, project, start, end, time.Second); err != nil {
		t.Fatal(err)
	}
	want := `project="` + project + `"`
	if !strings.Contains(metricsQuery, want) {
		t.Fatalf("scoped metrics query = %q, want %q", metricsQuery, want)
	}
}

func TestTrace404IsNotStored(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Error(w, "not found", http.StatusNotFound) }))
	defer s.Close()
	if _, err := (Client{Traces: s.URL}).TraceQuery(context.Background(), "0123456789abcdef0123456789abcdef"); err != ErrTraceNotStored {
		t.Fatalf("err=%v", err)
	}
}

func TestTraceQueryScopedFiltersMixedProjectProcessesAndSpans(t *testing.T) {
	id := "0123456789abcdef0123456789abcdef"
	fixture := `{"data":[{"spans":[{"spanID":"a-root","operationName":"root","startTime":1000000,"duration":1000,"processID":"p-a"},{"spanID":"a-child","operationName":"child","startTime":1001000,"duration":100,"processID":"p-a","references":[{"refType":"CHILD_OF","spanID":"a-root"}]},{"spanID":"b-root","operationName":"other","startTime":1000000,"duration":1000,"processID":"p-b"}],"processes":{"p-a":{"serviceName":"api","tags":[{"key":"project","value":"123e4567-e89b-42d3-a456-426614174000"}]},"p-b":{"serviceName":"worker","tags":[{"key":"project","value":"223e4567-e89b-42d3-a456-426614174000"}]}}}]}`
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/select/jaeger/api/traces/"+id {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(fixture))
	}))
	defer s.Close()
	c := Client{Traces: s.URL}
	raw, err := c.TraceQueryScoped(tContext(), id, "123e4567-e89b-42d3-a456-426614174000")
	if err != nil {
		t.Fatal(err)
	}
	root := raw.(map[string]any)["data"].([]any)[0].(map[string]any)
	spans := root["spans"].([]any)
	if len(spans) != 2 {
		t.Fatalf("scoped spans = %d, want 2: %#v", len(spans), spans)
	}
	processes := root["processes"].(map[string]any)
	if len(processes) != 1 || processes["p-a"] == nil || processes["p-b"] != nil {
		t.Fatalf("scoped processes = %#v", processes)
	}
	if _, err := c.TraceQueryScoped(tContext(), id, "323e4567-e89b-42d3-a456-426614174000"); err != ErrNoData {
		t.Fatalf("wrong project err = %v, want ErrNoData", err)
	}
}

func TestValidateMetricsPrometheusShapes(t *testing.T) {
	valid := []string{
		`{"status":"success","data":{"resultType":"matrix","result":[]}}`,
		`{"status":"success","data":{"resultType":"matrix","result":[{"metric":{"service_name":"app"},"values":[[1,"2"]]}]}}`,
		`{"status":"success","data":{"resultType":"vector","result":[]}}`,
		`{"status":"success","data":{"resultType":"scalar","result":[1,"2"]}}`,
	}
	for _, body := range valid {
		v, err := decodeBody(strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		err = validateMetrics(v)
		if strings.Contains(body, `"result":[]`) {
			if err != ErrNoData {
				t.Fatalf("empty result: %v", err)
			}
		} else if err != nil {
			t.Fatalf("valid shape: %v", err)
		}
		_ = v
	}
	for _, body := range []string{
		`{"status":"error","error":"bad_data","data":{}}`,
		`{"status":"success","data":{"resultType":"matrix"}}`,
		`{"status":"success","data":{"resultType":"unknown","result":[]}}`,
		`{"status":"success","data":{"resultType":"matrix","result":{}}}`,
	} {
		v, _ := decodeBody(strings.NewReader(body))
		if err := validateMetrics(v); err == nil {
			t.Fatalf("accepted malformed/error response %s", body)
		}
	}
}

func tContext() context.Context { return context.Background() }

package query

import (
	"context"
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

func TestTrace404IsNotStored(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Error(w, "not found", http.StatusNotFound) }))
	defer s.Close()
	if _, err := (Client{Traces: s.URL}).TraceQuery(context.Background(), "0123456789abcdef0123456789abcdef"); err != ErrTraceNotStored {
		t.Fatalf("err=%v", err)
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

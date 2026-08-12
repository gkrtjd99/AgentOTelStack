package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDecodeAndIDs(t *testing.T) {
	for _, tc := range []struct {
		in string
		ok bool
	}{
		{`{"jsonrpc":"2.0","id":1,"method":"ping"}`, true},
		{`{"jsonrpc":"2.0","id":"x","method":"ping"}`, true},
		{`{"jsonrpc":"2.0","id":true,"method":"ping"}`, true}, // validID is checked by the protocol loop
		{`{"jsonrpc":"2.0","id":1,"method":"ping"} trailing`, false},
		{`{"jsonrpc":"2.0","id":1,"method":"ping","extra":1}`, false},
	} {
		var q request
		if got := decode([]byte(tc.in), &q) == nil; got != tc.ok {
			t.Errorf("decode %q: got %v", tc.in, got)
		}
	}
	if !validID(json.RawMessage(`null`)) || validID(json.RawMessage(`true`)) {
		t.Fatal("invalid id handling")
	}
}

func TestHandleProtocolAndNotifications(t *testing.T) {
	initialized = false
	if got := handle(request{JSONRPC: "2.0", ID: json.RawMessage("1"), Method: "tools/list"}); got.Error.Code != -32600 {
		t.Fatal(got)
	}
	if got := handle(request{JSONRPC: "2.0", ID: json.RawMessage("1"), Method: "nope"}); got.Error.Code != -32601 {
		t.Fatal(got)
	}
	if got := handle(request{JSONRPC: "2.0", ID: json.RawMessage("1"), Method: "initialize"}); got.Result == nil {
		t.Fatal("initialize result missing")
	}
	initialized = true // main consumes notifications before calling handle
	if got := handle(request{JSONRPC: "2.0", ID: json.RawMessage("1"), Method: "tools/list"}); got.Error != nil {
		t.Fatal(got)
	}
	if got := handle(request{JSONRPC: "2.0", ID: json.RawMessage("1"), Method: "tools/call", Params: json.RawMessage(`{"name":"agentotel_services","arguments":{}}`)}); got.Result == nil {
		t.Fatal("call result missing")
	}
}

func TestToolSchemasExactShape(t *testing.T) {
	ts := tools()
	if len(ts) != 3 {
		t.Fatal(len(ts))
	}
	for _, x := range ts {
		s := x["inputSchema"].(map[string]any)
		if s["type"] != "object" || s["additionalProperties"] != false {
			t.Fatalf("bad schema %#v", s)
		}
	}
	if ts[0]["name"] != "agentotel_context" || ts[1]["name"] != "agentotel_correlate" || ts[2]["name"] != "agentotel_services" {
		t.Fatal("tool names")
	}
}

func TestStrictArguments(t *testing.T) {
	for _, raw := range []string{`null`, `{}`, `{"service":"ok","limit":1.2}`, `{"service":"ok","unknown":1}`, `{"service":"bad space"}`, `{"service":"ok","lookback":"2m"}`, `{"service":"ok","limit":501}`, `{"service":"ok","project":"not-uuid"}`} {
		var a contextArgs
		if raw == `{}` {
			continue
		}
		if err := strict(json.RawMessage(raw), &a); err == nil && validateContext(a) == nil {
			t.Errorf("accepted %s", raw)
		}
	}
	for _, id := range []string{"ABCDEF00000000000000000000000000", "short", strings.Repeat("a", 31)} {
		r := call(json.RawMessage(`{"name":"agentotel_correlate","arguments":{"trace_id":"` + id + `"}}`))
		if !r.IsError {
			t.Errorf("accepted trace %s", id)
		}
	}
	if !call(json.RawMessage(`{"name":"agentotel_services","arguments":{"x":1}}`)).IsError {
		t.Fatal("unknown service args")
	}
}

func TestCredentialsPrecedenceAndSecurity(t *testing.T) {
	d := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", d)
	dir := filepath.Join(d, "agentotel")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	write := func(p, s string, mode os.FileMode) {
		if err := os.WriteFile(p, []byte(s), mode); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(dir, "credentials"), `{"ingest_token":"ingest-token","query_token":" json-token ","grafana_admin_password":"grafana-token"}`, 0600)
	write(filepath.Join(dir, "query.token"), "raw-token", 0600)
	if got, _ := cred(); got != "json-token" {
		t.Fatal(got)
	}
	if err := os.WriteFile(filepath.Join(dir, "credentials"), []byte("bad"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := cred(); err == nil {
		t.Fatal("fell back from invalid primary")
	}
	os.Remove(filepath.Join(dir, "credentials"))
	if got, _ := cred(); got != "raw-token" {
		t.Fatal(got)
	}
	os.Chmod(filepath.Join(dir, "query.token"), 0644)
	if _, err := cred(); err == nil {
		t.Fatal("accepted mode")
	}
}

func TestCredentialsStoreValidation(t *testing.T) {
	tests := []struct {
		name string
		data string
		want string
	}{
		{
			name: "generated store",
			data: `{"ingest_token":"ingest-token","query_token":"query-token","grafana_admin_password":"grafana-token"}`,
			want: "query-token",
		},
		{
			name: "missing query token",
			data: `{"ingest_token":"ingest-token","grafana_admin_password":"grafana-token"}`,
		},
		{
			name: "empty query token",
			data: `{"ingest_token":"ingest-token","query_token":"  ","grafana_admin_password":"grafana-token"}`,
		},
		{
			name: "unknown field",
			data: `{"ingest_token":"ingest-token","query_token":"query-token","grafana_admin_password":"grafana-token","unexpected":"value"}`,
		},
		{
			name: "malformed json",
			data: `{"ingest_token":"ingest-token","query_token":`,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			d := t.TempDir()
			t.Setenv("XDG_CONFIG_HOME", d)
			dir := filepath.Join(d, "agentotel")
			if err := os.Mkdir(dir, 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, "credentials"), []byte(tc.data), 0600); err != nil {
				t.Fatal(err)
			}
			got, err := cred()
			if tc.want == "" {
				if err == nil {
					t.Fatalf("accepted invalid credentials and returned %q", got)
				}
				return
			}
			if err != nil || got != tc.want {
				t.Fatalf("cred() = %q, %v; want %q", got, err, tc.want)
			}
		})
	}
}

func TestCredentialsStoreSymlinkAndMode(t *testing.T) {
	d := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", d)
	dir := filepath.Join(d, "agentotel")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	valid := []byte(`{"ingest_token":"ingest-token","query_token":"query-token","grafana_admin_password":"grafana-token"}`)
	t.Run("symlink", func(t *testing.T) {
		target := filepath.Join(d, "target-credentials")
		if err := os.WriteFile(target, valid, 0600); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(dir, "credentials")
		if err := os.Symlink(target, path); err != nil {
			t.Fatal(err)
		}
		if _, err := cred(); err == nil {
			t.Fatal("accepted credential symlink")
		}
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("mode", func(t *testing.T) {
		path := filepath.Join(dir, "credentials")
		if err := os.WriteFile(path, valid, 0644); err != nil {
			t.Fatal(err)
		}
		if _, err := cred(); err == nil {
			t.Fatal("accepted credentials with permissive mode")
		}
	})
}

func TestGatewayRequestAndResponses(t *testing.T) {
	var got *http.Request
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"ok":true}`)
	}))
	defer ts.Close()
	gatewayBaseURL, gatewayHTTPClient = ts.URL, ts.Client()
	defer func() { gatewayBaseURL = "http://127.0.0.1:17777"; gatewayHTTPClient = http.DefaultClient }()
	d := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", d)
	os.Mkdir(filepath.Join(d, "agentotel"), 0700)
	os.WriteFile(filepath.Join(d, "agentotel", "query.token"), []byte("secret"), 0600)
	r := gateway("agentotel_context", "svc", "550e8400-e29b-41d4-a716-446655440000", "15m", 7)
	if r.IsError || r.StructuredContent["ok"] != true {
		t.Fatal(r)
	}
	if got.URL.Path != "/v1/context" || got.URL.Query().Get("service") != "svc" || got.URL.Query().Get("limit") != "7" || got.Header.Get("Authorization") != "Bearer secret" {
		t.Fatalf("request %#v", got)
	}
}

func TestGatewayFailuresAndLimits(t *testing.T) {
	for _, status := range []int{401, 500} {
		ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(status) }))
		gatewayBaseURL, gatewayHTTPClient = ts.URL, ts.Client()
		t.Setenv("XDG_CONFIG_HOME", t.TempDir())
		d := os.Getenv("XDG_CONFIG_HOME")
		os.Mkdir(filepath.Join(d, "agentotel"), 0700)
		os.WriteFile(filepath.Join(d, "agentotel", "query.token"), []byte("x"), 0600)
		if !gateway("agentotel_services", "", "", "", 0).IsError {
			t.Fatal(status)
		}
		ts.Close()
	}
}

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const maxBody = 2 << 20

var traceRE = regexp.MustCompile(`^[0-9a-f]{32}$`)
var serviceRE = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)
var uuidRE = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$`)

type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}
type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}
type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}
type callResult struct {
	Content           []map[string]string `json:"content"`
	StructuredContent map[string]any      `json:"structuredContent,omitempty"`
	IsError           bool                `json:"isError,omitempty"`
}

var initialized bool
var gatewayBaseURL = "http://127.0.0.1:17777"
var gatewayHTTPClient = http.DefaultClient

func main() {
	s := bufio.NewScanner(os.Stdin)
	s.Buffer(make([]byte, 4096), 4<<20)
	for s.Scan() {
		b := s.Bytes()
		var raw any
		if json.Unmarshal(b, &raw) != nil {
			write(response{JSONRPC: "2.0", Error: &rpcError{-32700, "parse error"}})
			continue
		}
		if _, ok := raw.([]any); ok {
			write(response{JSONRPC: "2.0", Error: &rpcError{-32600, "invalid request"}})
			continue
		}
		var q request
		if err := decode(b, &q); err != nil || q.JSONRPC != "2.0" || q.Method == "" || (q.ID != nil && !validID(q.ID)) {
			write(response{JSONRPC: "2.0", ID: nil, Error: &rpcError{-32600, "invalid request"}})
			continue
		}
		if q.Method == "notifications/initialized" {
			initialized = true
			continue
		}
		if q.ID == nil {
			continue
		}
		write(handle(q))
	}
}
func decode(b []byte, v any) error {
	d := json.NewDecoder(strings.NewReader(string(b)))
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return err
	}
	var x any
	return func() error {
		if d.Decode(&x) != io.EOF {
			return errors.New("trailing data")
		}
		return nil
	}()
}
func validID(b json.RawMessage) bool {
	var x any
	if json.Unmarshal(b, &x) != nil {
		return false
	}
	return x == nil || func() bool {
		switch x.(type) {
		case string, float64:
			return true
		}
		return false
	}()
}
func write(v response) { b, _ := json.Marshal(v); os.Stdout.Write(append(b, '\n')) }
func handle(q request) response {
	r := response{JSONRPC: "2.0", ID: q.ID}
	switch q.Method {
	case "initialize":
		r.Result = map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{"tools": map[string]any{}}, "serverInfo": map[string]any{"name": "agentotel-mcp", "version": "2.0.0"}}
	case "ping":
		r.Result = map[string]any{}
	case "tools/list":
		if !initialized {
			return errResp(r, -32600, "not initialized")
		}
		r.Result = map[string]any{"tools": tools()}
	case "tools/call":
		if !initialized {
			return errResp(r, -32600, "not initialized")
		}
		var p map[string]json.RawMessage
		if err := strict(q.Params, &p); err != nil {
			return errResp(r, -32602, "invalid params")
		}
		r.Result = call(q.Params)
	default:
		return errResp(r, -32601, "method not found")
	}
	return r
}
func errResp(r response, c int, m string) response { r.Error = &rpcError{c, m}; return r }
func tools() []map[string]any {
	return []map[string]any{{"name": "agentotel_context", "description": "Read service telemetry context", "inputSchema": map[string]any{"type": "object", "required": []string{"service"}, "additionalProperties": false, "properties": map[string]any{"service": map[string]any{"type": "string"}, "project": map[string]any{"type": "string", "format": "uuid"}, "lookback": map[string]any{"type": "string", "enum": []string{"5m", "15m", "1h", "6h", "24h"}}, "limit": map[string]any{"type": "integer", "minimum": 1, "maximum": 500}}}}, {"name": "agentotel_correlate", "description": "Read a trace correlation", "inputSchema": map[string]any{"type": "object", "required": []string{"trace_id"}, "additionalProperties": false, "properties": map[string]any{"trace_id": map[string]any{"type": "string", "pattern": "^[0-9a-f]{32}$"}, "project": map[string]any{"type": "string", "format": "uuid"}, "limit": map[string]any{"type": "integer", "minimum": 1, "maximum": 500}}}}, {"name": "agentotel_services", "description": "List observed services", "inputSchema": map[string]any{"type": "object", "additionalProperties": false}}}
}

type contextArgs struct {
	Service  string `json:"service"`
	Project  string `json:"project,omitempty"`
	Lookback string `json:"lookback,omitempty"`
	Limit    int    `json:"limit,omitempty"`
}
type correlateArgs struct {
	TraceID string `json:"trace_id"`
	Project string `json:"project,omitempty"`
	Limit   int    `json:"limit,omitempty"`
}

func strict(raw json.RawMessage, v any) error {
	if len(raw) == 0 || string(raw) == "null" {
		return errors.New("invalid arguments")
	}
	d := json.NewDecoder(strings.NewReader(string(raw)))
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return errors.New("invalid arguments")
	}
	var x any
	if d.Decode(&x) != io.EOF {
		return errors.New("invalid arguments")
	}
	return nil
}
func call(raw json.RawMessage) callResult {
	var c struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := strict(raw, &c); err != nil {
		return fail(err.Error())
	}
	if c.Name == "agentotel_context" {
		var a contextArgs
		if err := strict(c.Arguments, &a); err != nil {
			return fail("invalid arguments")
		}
		if err := validateContext(a); err != nil {
			return fail(err.Error())
		}
		return gateway(c.Name, a.Service, a.Project, a.Lookback, a.Limit)
	}
	if c.Name == "agentotel_correlate" {
		var a correlateArgs
		if err := strict(c.Arguments, &a); err != nil {
			return fail(err.Error())
		}
		if !traceRE.MatchString(a.TraceID) || (a.Project != "" && !uuidRE.MatchString(a.Project)) || a.Limit < 0 || a.Limit > 500 {
			return fail("invalid arguments")
		}
		return gateway(c.Name, a.TraceID, a.Project, "", a.Limit)
	}
	if c.Name == "agentotel_services" {
		var a map[string]any
		if err := strict(c.Arguments, &a); err != nil || len(a) > 0 {
			return fail("invalid arguments")
		}
		return gateway(c.Name, "", "", "", 0)
	}
	return fail("unknown tool")
}
func validateContext(a contextArgs) error {
	if !serviceRE.MatchString(a.Service) || (a.Project != "" && !uuidRE.MatchString(a.Project)) || (a.Lookback != "" && !map[string]bool{"5m": true, "15m": true, "1h": true, "6h": true, "24h": true}[a.Lookback]) || a.Limit < 0 || a.Limit > 500 {
		return errors.New("invalid arguments")
	}
	return nil
}
func fail(s string) callResult {
	return callResult{Content: []map[string]string{{"type": "text", "text": s}}, IsError: true}
}
func gateway(name, a, p, l string, n int) callResult {
	path := "/v1/" + strings.TrimPrefix(name, "agentotel_")
	q := url.Values{}
	for k, v := range map[string]string{"service": a, "project": p, "lookback": l} {
		if v != "" {
			q.Set(k, v)
		}
	}
	if n > 0 {
		q.Set("limit", fmt.Sprint(n))
	}
	b, e := get(path, q.Encode())
	if e != nil {
		return fail(e.Error())
	}
	var obj map[string]any
	if json.Unmarshal(b, &obj) != nil || obj == nil {
		return fail("invalid gateway response")
	}
	return callResult{Content: []map[string]string{{"type": "text", "text": string(b)}}, StructuredContent: obj}
}
func get(path, q string) ([]byte, error) {
	t, e := cred()
	if e != nil {
		return nil, errors.New("credentials unavailable")
	}
	u := strings.TrimRight(gatewayBaseURL, "/") + path
	if q != "" {
		u += "?" + q
	}
	ctx, c := context.WithTimeout(context.Background(), 5*time.Second)
	defer c()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	req.Header.Set("Authorization", "Bearer "+t)
	resp, e := gatewayHTTPClient.Do(req)
	if e != nil {
		return nil, errors.New("gateway unavailable")
	}
	defer resp.Body.Close()
	b, e := io.ReadAll(io.LimitReader(resp.Body, maxBody+1))
	if e != nil || len(b) > maxBody {
		return nil, errors.New("gateway response too large")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("gateway status %d", resp.StatusCode)
	}
	return b, nil
}
func cred() (string, error) {
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		h, e := os.UserHomeDir()
		if e != nil {
			return "", e
		}
		base = filepath.Join(h, ".config")
	}
	dir := filepath.Join(base, "agentotel")
	ds, de := os.Lstat(dir)
	if de == nil && (ds.Mode()&os.ModeSymlink != 0 || !ds.IsDir() || ds.Mode().Perm()&0077 != 0) {
		return "", errors.New("invalid credentials")
	}
	p := filepath.Join(dir, "credentials")
	if _, e := os.Lstat(p); os.IsNotExist(e) {
		p = filepath.Join(dir, "query.token")
	}
	st, e := os.Lstat(p)
	if e != nil || st.Mode()&os.ModeSymlink != 0 || !st.Mode().IsRegular() || st.Mode().Perm() != 0600 {
		return "", errors.New("invalid credentials")
	}
	b, e := os.ReadFile(p)
	if e != nil {
		return "", e
	}
	if strings.HasSuffix(p, "credentials") {
		var j map[string]string
		if json.Unmarshal(b, &j) != nil || len(j) != 3 {
			return "", errors.New("invalid credentials")
		}
		if _, ok := j["ingest_token"]; !ok {
			return "", errors.New("invalid credentials")
		}
		if _, ok := j["grafana_admin_password"]; !ok {
			return "", errors.New("invalid credentials")
		}
		t := strings.TrimSpace(j["query_token"])
		if t == "" || strings.ContainsAny(t, "\r\n") {
			return "", errors.New("invalid credentials")
		}
		return t, nil
	}
	t := strings.TrimSpace(string(b))
	if t == "" || strings.ContainsAny(t, "\r\n") {
		return "", errors.New("invalid credentials")
	}
	return t, nil
}

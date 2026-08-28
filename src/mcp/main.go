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
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const maxBody = 2 << 20

var traceRE = regexp.MustCompile(`^[0-9a-f]{32}$`)
var serviceRE = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)
var uuidRE = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

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
var buildVersion = "dev"
var workspaceProject string
var workspaceProjectErr error

func main() {
	if err := initWorkspaceProject(); err != nil {
		fmt.Fprintln(os.Stderr, "agentotel-mcp:", err)
		os.Exit(2)
	}
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
		r.Result = map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{"tools": map[string]any{}}, "serverInfo": map[string]any{"name": "agentotel-mcp", "version": buildVersion}}
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
	return []map[string]any{{"name": "agentotel_context", "description": "Read service telemetry context for this workspace", "inputSchema": map[string]any{"type": "object", "required": []string{"service"}, "additionalProperties": false, "properties": map[string]any{"service": map[string]any{"type": "string"}, "lookback": map[string]any{"type": "string", "enum": []string{"5m", "15m", "1h", "6h", "24h"}}, "limit": map[string]any{"type": "integer", "minimum": 1, "maximum": 500}}}}, {"name": "agentotel_correlate", "description": "Read a trace correlation for this workspace", "inputSchema": map[string]any{"type": "object", "required": []string{"trace_id"}, "additionalProperties": false, "properties": map[string]any{"trace_id": map[string]any{"type": "string", "pattern": "^[0-9a-f]{32}$"}, "limit": map[string]any{"type": "integer", "minimum": 1, "maximum": 500}}}}, {"name": "agentotel_services", "description": "List observed services for this workspace", "inputSchema": map[string]any{"type": "object", "additionalProperties": false}}}
}

type contextArgs struct {
	Service  string `json:"service"`
	Lookback string `json:"lookback,omitempty"`
	Limit    int    `json:"limit,omitempty"`
}
type correlateArgs struct {
	TraceID string `json:"trace_id"`
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
	if err := initWorkspaceProject(); err != nil {
		return fail("workspace project unavailable")
	}
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
		return contextCall(a)
	}
	if c.Name == "agentotel_correlate" {
		var a correlateArgs
		if err := strict(c.Arguments, &a); err != nil {
			return fail(err.Error())
		}
		if !traceRE.MatchString(a.TraceID) || a.Limit < 0 || a.Limit > 500 {
			return fail("invalid arguments")
		}
		return correlateCall(a)
	}
	if c.Name == "agentotel_services" {
		var a map[string]any
		if err := strict(c.Arguments, &a); err != nil || len(a) > 0 {
			return fail("invalid arguments")
		}
		return servicesCall()
	}
	return fail("unknown tool")
}
func validateContext(a contextArgs) error {
	if !serviceRE.MatchString(a.Service) || (a.Lookback != "" && !map[string]bool{"5m": true, "15m": true, "1h": true, "6h": true, "24h": true}[a.Lookback]) || a.Limit < 0 || a.Limit > 500 {
		return errors.New("invalid arguments")
	}
	return nil
}
func fail(s string) callResult {
	return callResult{Content: []map[string]string{{"type": "text", "text": s}}, IsError: true}
}
func contextCall(a contextArgs) callResult {
	q := url.Values{"service": []string{a.Service}}
	addWorkspaceProject(q)
	if a.Lookback != "" {
		q.Set("lookback", a.Lookback)
	}
	if a.Limit > 0 {
		q.Set("limit", strconv.Itoa(a.Limit))
	}
	return callGateway("/v1/context", q)
}

func correlateCall(a correlateArgs) callResult {
	q := url.Values{"trace_id": []string{a.TraceID}}
	addWorkspaceProject(q)
	if a.Limit > 0 {
		q.Set("limit", strconv.Itoa(a.Limit))
	}
	return callGateway("/v1/correlate", q)
}

func servicesCall() callResult {
	q := url.Values{}
	addWorkspaceProject(q)
	return callGateway("/v1/services", q)
}

func addWorkspaceProject(q url.Values) {
	if workspaceProjectErr == nil && workspaceProject != "" {
		q.Set("project", workspaceProject)
	}
}

func callGateway(path string, q url.Values) callResult {
	if workspaceProjectErr != nil || workspaceProject == "" {
		return fail("workspace project unavailable")
	}
	b, e := get(path, q.Encode())
	if e != nil {
		return fail(e.Error())
	}
	var obj map[string]any
	if json.Unmarshal(b, &obj) != nil || obj == nil {
		return fail("invalid gateway response")
	}
	return callResult{Content: []map[string]string{{"type": "text", "text": summarize(obj)}}, StructuredContent: obj}
}

func summarize(obj map[string]any) string {
	partial, _ := obj["partial"].(bool)
	spans := countArrays(obj, "spans")
	failures := countArrays(obj, "failures")
	items := countArrays(obj, "items")
	if spans > 0 || failures > 0 {
		return fmt.Sprintf("correlation complete: spans=%d failures=%d partial=%t", spans, failures, partial)
	}
	if items > 0 {
		return fmt.Sprintf("telemetry response: items=%d partial=%t", items, partial)
	}
	return fmt.Sprintf("telemetry response: partial=%t", partial)
}

func countArrays(v any, key string) int {
	count := 0
	switch x := v.(type) {
	case map[string]any:
		for k, value := range x {
			if k == key {
				if values, ok := value.([]any); ok {
					count += len(values)
				}
			}
			count += countArrays(value, key)
		}
	case []any:
		for _, value := range x {
			count += countArrays(value, key)
		}
	}
	return count
}

func initWorkspaceProject() error {
	if workspaceProject != "" || workspaceProjectErr != nil {
		return workspaceProjectErr
	}
	if id := os.Getenv("AGENTOTEL_PROJECT_ID"); id != "" {
		if !uuidRE.MatchString(id) {
			workspaceProjectErr = errors.New("invalid AGENTOTEL_PROJECT_ID")
			return workspaceProjectErr
		}
		workspaceProject = id
		return nil
	}
	root, err := gitRoot()
	if err != nil {
		workspaceProjectErr = errors.New("not in a git workspace")
		return workspaceProjectErr
	}
	id, err := readWorkspaceProject(root)
	if err != nil {
		workspaceProjectErr = err
		return err
	}
	workspaceProject = id
	return nil
}

func gitRoot() (string, error) {
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return "", err
	}
	root := strings.TrimSpace(string(out))
	if root == "" || filepath.IsAbs(root) == false {
		return "", errors.New("invalid git root")
	}
	return root, nil
}

func readWorkspaceProject(root string) (string, error) {
	path := filepath.Join(root, ".agentotel", "project.toml")
	st, err := os.Lstat(path)
	if err != nil || st.Mode()&os.ModeSymlink != 0 || !st.Mode().IsRegular() {
		return "", errors.New("project is not initialized")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", errors.New("project is not readable")
	}
	var schema, id string
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		switch {
		case strings.HasPrefix(line, "schema = "):
			if schema != "" || line != "schema = 1" {
				return "", errors.New("invalid project.toml")
			}
			schema = "1"
		case strings.HasPrefix(line, "project_id = "):
			if id != "" || len(line) < len("project_id = \"\"")+1 || line[len(line)-1] != '"' || !strings.HasPrefix(line, "project_id = \"") {
				return "", errors.New("invalid project.toml")
			}
			id = strings.TrimSuffix(strings.TrimPrefix(line, "project_id = \""), "\"")
		default:
			return "", errors.New("invalid project.toml")
		}
	}
	if schema != "1" || !uuidRE.MatchString(id) {
		return "", errors.New("invalid project.toml")
	}
	return id, nil
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
		if json.Unmarshal(b, &j) != nil || len(j) != 2 {
			return "", errors.New("invalid credentials")
		}
		i, iok := j["ingest_token"]
		q, qok := j["query_token"]
		if !iok || !qok || strings.TrimSpace(i) == "" || strings.ContainsAny(i, "\r\n") {
			return "", errors.New("invalid credentials")
		}
		t := strings.TrimSpace(q)
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

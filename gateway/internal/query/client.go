package query

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var (
	ErrBackendDecode   = fmt.Errorf("backend_decode_error")
	ErrTraceNotStored  = fmt.Errorf("trace_not_stored")
	ErrNoData          = fmt.Errorf("no_matching_data")
	ErrBackendResponse = fmt.Errorf("backend_error")
)

type Client struct {
	Logs, Metrics, Traces string
	HTTP                  *http.Client
}

func (c Client) client() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return &http.Client{Timeout: 8 * time.Second}
}
func decodeBody(r io.Reader) (any, error) {
	// VictoriaLogs returns either a JSON value or newline-delimited JSON
	// records (often with a streaming content type). Decode incrementally so a
	// truncated/malformed tail cannot be mistaken for a successful response.
	b, err := io.ReadAll(io.LimitReader(r, 2<<20+1))
	if err != nil {
		return nil, err
	}
	if len(b) > 2<<20 {
		return nil, ErrBackendDecode
	}
	dec := json.NewDecoder(strings.NewReader(string(b)))
	var first any
	if err := dec.Decode(&first); err != nil {
		if err == io.EOF {
			return []any{}, nil
		}
		return nil, ErrBackendDecode
	}
	if first == nil {
		return nil, ErrBackendDecode
	}
	// A normal JSON array/object is a complete value. Reject trailing non-space
	// data; NDJSON is handled only when the first value is an object.
	if _, ok := first.(map[string]any); !ok {
		if _, array := first.([]any); !array {
			return nil, ErrBackendDecode
		}
		var extra any
		if err := dec.Decode(&extra); err != io.EOF {
			return nil, ErrBackendDecode
		}
		return first, nil
	}
	// A single object is a normal JSON response (for example, a Prometheus
	// envelope). Only return an NDJSON slice when a second object is present.
	var second any
	err = dec.Decode(&second)
	if err == io.EOF {
		return first, nil
	}
	if err != nil || second == nil {
		return nil, ErrBackendDecode
	}
	if _, ok := second.(map[string]any); !ok {
		return nil, ErrBackendDecode
	}
	out := []any{first, second}
	for {
		var x any
		err := dec.Decode(&x)
		if err == io.EOF {
			break
		}
		if err != nil || x == nil {
			return nil, ErrBackendDecode
		}
		if _, ok := x.(map[string]any); !ok {
			return nil, ErrBackendDecode
		}
		out = append(out, x)
	}
	return out, nil
}
func get(ctx context.Context, c *Client, base, path string, q url.Values) (any, error) {
	u, e := url.Parse(strings.TrimRight(base, "/") + path)
	if e != nil {
		return nil, e
	}
	u.RawQuery = q.Encode()
	req, e := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if e != nil {
		return nil, e
	}
	resp, e := c.client().Do(req)
	if e != nil {
		return nil, e
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("backend status %d", resp.StatusCode)
	}
	return decodeBody(resp.Body)
}
func (c Client) LogsQuery(ctx context.Context, service string, start, end time.Time, limit int) (any, error) {
	return c.LogsQueryScoped(ctx, service, "", start, end, limit)
}
func (c Client) LogsQueryScoped(ctx context.Context, service, project string, start, end time.Time, limit int) (any, error) {
	filters := make([]string, 0, 2)
	if service != "" {
		filters = append(filters, logFilter("service.name", service))
	}
	if project != "" {
		filters = append(filters, logFilter("project", project))
	}
	q := url.Values{"query": []string{strings.Join(filters, " ")}, "start": []string{logTime(start)}, "end": []string{logTime(end)}, "limit": []string{strconv.Itoa(limit)}}
	if len(filters) == 0 {
		q.Del("query")
	}
	v, err := get(ctx, &c, c.Logs, "/select/logsql/query", q)
	if err != nil {
		return nil, err
	}
	if empty(v) {
		return nil, ErrNoData
	}
	return v, nil
}

// logFilter uses LogSQL's field:value syntax. Dotted field names cannot use
// the PromQL-style field=value form (VictoriaLogs parses that as a field named
// "service" followed by an unexpected token).
func logFilter(field, value string) string {
	value = strings.ReplaceAll(strings.ReplaceAll(value, `\\`, `\\\\`), `"`, `\\"`)
	return field + `:"` + value + `"`
}
func (c Client) LogsTrace(ctx context.Context, trace string, start, end time.Time, limit int) (any, error) {
	q := url.Values{"query": []string{"trace_id:" + trace}, "start": []string{logTime(start)}, "end": []string{logTime(end)}, "limit": []string{strconv.Itoa(limit)}}
	v, err := get(ctx, &c, c.Logs, "/select/logsql/query", q)
	if err != nil {
		return nil, err
	}
	if empty(v) {
		return nil, ErrNoData
	}
	return v, nil
}

func logTime(t time.Time) string { return t.UTC().Format(time.RFC3339Nano) }
func (c Client) MetricsQuery(ctx context.Context, service string, start, end time.Time, step time.Duration) (any, error) {
	selector := `{service_name=~".+"}`
	if service != "" {
		selector = `{service_name="` + promLabelEscape(service) + `"}`
	}
	q := url.Values{"query": []string{"count by (service_name) (" + selector + ")"}, "start": []string{strconv.FormatInt(start.Unix(), 10)}, "end": []string{strconv.FormatInt(end.Unix(), 10)}, "step": []string{step.String()}}
	v, err := get(ctx, &c, c.Metrics, "/api/v1/query_range", q)
	if err != nil {
		return nil, err
	}
	if err := validateMetrics(v); err != nil {
		return nil, err
	}
	return v, nil
}
func (c Client) MetricsTrace(ctx context.Context, services []string, start, end time.Time, step time.Duration) (any, error) {
	if len(services) == 0 {
		return nil, ErrNoData
	}
	if len(services) > 16 {
		services = services[:16]
	}
	parts := make([]string, 0, len(services))
	for _, s := range services {
		parts = append(parts, regexp.QuoteMeta(s))
	}
	selector := `{service_name=~"` + strings.Join(parts, "|") + `"}`
	q := url.Values{"query": []string{"count by (service_name) (" + selector + ")"}, "start": []string{strconv.FormatInt(start.Unix(), 10)}, "end": []string{strconv.FormatInt(end.Unix(), 10)}, "step": []string{step.String()}}
	v, err := get(ctx, &c, c.Metrics, "/api/v1/query_range", q)
	if err != nil {
		return nil, err
	}
	if err := validateMetrics(v); err != nil {
		return nil, err
	}
	return v, nil
}
func (c Client) Services(ctx context.Context) (any, error) {
	return get(ctx, &c, c.Traces, "/select/jaeger/api/services", nil)
}
func (c Client) TraceQuery(ctx context.Context, trace string) (any, error) {
	v, err := get(ctx, &c, c.Traces, "/select/jaeger/api/traces/"+trace, nil)
	if err != nil {
		if strings.Contains(err.Error(), "backend status 404") {
			return nil, ErrTraceNotStored
		}
		return nil, err
	}
	if !validTraceResponse(v) {
		return nil, ErrTraceNotStored
	}
	return v, nil
}
func (c Client) TracesQuery(ctx context.Context, service string, limit int) (any, error) {
	return c.TracesQueryScoped(ctx, service, "", limit)
}
func (c Client) TracesQueryScoped(ctx context.Context, service, project string, limit int) (any, error) {
	q := url.Values{"service": []string{service}, "limit": []string{strconv.Itoa(limit)}}
	if project != "" {
		q.Set("project", project)
	}
	return get(ctx, &c, c.Traces, "/select/jaeger/api/traces", q)
}

func empty(v any) bool {
	switch x := v.(type) {
	case nil:
		return true
	case []any:
		return len(x) == 0
	case map[string]any:
		if d, ok := x["data"].([]any); ok {
			return len(d) == 0
		}
		return false
	}
	return false
}
func validTraceResponse(v any) bool {
	m, ok := v.(map[string]any)
	if !ok {
		return false
	}
	d, ok := m["data"].([]any)
	if !ok || len(d) == 0 {
		return false
	}
	x, ok := d[0].(map[string]any)
	if !ok {
		return false
	}
	_, ok = x["spans"].([]any)
	_, procOK := x["processes"].(map[string]any)
	return ok && procOK
}
func validateMetrics(v any) error {
	m, ok := v.(map[string]any)
	if !ok {
		return ErrBackendDecode
	}
	if s, ok := m["status"].(string); !ok {
		return ErrBackendDecode
	} else if s != "success" {
		return ErrBackendResponse
	}
	d, ok := m["data"].(map[string]any)
	if !ok {
		return ErrBackendDecode
	}
	rt, ok := d["resultType"].(string)
	if !ok || (rt != "matrix" && rt != "vector" && rt != "scalar" && rt != "string") {
		return ErrBackendDecode
	}
	result, ok := d["result"]
	if !ok {
		return ErrBackendDecode
	}
	if rt == "matrix" || rt == "vector" {
		rows, ok := result.([]any)
		if !ok {
			return ErrBackendDecode
		}
		if len(rows) == 0 {
			return ErrNoData
		}
	} else if result == nil {
		return ErrBackendDecode
	} else if _, ok := result.(string); !ok && rt == "string" {
		return ErrBackendDecode
	}
	return nil
}

func promLabelEscape(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return s
}

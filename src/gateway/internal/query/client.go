package query

import (
	"bytes"
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

type BackendHTTPError struct {
	StatusCode int
}

func (e BackendHTTPError) Error() string { return fmt.Sprintf("backend status %d", e.StatusCode) }

type Client struct {
	Logs, Metrics, Traces string
	HTTP                  *http.Client
}

var defaultHTTPClient = &http.Client{
	Timeout: 8 * time.Second,
	CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	},
}

// NewHTTPClient creates the single redirect-safe client used by a Gateway
// query client.  Callers that provide a custom transport should construct it
// once at startup rather than cloning an http.Client for every request.
func NewHTTPClient(base *http.Client) *http.Client {
	if base == nil {
		return defaultHTTPClient
	}
	client := *base
	client.CheckRedirect = func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}
	return &client
}

func (c Client) client() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return defaultHTTPClient
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
	dec := json.NewDecoder(bytes.NewReader(b))
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
		return nil, BackendHTTPError{StatusCode: resp.StatusCode}
	}
	return decodeBody(resp.Body)
}
func (c Client) LogsQuery(ctx context.Context, service string, start, end time.Time, limit int) (any, error) {
	return c.LogsQueryScoped(ctx, service, "", start, end, limit)
}
func (c Client) LogsQueryScoped(ctx context.Context, service, project string, start, end time.Time, limit int) (any, error) {
	filters := make([]string, 0, 3)
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

// LogsErrorsScoped is the errors endpoint's query contract. Keep the error
// predicate in the backend query itself so successful records are never
// selected merely because the endpoint is named /v1/errors.
func (c Client) LogsErrorsScoped(ctx context.Context, service, project string, start, end time.Time, limit int) (any, error) {
	filters := []string{logFilter("severity_text", "error")}
	if service != "" {
		filters = append(filters, logFilter("service.name", service))
	}
	if project != "" {
		filters = append(filters, logFilter("project", project))
	}
	q := url.Values{"query": []string{strings.Join(filters, " ")}, "start": []string{logTime(start)}, "end": []string{logTime(end)}, "limit": []string{strconv.Itoa(limit)}}
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
	value = strings.ReplaceAll(strings.ReplaceAll(value, `\`, `\\`), `"`, `\"`)
	return field + `:"` + value + `"`
}
func (c Client) LogsTrace(ctx context.Context, trace string, start, end time.Time, limit int) (any, error) {
	return c.LogsTraceScoped(ctx, trace, "", start, end, limit)
}
func (c Client) LogsTraceScoped(ctx context.Context, trace, project string, start, end time.Time, limit int) (any, error) {
	filters := []string{"trace_id:" + trace}
	if project != "" {
		filters = append(filters, logFilter("project", project))
	}
	q := url.Values{"query": []string{strings.Join(filters, " ")}, "start": []string{logTime(start)}, "end": []string{logTime(end)}, "limit": []string{strconv.Itoa(limit)}}
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
	return c.MetricsQueryScoped(ctx, service, "", start, end, step)
}
func (c Client) MetricsQueryScoped(ctx context.Context, service, project string, start, end time.Time, step time.Duration) (any, error) {
	labels := []string{}
	if service != "" {
		labels = append(labels, `service_name="`+promLabelEscape(service)+`"`)
	} else {
		labels = append(labels, `service_name=~".+"`)
	}
	if project != "" {
		// The collector canonicalizes agentotel.project.id to the low-cardinality
		// Prometheus label `project`; escape it as a label value, never as query
		// syntax.
		labels = append(labels, `project="`+promLabelEscape(project)+`"`)
	}
	selector := `{` + strings.Join(labels, ",") + `}`
	// Context is a current metric snapshot, not a time series. An instant
	// query preserves the service/project aggregation while avoiding the 61
	// samples emitted by the previous 15-second query_range request.
	q := url.Values{"query": []string{"count by (service_name) (" + selector + ")"}, "time": []string{strconv.FormatInt(end.Unix(), 10)}}
	v, err := get(ctx, &c, c.Metrics, "/api/v1/query", q)
	if err != nil {
		return nil, err
	}
	if err := validateMetrics(v); err != nil {
		return nil, err
	}
	return v, nil
}
func (c Client) MetricsTrace(ctx context.Context, services []string, start, end time.Time, step time.Duration) (any, error) {
	return c.MetricsTraceScoped(ctx, services, "", start, end, step)
}
func (c Client) MetricsTraceScoped(ctx context.Context, services []string, project string, start, end time.Time, step time.Duration) (any, error) {
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
	labels := []string{`service_name=~"` + strings.Join(parts, "|") + `"`}
	if project != "" {
		labels = append(labels, `project="`+promLabelEscape(project)+`"`)
	}
	selector := `{` + strings.Join(labels, ",") + `}`
	// Correlation attaches a same-service metric snapshot to a trace. The
	// trace/log lookback remains bounded independently; returning one value at
	// the end of that window is sufficient and keeps the response compact.
	q := url.Values{"query": []string{"count by (service_name) (" + selector + ")"}, "time": []string{strconv.FormatInt(end.Unix(), 10)}}
	v, err := get(ctx, &c, c.Metrics, "/api/v1/query", q)
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
	return c.TraceQueryScoped(ctx, trace, "")
}
func (c Client) TraceQueryScoped(ctx context.Context, trace, project string) (any, error) {
	v, err := get(ctx, &c, c.Traces, "/select/jaeger/api/traces/"+trace, nil)
	if err != nil {
		if strings.Contains(err.Error(), "backend status 404") {
			return nil, ErrTraceNotStored
		}
		return nil, err
	}
	if project != "" {
		v, err = scopeTraceProject(v, project)
		if err != nil {
			return nil, err
		}
	}
	if !validTraceResponse(v) {
		return nil, ErrTraceNotStored
	}
	return v, nil
}

// scopeTraceProject enforces the optional project provenance filter on the
// trace-by-ID response itself. Trace IDs are globally unique, but a trace can
// contain spans from multiple resource processes; returning the unfiltered
// response would therefore violate a requested project scope.
func scopeTraceProject(raw any, project string) (any, error) {
	m, ok := raw.(map[string]any)
	if !ok {
		return nil, ErrNoData
	}
	data, ok := m["data"].([]any)
	if !ok {
		return nil, ErrNoData
	}
	filtered := make([]any, 0, len(data))
	for _, item := range data {
		root, ok := item.(map[string]any)
		if !ok {
			continue
		}
		processes, ok := root["processes"].(map[string]any)
		if !ok {
			continue
		}
		matchingProcesses := make(map[string]any)
		for id, process := range processes {
			if processProject(process) == project {
				matchingProcesses[id] = process
			}
		}
		if len(matchingProcesses) == 0 {
			continue
		}
		spans, ok := root["spans"].([]any)
		if !ok {
			continue
		}
		keptSpans := make([]any, 0, len(spans))
		keptSpanIDs := make(map[string]bool)
		for _, value := range spans {
			span, ok := value.(map[string]any)
			if !ok {
				continue
			}
			processID, _ := span["processID"].(string)
			if _, ok := matchingProcesses[processID]; !ok {
				continue
			}
			clone := make(map[string]any, len(span))
			for key, field := range span {
				clone[key] = field
			}
			if references, ok := span["references"].([]any); ok {
				keptReferences := make([]any, 0, len(references))
				for _, reference := range references {
					ref, ok := reference.(map[string]any)
					if !ok {
						continue
					}
					// References are resolved after collecting IDs below; remove
					// cross-scope references after the full span set is known.
					keptReferences = append(keptReferences, ref)
				}
				clone["references"] = keptReferences
			}
			keptSpans = append(keptSpans, clone)
			keptSpanIDs[stringField(span, "spanID")] = true
		}
		if len(keptSpans) == 0 {
			continue
		}
		for _, value := range keptSpans {
			span, ok := value.(map[string]any)
			if !ok {
				continue
			}
			references, ok := span["references"].([]any)
			if !ok {
				continue
			}
			keptReferences := references[:0]
			for _, reference := range references {
				ref, ok := reference.(map[string]any)
				if ok && (stringField(ref, "spanID") == "" || keptSpanIDs[stringField(ref, "spanID")]) {
					keptReferences = append(keptReferences, ref)
				}
			}
			span["references"] = keptReferences
		}
		clone := make(map[string]any, len(root))
		for key, field := range root {
			clone[key] = field
		}
		clone["processes"] = matchingProcesses
		clone["spans"] = keptSpans
		filtered = append(filtered, clone)
	}
	if len(filtered) == 0 {
		return nil, ErrNoData
	}
	clone := make(map[string]any, len(m))
	for key, field := range m {
		clone[key] = field
	}
	clone["data"] = filtered
	return clone, nil
}

func stringField(m map[string]any, key string) string {
	s, _ := m[key].(string)
	return s
}

func processProject(v any) string {
	m, ok := v.(map[string]any)
	if !ok {
		return ""
	}
	if p := stringField(m, "project"); p != "" {
		return p
	}
	tags, _ := m["tags"].([]any)
	for _, value := range tags {
		tag, ok := value.(map[string]any)
		if !ok {
			continue
		}
		key := strings.ToLower(stringField(tag, "key"))
		switch key {
		case "project", "project.id", "resource.project", "resource.project.id", "otel.resource.project.id", "resource_attr:project", "resource_attr:project.id":
			if p := stringField(tag, "value"); p != "" {
				return p
			}
		}
	}
	return ""
}
func (c Client) TracesQuery(ctx context.Context, service string, limit int) (any, error) {
	return c.TracesQueryScoped(ctx, service, "", time.Time{}, time.Time{}, limit)
}

// TracesQueryScoped searches the Jaeger-compatible trace API within the
// supplied bounded window. Jaeger encodes start and end as Unix microseconds,
// rather than the RFC3339 values used by VictoriaLogs.
func (c Client) TracesQueryScoped(ctx context.Context, service, project string, start, end time.Time, limit int) (any, error) {
	q := url.Values{"service": []string{service}, "limit": []string{strconv.Itoa(limit)}}
	if !start.IsZero() {
		q.Set("start", strconv.FormatInt(start.UTC().UnixMicro(), 10))
	}
	if !end.IsZero() {
		q.Set("end", strconv.FormatInt(end.UTC().UnixMicro(), 10))
	}
	// VictoriaTraces' Jaeger API accepts a JSON object in `tags`. The live OTel
	// storage exposes the failure marker as the Jaeger span tag error=true;
	// project is a resource attribute and therefore needs the resource_attr:
	// prefix. Keeping both predicates in the backend request prevents successful
	// or cross-project spans from being selected for /v1/errors.
	tags := map[string]string{"error": "true"}
	if project != "" {
		tags["resource_attr:project"] = project
	}
	tagsJSON, _ := json.Marshal(tags)
	q.Set("tags", string(tagsJSON))
	v, err := get(ctx, &c, c.Traces, "/select/jaeger/api/traces", q)
	if err != nil {
		return nil, err
	}
	if empty(v) {
		return nil, ErrNoData
	}
	return v, nil
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

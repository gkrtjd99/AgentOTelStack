package proxy

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	MaxBodyBytes       = 64 << 10
	MaxUpstreamBytes   = 1 << 20
	UpstreamTimeout    = 8 * time.Second
	DefaultLookback    = "15m"
	DefaultLimit       = 50
	DashboardSchema    = "dashboard.v1"
	UntrustedTelemetry = "untrusted_telemetry"
)

var (
	serviceRE = regexp.MustCompile(`^[[:print:]]{1,128}$`)
	traceRE   = regexp.MustCompile(`^[0-9a-f]{32}$`)
	projectRE = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$`)
)

var lookbacks = map[string]struct{}{
	"5m": {}, "15m": {}, "1h": {}, "6h": {}, "24h": {},
}

// Config contains only the dashboard's server-side credentials and fixed scope.
// None of these values are copied into a browser response.
type Config struct {
	GatewayURL string
	QueryToken string
	ProjectID  string
	HTTPClient *http.Client
}

// ValidateConfig rejects ambiguous or unsafe startup configuration. The
// dashboard talks to the query listener only; it has no ingest credential.
func ValidateConfig(c Config) error {
	if c.QueryToken == "" {
		return errors.New("missing dashboard query token")
	}
	if strings.ContainsAny(c.QueryToken, "\x00\r\n") {
		return errors.New("invalid dashboard query token")
	}
	if err := ValidateProject(c.ProjectID); err != nil {
		return errors.New("invalid dashboard project id")
	}
	u, err := url.Parse(c.GatewayURL)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("invalid dashboard gateway url")
	}
	return nil
}

// Handler is a same-origin adapter between the browser and the fixed Gateway
// query API. It never forwards browser credentials or proxy headers.
type Handler struct {
	gatewayURL string
	queryToken string
	projectID  string
	client     *http.Client
}

func New(c Config) (*Handler, error) {
	if err := ValidateConfig(c); err != nil {
		return nil, err
	}
	client := c.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: UpstreamTimeout}
	} else {
		copy := *client
		client = &copy
	}
	client.CheckRedirect = func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}
	return &Handler{
		gatewayURL: strings.TrimRight(c.GatewayURL, "/"),
		queryToken: c.QueryToken,
		projectID:  c.ProjectID,
		client:     client,
	}, nil
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/api/services":
		if r.Method != http.MethodGet {
			httpJSONError(w, http.StatusMethodNotAllowed, "method_not_allowed")
			return
		}
		h.services(w, r)
	case "/api/context", "/api/errors":
		if r.Method != http.MethodGet {
			httpJSONError(w, http.StatusMethodNotAllowed, "method_not_allowed")
			return
		}
		h.queryView(w, r, strings.TrimPrefix(r.URL.Path, "/api/"))
	case "/api/correlate":
		if r.Method != http.MethodPost {
			httpJSONError(w, http.StatusMethodNotAllowed, "method_not_allowed")
			return
		}
		h.correlate(w, r)
	default:
		httpJSONError(w, http.StatusNotFound, "not_found")
	}
}

func (h *Handler) services(w http.ResponseWriter, r *http.Request) {
	if _, err := strictQuery(r, nil); err != nil {
		httpJSONError(w, http.StatusBadRequest, "invalid_query")
		return
	}
	query := url.Values{"project": []string{h.projectID}}
	h.fetch(w, r, "services", http.MethodGet, "/v1/services?"+query.Encode(), nil, Scope{ProjectBound: true})
}

func (h *Handler) queryView(w http.ResponseWriter, r *http.Request, kind string) {
	allowed := map[string]bool{"service": true, "lookback": true, "limit": true}
	values, err := strictQuery(r, allowed)
	if err != nil {
		httpJSONError(w, http.StatusBadRequest, "invalid_query")
		return
	}
	service := values.Get("service")
	lookback := values.Get("lookback")
	limit := values.Get("limit")
	if service != "" && ValidateService(service) != nil {
		httpJSONError(w, http.StatusBadRequest, "invalid_service")
		return
	}
	if lookback == "" {
		lookback = DefaultLookback
	}
	if !validLookback(lookback) {
		httpJSONError(w, http.StatusBadRequest, "invalid_lookback")
		return
	}
	parsedLimit, err := parseLimit(limit)
	if err != nil {
		httpJSONError(w, http.StatusBadRequest, "invalid_limit")
		return
	}
	scope := Scope{Service: service, Lookback: lookback, Limit: parsedLimit, ProjectBound: true}
	q := url.Values{
		"project":  []string{h.projectID},
		"lookback": []string{lookback},
		"limit":    []string{strconv.Itoa(parsedLimit)},
	}
	if service != "" {
		q.Set("service", service)
	}
	h.fetch(w, r, kind, http.MethodGet, "/v1/"+kind+"?"+q.Encode(), nil, scope)
}

func (h *Handler) correlate(w http.ResponseWriter, r *http.Request) {
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		httpJSONError(w, http.StatusBadRequest, "invalid_content_type")
		return
	}
	if encoding := r.Header.Get("Content-Encoding"); encoding != "" && !strings.EqualFold(encoding, "identity") {
		httpJSONError(w, http.StatusBadRequest, "invalid_content_encoding")
		return
	}
	if r.ContentLength > MaxBodyBytes {
		httpJSONError(w, http.StatusRequestEntityTooLarge, "request_too_large")
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, MaxBodyBytes+1))
	if err != nil || len(body) > MaxBodyBytes {
		httpJSONError(w, http.StatusRequestEntityTooLarge, "request_too_large")
		return
	}
	fields, err := strictJSONObject(body)
	if err != nil {
		if errors.Is(err, errTrailingJSON) {
			httpJSONError(w, http.StatusBadRequest, "trailing_json")
		} else {
			httpJSONError(w, http.StatusBadRequest, "invalid_json")
		}
		return
	}
	for key := range fields {
		if key != "trace_id" && key != "limit" {
			httpJSONError(w, http.StatusBadRequest, "unknown_field")
			return
		}
	}
	var traceID string
	if raw, ok := fields["trace_id"]; !ok || json.Unmarshal(raw, &traceID) != nil || ValidateTraceID(traceID) != nil {
		httpJSONError(w, http.StatusBadRequest, "invalid_trace_id")
		return
	}
	limit := DefaultLimit
	if raw, ok := fields["limit"]; ok {
		if string(raw) == "null" {
			httpJSONError(w, http.StatusBadRequest, "invalid_limit")
			return
		}
		var n int
		if err := json.Unmarshal(raw, &n); err != nil {
			httpJSONError(w, http.StatusBadRequest, "invalid_limit")
			return
		}
		limit = n
	}
	// An omitted limit gets the default; an explicit zero (including JSON's
	// negative zero) is outside the documented 1-500 contract.
	if limit < 1 || limit > 500 {
		httpJSONError(w, http.StatusBadRequest, "invalid_limit")
		return
	}
	upstreamBody, _ := json.Marshal(struct {
		TraceID string `json:"trace_id"`
		Limit   int    `json:"limit"`
		Project string `json:"project"`
	}{TraceID: traceID, Limit: limit, Project: h.projectID})
	h.fetch(w, r, "correlate", http.MethodPost, "/v1/correlate", upstreamBody, Scope{Limit: limit, ProjectBound: true})
}

var errTrailingJSON = errors.New("trailing json")

func strictJSONObject(body []byte) (map[string]json.RawMessage, error) {
	dec := json.NewDecoder(bytes.NewReader(body))
	token, err := dec.Token()
	if err != nil {
		return nil, err
	}
	delim, ok := token.(json.Delim)
	if !ok || delim != '{' {
		return nil, errors.New("json object required")
	}
	fields := make(map[string]json.RawMessage)
	for dec.More() {
		token, err := dec.Token()
		if err != nil {
			return nil, err
		}
		key, ok := token.(string)
		if !ok || key == "" {
			return nil, errors.New("json key required")
		}
		if _, exists := fields[key]; exists {
			return nil, errors.New("duplicate json field")
		}
		var value json.RawMessage
		if err := dec.Decode(&value); err != nil {
			return nil, err
		}
		fields[key] = value
	}
	end, err := dec.Token()
	if err != nil {
		return nil, err
	}
	if delim, ok := end.(json.Delim); !ok || delim != '}' {
		return nil, errors.New("json object end required")
	}
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		if err == nil {
			return nil, errTrailingJSON
		}
		return nil, errTrailingJSON
	}
	return fields, nil
}

func strictQuery(r *http.Request, allowed map[string]bool) (url.Values, error) {
	values, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		return nil, err
	}
	for key, vals := range values {
		if allowed == nil || !allowed[key] || len(vals) != 1 {
			return nil, errors.New("unsupported or duplicate query parameter")
		}
	}
	return values, nil
}

func parseLimit(raw string) (int, error) {
	if raw == "" {
		return DefaultLimit, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil || strconv.Itoa(n) != raw || n < 1 || n > 500 {
		return 0, errors.New("invalid limit")
	}
	return n, nil
}

func validLookback(s string) bool {
	_, ok := lookbacks[s]
	return ok
}

func ValidateService(s string) error {
	if s == "" || !serviceRE.MatchString(s) || strings.ContainsAny(s, "{}[]()=~!|,;\r\n\t\"\\") {
		return errors.New("invalid service")
	}
	return nil
}

func ValidateTraceID(s string) error {
	if !traceRE.MatchString(s) {
		return errors.New("invalid trace id")
	}
	return nil
}

func ValidateProject(s string) error {
	if !projectRE.MatchString(s) {
		return errors.New("invalid project id")
	}
	return nil
}

func (h *Handler) fetch(w http.ResponseWriter, r *http.Request, kind, method, path string, body []byte, scope Scope) {
	ctx, cancel := context.WithTimeout(r.Context(), UpstreamTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, h.gatewayURL+path, bytes.NewReader(body))
	if err != nil {
		httpJSONError(w, http.StatusBadGateway, "upstream_request_failed")
		return
	}
	// Deliberately construct a new request and set only the exact Gateway
	// credential and content type. Authorization, Cookie, forwarded and proxy
	// headers supplied by the browser are never copied.
	req.Header.Set("Authorization", "Bearer "+h.queryToken)
	if method == http.MethodPost {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := h.client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			httpJSONError(w, http.StatusGatewayTimeout, "upstream_timeout")
		} else {
			httpJSONError(w, http.StatusBadGateway, "upstream_unavailable")
		}
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// Redirects are an upstream failure, not a browser redirect. The custom
		// client never follows them and no Location header is copied.
		httpJSONError(w, http.StatusBadGateway, "upstream_unavailable")
		return
	}
	if resp.ContentLength > MaxUpstreamBytes {
		httpJSONError(w, http.StatusBadGateway, "upstream_response_too_large")
		return
	}
	payload, err := io.ReadAll(io.LimitReader(resp.Body, MaxUpstreamBytes+1))
	if err != nil || len(payload) > MaxUpstreamBytes {
		httpJSONError(w, http.StatusBadGateway, "upstream_response_too_large")
		return
	}
	var raw map[string]any
	dec := json.NewDecoder(bytes.NewReader(payload))
	if err := dec.Decode(&raw); err != nil || raw == nil {
		httpJSONError(w, http.StatusBadGateway, "upstream_invalid_json")
		return
	}
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		httpJSONError(w, http.StatusBadGateway, "upstream_invalid_json")
		return
	}
	view := Normalize(kind, raw, scope)
	view = redactView(view, h.projectID, h.queryToken, h.gatewayURL)
	writeView(w, view)
}

// BackendStatus is intentionally a small status projection; backend payloads
// and backend URLs do not cross the browser boundary.
type BackendStatus struct {
	Name        string `json:"name"`
	Status      string `json:"status"`
	Error       string `json:"error,omitempty"`
	Unsupported bool   `json:"unsupported,omitempty"`
}

type Scope struct {
	Service      string `json:"service,omitempty"`
	Lookback     string `json:"lookback,omitempty"`
	Limit        int    `json:"limit,omitempty"`
	ProjectBound bool   `json:"project_bound"`
}

type View struct {
	SchemaVersion string          `json:"schema_version"`
	Kind          string          `json:"kind"`
	FetchedAt     string          `json:"fetched_at"`
	Partial       bool            `json:"partial"`
	Truncated     bool            `json:"truncated"`
	Warnings      []string        `json:"warnings,omitempty"`
	ContentTrust  string          `json:"content_trust"`
	Backends      []BackendStatus `json:"backends"`
	Scope         Scope           `json:"scope"`
	Data          any             `json:"data"`
}

type ServicesData struct {
	Supported bool     `json:"supported"`
	Services  []string `json:"services"`
}

type LogRecord struct {
	TraceID   string `json:"trace_id,omitempty"`
	Service   string `json:"service,omitempty"`
	Severity  string `json:"severity,omitempty"`
	Message   string `json:"message,omitempty"`
	Timestamp string `json:"timestamp,omitempty"`
}

type MetricRecord struct {
	Service string `json:"service,omitempty"`
	Value   string `json:"value,omitempty"`
}

type ContextData struct {
	Supported bool           `json:"supported"`
	Logs      []LogRecord    `json:"logs"`
	Metrics   []MetricRecord `json:"metrics"`
}

type ErrorRecord struct {
	TraceID   string `json:"trace_id,omitempty"`
	Service   string `json:"service,omitempty"`
	Operation string `json:"operation,omitempty"`
	Message   string `json:"message,omitempty"`
	Timestamp string `json:"timestamp,omitempty"`
}

type ErrorsData struct {
	Supported bool          `json:"supported"`
	Errors    []ErrorRecord `json:"errors"`
}

type SpanRecord struct {
	SpanID    string `json:"span_id,omitempty"`
	Service   string `json:"service,omitempty"`
	Operation string `json:"operation,omitempty"`
	StartTime string `json:"start_time,omitempty"`
	Duration  string `json:"duration,omitempty"`
	Status    string `json:"status,omitempty"`
}

type CorrelationData struct {
	Supported  bool           `json:"supported"`
	TraceID    string         `json:"trace_id,omitempty"`
	Spans      []SpanRecord   `json:"spans"`
	Logs       []LogRecord    `json:"logs"`
	Metrics    []MetricRecord `json:"metrics"`
	Indicators []string       `json:"indicators"`
}

// Normalize converts the intentionally weak Gateway envelope into a stable
// dashboard view model. Only fields with a known shape are selected; healthy
// no-data envelopes are represented as typed, supported empty projections.
func Normalize(kind string, raw map[string]any, scope Scope) View {
	backends, backendsTruncated := normalizeBackends(raw["backends"])
	view := View{
		SchemaVersion: DashboardSchema,
		Kind:          kind,
		FetchedAt:     time.Now().UTC().Format(time.RFC3339Nano),
		Partial:       boolField(raw, "partial"),
		Truncated:     boolField(raw, "truncated"),
		Warnings:      stringList(raw["warnings"], 16, 256),
		ContentTrust:  safeField(raw["content_trust"], 64),
		Backends:      backends,
		Scope:         scope,
	}
	if backendsTruncated {
		view.Truncated = true
		appendWarning(&view, "backend_status_limit")
	}
	if view.ContentTrust == "" {
		view.ContentTrust = "unknown"
	}
	if len(view.Backends) == 0 {
		view.Backends = []BackendStatus{{Name: "gateway", Status: "unsupported", Unsupported: true}}
	}
	data, _ := raw["data"].(map[string]any)
	noDataEnvelope := healthyNoData(view)
	switch kind {
	case "services":
		services, servicesTruncated := normalizeServices(data)
		view.Data = services
		if servicesTruncated {
			view.Truncated = true
			appendWarning(&view, "service_list_limit")
		}
	case "context":
		contextData := normalizeContext(data, scope)
		if noDataEnvelope {
			contextData.Supported = true
		}
		view.Data = contextData
	case "errors":
		errorsData := normalizeErrors(data, scope)
		if noDataEnvelope {
			errorsData.Supported = true
		}
		view.Data = errorsData
	case "correlate":
		correlationData := normalizeCorrelation(data, scope)
		if noDataEnvelope {
			correlationData.Supported = true
		}
		view.Data = correlationData
	default:
		view.Data = map[string]any{"supported": false}
	}
	return view
}

const (
	maxNormalizedBackends = 16
	maxNormalizedServices = 500
)

// healthyNoData distinguishes an intentional empty query result from a
// malformed or unavailable backend response. A no-data status is healthy only
// when every reported backend is either successful or explicitly says that no
// matching signal was found.
func healthyNoData(view View) bool {
	if view.Partial || len(view.Backends) == 0 {
		return false
	}
	sawNoData := false
	for _, backend := range view.Backends {
		switch backend.Status {
		case "ok":
		case "no_matching", "no_matching_data", "trace_not_stored", "signal_not_observed":
			sawNoData = true
		default:
			return false
		}
	}
	return sawNoData
}

func normalizeBackends(raw any) ([]BackendStatus, bool) {
	items, ok := raw.([]any)
	if !ok {
		return nil, false
	}
	truncated := len(items) > maxNormalizedBackends
	count := min(len(items), maxNormalizedBackends)
	out := make([]BackendStatus, 0, count)
	for i := 0; i < count; i++ {
		item := items[i]
		m, ok := item.(map[string]any)
		if !ok {
			out = append(out, BackendStatus{Name: "unknown", Status: "unsupported", Unsupported: true})
			continue
		}
		name := safeField(m["name"], 64)
		status := safeField(m["status"], 64)
		if name == "" {
			name = "unknown"
		}
		if status == "" {
			status = "unsupported"
		}
		b := BackendStatus{Name: name, Status: status}
		if status == "unsupported" {
			b.Unsupported = true
		}
		if e := safeField(m["error"], 256); e != "" {
			b.Error = e
		}
		out = append(out, b)
	}
	return out, truncated
}

func normalizeServices(data map[string]any) (ServicesData, bool) {
	out := ServicesData{Supported: false, Services: []string{}}
	values, ok := data["services"].([]any)
	if !ok {
		return out, false
	}
	out.Supported = true
	truncated := len(values) > maxNormalizedServices
	count := min(len(values), maxNormalizedServices)
	seen := make(map[string]bool, min(count, maxNormalizedServices))
	out.Services = make([]string, 0, min(count, maxNormalizedServices))
	for i := 0; i < count; i++ {
		value := values[i]
		name, ok := value.(string)
		if !ok || ValidateService(name) != nil || seen[name] {
			continue
		}
		seen[name] = true
		out.Services = append(out.Services, cleanText(name, 128))
	}
	return out, truncated
}

func normalizeContext(data map[string]any, scope Scope) ContextData {
	limit := sampleLimit(scope)
	out := ContextData{Supported: false, Logs: []LogRecord{}, Metrics: []MetricRecord{}}
	if _, ok := data["logs"]; ok {
		out.Supported = true
		out.Logs = normalizeLogs(data["logs"], limit)
	}
	if _, ok := data["metrics"]; ok {
		out.Supported = true
		out.Metrics = normalizeMetrics(data["metrics"], limit)
	}
	return out
}

func normalizeErrors(data map[string]any, scope Scope) ErrorsData {
	limit := sampleLimit(scope)
	out := ErrorsData{Supported: false, Errors: []ErrorRecord{}}
	if logs, ok := data["logs"]; ok {
		out.Supported = true
		for _, record := range normalizeLogs(logs, limit) {
			if len(out.Errors) >= limit {
				break
			}
			out.Errors = append(out.Errors, ErrorRecord{TraceID: record.TraceID, Service: record.Service, Message: record.Message, Timestamp: record.Timestamp})
		}
	}
	if traces, ok := data["traces"]; ok {
		out.Supported = true
		remaining := limit - len(out.Errors)
		if remaining > 0 {
			out.Errors = append(out.Errors, normalizeTraceErrors(traces, remaining)...)
		}
	}
	return out
}

func normalizeCorrelation(data map[string]any, scope Scope) CorrelationData {
	limit := sampleLimit(scope)
	out := CorrelationData{Supported: false, Spans: []SpanRecord{}, Logs: []LogRecord{}, Metrics: []MetricRecord{}, Indicators: []string{}}
	correlation, ok := data["correlation"].(map[string]any)
	if !ok {
		return out
	}
	out.Supported = true
	out.TraceID = validTraceField(correlation["trace_id"])
	out.Spans = normalizeSpans(correlation["spans"], correlation["processes"], limit)
	out.Logs = normalizeLogs(correlation["logs"], limit)
	out.Metrics = normalizeMetrics(correlation["metrics"], limit)
	out.Indicators = stringList(correlation["indicators"], 32, 128)
	return out
}

func normalizeLogs(raw any, limit int) []LogRecord {
	items := unwrapItems(raw)
	out := make([]LogRecord, 0, min(len(items), limit))
	for _, item := range items {
		if len(out) >= limit {
			break
		}
		m, ok := item.(map[string]any)
		if !ok {
			continue
		}
		record := LogRecord{
			TraceID:   validTraceField(first(m, "trace_id", "traceid")),
			Service:   validServiceField(first(m, "service", "service_name", "service.name")),
			Severity:  cleanText(safeField(first(m, "severity_text", "severity"), 32), 32),
			Message:   cleanText(safeField(m["message"], 2048), 2048),
			Timestamp: cleanText(safeField(first(m, "timestamp", "time", "_time"), 128), 128),
		}
		if record.TraceID != "" || record.Service != "" || record.Message != "" || record.Timestamp != "" {
			out = append(out, record)
		}
	}
	return out
}

func normalizeMetrics(raw any, limit int) []MetricRecord {
	items := unwrapItems(raw)
	out := make([]MetricRecord, 0, min(len(items), limit))
	for _, item := range items {
		if len(out) >= limit {
			break
		}
		m, ok := item.(map[string]any)
		if !ok {
			continue
		}
		metric := m
		if nested, ok := m["metric"].(map[string]any); ok {
			metric = nested
		}
		record := MetricRecord{Service: validServiceField(first(metric, "service_name", "service", "service.name")), Value: metricValue(m)}
		if record.Service != "" || record.Value != "" {
			out = append(out, record)
		}
	}
	return out
}

func normalizeTraceErrors(raw any, limit int) []ErrorRecord {
	items := unwrapItems(raw)
	out := make([]ErrorRecord, 0, min(len(items), limit))
	for _, item := range items {
		if len(out) >= limit {
			break
		}
		m, ok := item.(map[string]any)
		if !ok {
			continue
		}
		traceID := validTraceField(first(m, "traceID", "trace_id", "traceid"))
		service := validServiceField(first(m, "service", "serviceName", "service_name"))
		operation := cleanText(safeField(first(m, "operationName", "operation", "name"), 256), 256)
		if operation == "" {
			if spans, ok := m["spans"].([]any); ok {
				processes, _ := m["processes"].(map[string]any)
				for _, value := range spans {
					span, ok := value.(map[string]any)
					if !ok {
						continue
					}
					if operation == "" {
						operation = cleanText(safeField(first(span, "operationName", "operation", "name"), 256), 256)
					}
					if service == "" {
						service = validServiceField(first(span, "service", "service_name"))
					}
					if service == "" {
						if processID, ok := span["processID"].(string); ok {
							if process, ok := processes[processID].(map[string]any); ok {
								service = validServiceField(first(process, "serviceName", "service_name", "service"))
							}
						}
					}
				}
			}
		}
		if traceID != "" || service != "" || operation != "" {
			out = append(out, ErrorRecord{TraceID: traceID, Service: service, Operation: operation})
		}
	}
	return out
}

func normalizeSpans(raw any, processes any, limit int) []SpanRecord {
	items, _ := raw.([]any)
	processMap, _ := processes.(map[string]any)
	out := make([]SpanRecord, 0, min(len(items), limit))
	for _, item := range items {
		if len(out) >= limit {
			break
		}
		m, ok := item.(map[string]any)
		if !ok {
			continue
		}
		service := ""
		if processID, ok := m["processID"].(string); ok {
			if p, ok := processMap[processID].(map[string]any); ok {
				service = validServiceField(first(p, "serviceName", "service_name", "service"))
			}
		}
		if service == "" {
			service = validServiceField(first(m, "service", "service_name"))
		}
		span := SpanRecord{
			SpanID:    validSpanField(first(m, "spanID", "span_id")),
			Service:   service,
			Operation: cleanText(safeField(first(m, "operationName", "operation", "name"), 256), 256),
			StartTime: scalarField(first(m, "startTime", "start_time"), 128),
			Duration:  scalarField(first(m, "duration", "duration_ms"), 64),
			Status:    cleanText(safeField(m["status"], 64), 64),
		}
		if span.SpanID != "" || span.Service != "" || span.Operation != "" {
			out = append(out, span)
		}
	}
	return out
}

func unwrapItems(raw any) []any {
	if raw == nil {
		return nil
	}
	if items, ok := raw.([]any); ok {
		return items
	}
	m, ok := raw.(map[string]any)
	if !ok {
		return nil
	}
	if items, ok := m["data"].([]any); ok {
		return items
	}
	if items, ok := m["items"].([]any); ok {
		return items
	}
	if nested, ok := m["data"].(map[string]any); ok {
		if items, ok := nested["result"].([]any); ok {
			return items
		}
		if items, ok := nested["items"].([]any); ok {
			return items
		}
	}
	return nil
}

func metricValue(m map[string]any) string {
	if value := scalarField(m["value"], 128); value != "" {
		return value
	}
	if values, ok := m["value"].([]any); ok && len(values) > 0 {
		return scalarField(values[len(values)-1], 128)
	}
	values, ok := m["values"].([]any)
	if !ok || len(values) == 0 {
		return ""
	}
	last := values[len(values)-1]
	if pair, ok := last.([]any); ok && len(pair) > 1 {
		return scalarField(pair[len(pair)-1], 128)
	}
	return scalarField(last, 128)
}

func first(m map[string]any, keys ...string) any {
	for _, key := range keys {
		if value, ok := m[key]; ok {
			return value
		}
	}
	return nil
}

func boolField(m map[string]any, key string) bool {
	value, _ := m[key].(bool)
	return value
}

func safeField(value any, max int) string {
	s, ok := value.(string)
	if !ok {
		return ""
	}
	return cleanText(s, max)
}

func scalarField(value any, max int) string {
	if text := safeField(value, max); text != "" {
		return text
	}
	switch number := value.(type) {
	case float64:
		return strconv.FormatFloat(number, 'f', -1, 64)
	case json.Number:
		return cleanText(number.String(), max)
	default:
		return ""
	}
}

func cleanText(s string, max int) string {
	s = strings.ToValidUTF8(s, "�")
	var b strings.Builder
	for _, r := range s {
		if r == '\x00' || r == '\x1b' || (r < 0x20 && r != '\n' && r != '\t') || r == 0x7f {
			continue
		}
		b.WriteRune(r)
		if b.Len() >= max {
			break
		}
	}
	out := b.String()
	if len(out) > max {
		out = out[:max]
		for !utf8.ValidString(out) {
			out = out[:len(out)-1]
		}
	}
	return out
}

func appendWarning(view *View, warning string) {
	for _, existing := range view.Warnings {
		if existing == warning {
			return
		}
	}
	if len(view.Warnings) >= 16 {
		// Keep the truncation signal visible even when an upstream supplied the
		// maximum number of untrusted warnings.
		view.Warnings[15] = warning
		return
	}
	view.Warnings = append(view.Warnings, warning)
}

func stringList(value any, maxItems, maxLen int) []string {
	items, ok := value.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, min(len(items), maxItems))
	for _, item := range items {
		if s := safeField(item, maxLen); s != "" {
			out = append(out, s)
		}
		if len(out) == maxItems {
			break
		}
	}
	return out
}

func validTraceField(value any) string {
	s := safeField(value, 64)
	if ValidateTraceID(s) != nil {
		return ""
	}
	return s
}

func validSpanField(value any) string {
	s := safeField(value, 64)
	if s == "" || len(s) > 64 || strings.ContainsAny(s, "\r\n\t") {
		return ""
	}
	return s
}

func validServiceField(value any) string {
	s := safeField(value, 128)
	if ValidateService(s) != nil {
		return ""
	}
	return s
}

func sampleLimit(scope Scope) int {
	if scope.Limit >= 1 && scope.Limit <= 500 {
		return scope.Limit
	}
	return DefaultLimit
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// redactView applies copy-on-write redaction to the already-normalized view.
// It deliberately does not marshal or unmarshal: one final JSON encode happens
// in writeView, and the input view (including all slices) remains unchanged.
func redactView(view View, secrets ...string) View {
	out := view
	out.SchemaVersion, _ = redactText(view.SchemaVersion, secrets)
	out.Kind, _ = redactText(view.Kind, secrets)
	out.FetchedAt, _ = redactText(view.FetchedAt, secrets)
	out.ContentTrust, _ = redactText(view.ContentTrust, secrets)
	out.Warnings = redactTextSlice(view.Warnings, secrets)
	out.Backends = redactBackendSlice(view.Backends, secrets)
	out.Scope = redactScope(view.Scope, secrets)
	out.Data = redactData(view.Data, secrets)
	return out
}

func redactText(text string, secrets []string) (string, bool) {
	redacted := text
	changed := false
	for _, secret := range secrets {
		if secret == "" {
			continue
		}
		next := strings.ReplaceAll(redacted, secret, "[redacted]")
		changed = changed || next != redacted
		redacted = next
	}
	return redacted, changed
}

func redactTextSlice(values []string, secrets []string) []string {
	var out []string
	for i, value := range values {
		redacted, changed := redactText(value, secrets)
		if !changed {
			continue
		}
		if out == nil {
			out = append([]string(nil), values...)
		}
		out[i] = redacted
	}
	if out == nil {
		return values
	}
	return out
}

func redactBackendSlice(values []BackendStatus, secrets []string) []BackendStatus {
	var out []BackendStatus
	for i, value := range values {
		redacted := value
		changed := false
		if redacted.Name, changed = redactText(value.Name, secrets); changed {
			// keep changed set below
		}
		if redacted.Status, changed = redactText(value.Status, secrets); changed {
			// preserve an earlier Name change
		}
		if value.Name != redacted.Name || value.Status != redacted.Status {
			changed = true
		}
		redacted.Error, _ = redactText(value.Error, secrets)
		if redacted.Error != value.Error {
			changed = true
		}
		if !changed {
			continue
		}
		if out == nil {
			out = append([]BackendStatus(nil), values...)
		}
		out[i] = redacted
	}
	if out == nil {
		return values
	}
	return out
}

func redactScope(scope Scope, secrets []string) Scope {
	out := scope
	out.Service, _ = redactText(scope.Service, secrets)
	out.Lookback, _ = redactText(scope.Lookback, secrets)
	return out
}

func redactLogSlice(values []LogRecord, secrets []string) []LogRecord {
	var out []LogRecord
	for i, value := range values {
		redacted := value
		redacted.TraceID, _ = redactText(value.TraceID, secrets)
		redacted.Service, _ = redactText(value.Service, secrets)
		redacted.Severity, _ = redactText(value.Severity, secrets)
		redacted.Message, _ = redactText(value.Message, secrets)
		redacted.Timestamp, _ = redactText(value.Timestamp, secrets)
		if redacted == value {
			continue
		}
		if out == nil {
			out = append([]LogRecord(nil), values...)
		}
		out[i] = redacted
	}
	if out == nil {
		return values
	}
	return out
}

func redactMetricSlice(values []MetricRecord, secrets []string) []MetricRecord {
	var out []MetricRecord
	for i, value := range values {
		redacted := value
		redacted.Service, _ = redactText(value.Service, secrets)
		redacted.Value, _ = redactText(value.Value, secrets)
		if redacted == value {
			continue
		}
		if out == nil {
			out = append([]MetricRecord(nil), values...)
		}
		out[i] = redacted
	}
	if out == nil {
		return values
	}
	return out
}

func redactErrorSlice(values []ErrorRecord, secrets []string) []ErrorRecord {
	var out []ErrorRecord
	for i, value := range values {
		redacted := value
		redacted.TraceID, _ = redactText(value.TraceID, secrets)
		redacted.Service, _ = redactText(value.Service, secrets)
		redacted.Operation, _ = redactText(value.Operation, secrets)
		redacted.Message, _ = redactText(value.Message, secrets)
		redacted.Timestamp, _ = redactText(value.Timestamp, secrets)
		if redacted == value {
			continue
		}
		if out == nil {
			out = append([]ErrorRecord(nil), values...)
		}
		out[i] = redacted
	}
	if out == nil {
		return values
	}
	return out
}

func redactSpanSlice(values []SpanRecord, secrets []string) []SpanRecord {
	var out []SpanRecord
	for i, value := range values {
		redacted := value
		redacted.SpanID, _ = redactText(value.SpanID, secrets)
		redacted.Service, _ = redactText(value.Service, secrets)
		redacted.Operation, _ = redactText(value.Operation, secrets)
		redacted.StartTime, _ = redactText(value.StartTime, secrets)
		redacted.Duration, _ = redactText(value.Duration, secrets)
		redacted.Status, _ = redactText(value.Status, secrets)
		if redacted == value {
			continue
		}
		if out == nil {
			out = append([]SpanRecord(nil), values...)
		}
		out[i] = redacted
	}
	if out == nil {
		return values
	}
	return out
}

func redactData(data any, secrets []string) any {
	switch value := data.(type) {
	case ServicesData:
		value.Services = redactTextSlice(value.Services, secrets)
		return value
	case ContextData:
		value.Logs = redactLogSlice(value.Logs, secrets)
		value.Metrics = redactMetricSlice(value.Metrics, secrets)
		return value
	case ErrorsData:
		value.Errors = redactErrorSlice(value.Errors, secrets)
		return value
	case CorrelationData:
		value.TraceID, _ = redactText(value.TraceID, secrets)
		value.Spans = redactSpanSlice(value.Spans, secrets)
		value.Logs = redactLogSlice(value.Logs, secrets)
		value.Metrics = redactMetricSlice(value.Metrics, secrets)
		value.Indicators = redactTextSlice(value.Indicators, secrets)
		return value
	default:
		redacted, _ := redactUnknown(data, secrets)
		return redacted
	}
}

// redactUnknown is the fail-safe path for future/unknown view data. It clones
// only containers containing a changed descendant and never mutates telemetry.
func redactUnknown(value any, secrets []string) (any, bool) {
	switch item := value.(type) {
	case string:
		return redactText(item, secrets)
	case []any:
		var out []any
		for i, child := range item {
			redacted, changed := redactUnknown(child, secrets)
			if !changed {
				continue
			}
			if out == nil {
				out = append([]any(nil), item...)
			}
			out[i] = redacted
		}
		if out == nil {
			return value, false
		}
		return out, true
	case map[string]any:
		var out map[string]any
		for key, child := range item {
			redacted, changed := redactUnknown(child, secrets)
			if !changed {
				continue
			}
			if out == nil {
				out = make(map[string]any, len(item))
				for existingKey, existingValue := range item {
					out[existingKey] = existingValue
				}
			}
			out[key] = redacted
		}
		if out == nil {
			return value, false
		}
		return out, true
	default:
		return value, false
	}
}

func writeView(w http.ResponseWriter, view View) {
	body, err := json.Marshal(view)
	if err != nil {
		httpJSONError(w, http.StatusInternalServerError, "view_encode_failed")
		return
	}
	if len(body) > MaxUpstreamBytes {
		view.Truncated = true
		view.Warnings = append(view.Warnings, "dashboard_response_size_limit")
		view.Data = map[string]any{"supported": false}
		body, _ = json.Marshal(view)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

func httpJSONError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = fmt.Fprintf(w, `{"error":%q}`+"\n", code)
}

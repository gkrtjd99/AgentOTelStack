package correlation

import (
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"
)

var traceIDRE = regexp.MustCompile(`^[0-9a-f]{32}$`)
var controlRE = regexp.MustCompile(`[\x00-\x1f\x7f-\x9f\x1b]`)

type Result struct {
	TraceID    string    `json:"trace_id"`
	Spans      []Span    `json:"spans"`
	Services   []string  `json:"services,omitempty"`
	Projects   []string  `json:"projects,omitempty"`
	RootSpanID string    `json:"root_span_id,omitempty"`
	Indicators []string  `json:"indicators,omitempty"`
	Failures   []Failure `json:"failures,omitempty"`
	Logs       any       `json:"logs,omitempty"`
	Metrics    any       `json:"metrics,omitempty"`
	StartTime  time.Time `json:"start_time,omitempty"`
	EndTime    time.Time `json:"end_time,omitempty"`
}
type Span struct {
	SpanID       string    `json:"span_id"`
	ParentSpanID string    `json:"parent_span_id,omitempty"`
	Operation    string    `json:"operation,omitempty"`
	Service      string    `json:"service,omitempty"`
	Project      string    `json:"project,omitempty"`
	StartTime    time.Time `json:"start_time"`
	DurationMS   float64   `json:"duration_ms"`
	Status       string    `json:"status,omitempty"`
}
type Failure struct {
	SpanID  string `json:"span_id"`
	Service string `json:"service,omitempty"`
	Kind    string `json:"kind"`
	Code    int    `json:"code,omitempty"`
}

func ValidTraceID(s string) bool { return traceIDRE.MatchString(s) }

// Decode accepts the Jaeger query response (data[0].spans) and projects only safe fields.
func Decode(traceID string, raw any) Result {
	r := Result{TraceID: traceID}
	root := raw
	if m, ok := raw.(map[string]any); ok {
		if d, ok := m["data"].([]any); ok && len(d) > 0 {
			root = d[0]
		}
	}
	m, _ := root.(map[string]any)
	arr, _ := m["spans"].([]any)
	services, projects := map[string]bool{}, map[string]bool{}
	hasParent := map[string]bool{}
	for _, v := range arr {
		sm, ok := v.(map[string]any)
		if !ok {
			continue
		}
		s := Span{SpanID: str(sm["spanID"]), Operation: str(sm["operationName"]), StartTime: ts(sm["startTime"]), DurationMS: num(sm["duration"]) / 1000}
		if p, ok := sm["references"].([]any); ok {
			for _, x := range p {
				if q, ok := x.(map[string]any); ok && (str(q["refType"]) == "CHILD_OF" || str(q["refType"]) == "") {
					s.ParentSpanID = str(q["spanID"])
					hasParent[s.SpanID] = true
				}
			}
		}
		if p, ok := sm["processID"].(string); ok {
			if pm, ok := m["processes"].(map[string]any); ok {
				if x, ok := pm[p].(map[string]any); ok {
					s.Service = str(x["serviceName"])
					s.Project = str(x["project"])
					if s.Project == "" {
						s.Project = processProject(x)
					}
				}
			}
		}
		if s.Service != "" {
			services[s.Service] = true
		}
		if s.Project != "" {
			projects[s.Project] = true
		}
		s.Status = spanStatus(sm)
		if s.StartTime.IsZero() || s.DurationMS < 0 {
			r.Indicators = append(r.Indicators, "timestamps_invalid")
		}
		if s.Status == "ERROR" {
			r.Failures = append(r.Failures, Failure{SpanID: s.SpanID, Service: s.Service, Kind: "status_error"})
		}
		r.Spans = append(r.Spans, s)
	}
	if len(r.Spans) == 0 {
		r.Indicators = append(r.Indicators, "trace_not_stored")
	} else {
		for _, s := range r.Spans {
			if s.SpanID != "" && !hasParent[s.SpanID] {
				r.RootSpanID = s.SpanID
				break
			}
		}
		for s := range services {
			r.Services = append(r.Services, s)
		}
		for p := range projects {
			r.Projects = append(r.Projects, p)
		}
		if r.RootSpanID == "" {
			r.Indicators = append(r.Indicators, "missing_root")
		}
		for _, s := range r.Spans {
			if s.ParentSpanID != "" {
				found := false
				for _, x := range r.Spans {
					if x.SpanID == s.ParentSpanID {
						found = true
					}
				}
				if !found {
					r.Indicators = append(r.Indicators, "broken_parent_ref")
				}
			}
		}
		if len(r.Indicators) == 0 {
			r.Indicators = append(r.Indicators, "telemetry_complete")
		}
	}
	if len(r.Spans) > 0 {
		r.StartTime = r.Spans[0].StartTime
		r.EndTime = r.Spans[0].StartTime.Add(time.Duration(r.Spans[0].DurationMS) * time.Millisecond)
		for _, s := range r.Spans {
			e := s.StartTime.Add(time.Duration(s.DurationMS) * time.Millisecond)
			if s.StartTime.Before(r.StartTime) {
				r.StartTime = s.StartTime
			}
			if e.After(r.EndTime) {
				r.EndTime = e
			}
		}
	}
	sort.Strings(r.Services)
	sort.Strings(r.Projects)
	sort.Slice(r.Spans, func(i, j int) bool { return r.Spans[i].StartTime.Before(r.Spans[j].StartTime) })
	return r
}
func spanStatus(m map[string]any) string {
	if x, ok := m["tags"].([]any); ok {
		for _, v := range x {
			q, _ := v.(map[string]any)
			k := str(q["key"])
			val := str(q["value"])
			if k == "error" && truthy(q["value"]) {
				return "ERROR"
			}
			if k == "otel.status_code" && strings.EqualFold(val, "ERROR") {
				return "ERROR"
			}
			if k == "http.status_code" || k == "http.response.status_code" {
				n := number(q["value"])
				if n >= 400 {
					return "ERROR"
				}
			}
			if k == "rpc.grpc.status_code" && val != "0" && val != "OK" {
				if _, ok := q["value"].(string); ok || number(q["value"]) != 0 {
					return "ERROR"
				}
			}
		}
	}
	return ""
}
func truthy(v any) bool {
	switch x := v.(type) {
	case bool:
		return x
	case string:
		return strings.EqualFold(x, "true")
	default:
		return false
	}
}
func processProject(m map[string]any) string {
	if p := str(m["project"]); p != "" {
		return p
	}
	if tags, ok := m["tags"].([]any); ok {
		for _, v := range tags {
			q, _ := v.(map[string]any)
			k := strings.ToLower(str(q["key"]))
			if k == "project" || k == "project.id" || k == "service.project" || k == "deployment.project" || k == "resource.project" || k == "resource.project.id" || k == "otel.resource.project.id" {
				if p := str(q["value"]); p != "" {
					return p
				}
			}
		}
	}
	return "unknown"
}
func str(v any) string {
	s, _ := v.(string)
	s = controlRE.ReplaceAllString(strings.ToValidUTF8(s, "�"), "")
	if len(s) > 256 {
		s = s[:256]
	}
	return s
}
func num(v any) float64 { n, _ := v.(float64); return n }
func number(v any) float64 {
	switch n := v.(type) {
	case float64:
		return n
	case json.Number:
		f, _ := n.Float64()
		return f
	case string:
		var f float64
		fmt.Sscanf(n, "%f", &f)
		return f
	}
	return 0
}
func ts(v any) time.Time { return time.Unix(0, int64(num(v))*1000) }

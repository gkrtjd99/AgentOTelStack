package correlation

import "testing"

func TestDecodeCrossProjectAndFailures(t *testing.T) {
	raw := map[string]any{"data": []any{map[string]any{
		"spans": []any{
			map[string]any{"spanID": "a", "operationName": "root", "startTime": float64(1000000), "duration": float64(1000), "processID": "p1", "tags": []any{map[string]any{"key": "http.status_code", "value": float64(503)}}},
			map[string]any{"spanID": "b", "operationName": "child", "startTime": float64(1001000), "duration": float64(100), "processID": "p2", "references": []any{map[string]any{"refType": "CHILD_OF", "spanID": "a"}}},
		}, "processes": map[string]any{"p1": map[string]any{"serviceName": "api", "tags": []any{map[string]any{"key": "project.id", "value": "one"}}}, "p2": map[string]any{"serviceName": "worker", "tags": []any{map[string]any{"key": "project.id", "value": "two"}}}},
	}}}
	r := Decode("0123456789abcdef0123456789abcdef", raw)
	if len(r.Spans) != 2 || len(r.Projects) != 2 || len(r.Failures) != 1 {
		t.Fatalf("unexpected result: %#v", r)
	}
}

func TestDecodeJaegerOmittedReferenceTypeFindsRoot(t *testing.T) {
	raw := map[string]any{"data": []any{map[string]any{
		"spans": []any{
			map[string]any{"spanID": "child", "startTime": float64(2), "references": []any{map[string]any{"spanID": "root"}}},
			map[string]any{"spanID": "root", "startTime": float64(1), "references": []any{}},
		}, "processes": map[string]any{},
	}}}
	if got := Decode("0123456789abcdef0123456789abcdef", raw).RootSpanID; got != "root" {
		t.Fatalf("root=%q", got)
	}
}

func TestDecodeCompletenessIndicators(t *testing.T) {
	id := "0123456789abcdef0123456789abcdef"
	if got := Decode(id, map[string]any{"data": []any{map[string]any{"spans": []any{}}}}); !has(got.Indicators, "trace_not_stored") {
		t.Fatalf("expected trace_not_stored: %#v", got.Indicators)
	}
	// A child whose parent was not exported is observable and must not be
	// presented as a complete trace.
	r := Decode(id, map[string]any{"data": []any{map[string]any{"spans": []any{
		map[string]any{"spanID": "child", "startTime": float64(1), "references": []any{map[string]any{"spanID": "missing", "refType": "CHILD_OF"}}}}}}})
	if !has(r.Indicators, "broken_parent_ref") {
		t.Fatalf("expected broken_parent_ref: %#v", r.Indicators)
	}
}

func has(xs []string, want string) bool {
	for _, x := range xs {
		if x == want {
			return true
		}
	}
	return false
}

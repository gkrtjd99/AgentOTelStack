package main

import (
	"agentotelstack/gateway/internal/query"
	"agentotelstack/gateway/internal/query/correlation"
	"agentotelstack/gateway/internal/status"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	maxBody                 = 8 << 20
	maxHeaderSize           = 16 << 10
	requestLimit            = 10 * time.Second
	defaultQueryConcurrency = 16
	maxQueryConcurrency     = 128
)

var ingestPaths = []string{"/v1/traces", "/v1/metrics", "/v1/logs"}

type config struct {
	token              string
	upstream           string
	maxConcurrent      int
	queryMaxConcurrent int
	queryToken         string
	query              query.Client
	querySem           chan struct{}
}

type configError struct{ s string }

func (e *configError) Error() string { return e.s }

func load() (config, error) {
	token := os.Getenv("GATEWAY_INGEST_TOKEN")
	if path := os.Getenv("GATEWAY_INGEST_TOKEN_FILE"); path != "" {
		var err error
		token, err = tokenFile(path, "ingest_token")
		if err != nil {
			return config{}, err
		}
	}
	if token == "" {
		return config{}, &configError{"missing ingest token"}
	}
	queryToken := os.Getenv("GATEWAY_QUERY_TOKEN")
	if path := os.Getenv("GATEWAY_QUERY_TOKEN_FILE"); path != "" {
		var err error
		queryToken, err = tokenFile(path, "query_token")
		if err != nil {
			return config{}, err
		}
	}
	if queryToken == "" {
		return config{}, &configError{"missing query token"}
	}
	th := sha256.Sum256([]byte(token))
	qh := sha256.Sum256([]byte(queryToken))
	if subtle.ConstantTimeCompare(th[:], qh[:]) == 1 && len(token) == len(queryToken) {
		return config{}, &configError{"ingest and query tokens must differ"}
	}

	upstream := os.Getenv("GATEWAY_COLLECTOR_URL")
	if upstream == "" {
		upstream = "http://otel-collector:4318"
	}
	u, err := url.Parse(upstream)
	if err != nil || u.Scheme != "http" || u.Host == "" || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
		return config{}, &configError{"invalid collector upstream"}
	}
	queryMax, err := boundedConcurrency(os.Getenv("GATEWAY_QUERY_MAX_CONCURRENT"), defaultQueryConcurrency, maxQueryConcurrency)
	if err != nil {
		return config{}, err
	}
	return config{token: token, queryToken: queryToken, upstream: strings.TrimRight(upstream, "/"), maxConcurrent: 32, queryMaxConcurrent: queryMax}, nil
}

func boundedConcurrency(raw string, defaultValue, maximum int) (int, error) {
	if raw == "" {
		return defaultValue, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 || n > maximum {
		return 0, &configError{"invalid query concurrency"}
	}
	return n, nil
}

// tokenFile accepts either a single raw token or the XDG credentials JSON
// emitted by agentotel credentials rotation. It never writes or logs secrets.
func tokenFile(path, key string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	raw := strings.TrimSpace(string(b))
	var credentials map[string]string
	if strings.HasPrefix(raw, "{") && json.Unmarshal(b, &credentials) == nil {
		return strings.TrimSpace(credentials[key]), nil
	}
	return raw, nil
}

func main() {
	c, err := load()
	if err != nil {
		log.Fatal(err)
	}
	sem := make(chan struct{}, c.maxConcurrent)
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/version", version)
	mux.HandleFunc("/v1/health", health)
	for _, path := range ingestPaths {
		mux.Handle(path, ingest(c, sem, path))
	}
	qc := query.Client{Logs: envOr("GATEWAY_LOGS_URL", "http://victorialogs:9428"), Metrics: envOr("GATEWAY_METRICS_URL", "http://victoriametrics:8428"), Traces: envOr("GATEWAY_TRACES_URL", "http://victoriatraces:10428")}
	for _, backend := range []string{qc.Logs, qc.Metrics, qc.Traces} {
		u, e := url.Parse(backend)
		if e != nil || u.Scheme != "http" || u.Host == "" || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
			log.Fatal("invalid query backend URL")
		}
	}
	qcfg := c
	qcfg.query = qc
	qcfg.querySem = make(chan struct{}, c.queryMaxConcurrent)
	server := &http.Server{
		Addr:              "0.0.0.0:4318",
		Handler:           limitHeaders(mux),
		ReadHeaderTimeout: 2 * time.Second,
		ReadTimeout:       requestLimit,
		WriteTimeout:      requestLimit,
		IdleTimeout:       30 * time.Second,
	}
	queryMux := http.NewServeMux()
	for _, p := range []string{"/v1/context", "/v1/errors", "/v1/correlate", "/v1/services"} {
		queryMux.HandleFunc(p, queryHandler(qcfg, p))
	}
	queryMux.HandleFunc("/v1/health", queryHealth(qcfg))
	queryMux.HandleFunc("/v1/version", version)
	queryServer := &http.Server{Addr: "0.0.0.0:17777", Handler: limitHeaders(queryMux), ReadHeaderTimeout: 2 * time.Second, ReadTimeout: requestLimit, WriteTimeout: requestLimit}
	go func() {
		log.Printf("gateway listening on %s", server.Addr)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("gateway stopped: %v", err)
		}
	}()
	go func() {
		log.Printf("gateway query listening on %s", queryServer.Addr)
		if err := queryServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("query gateway stopped: %v", err)
		}
	}()

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	<-signals
	signal.Stop(signals)
	ctx, cancel := context.WithTimeout(context.Background(), requestLimit)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		log.Printf("gateway shutdown: %v", err)
	}
	_ = queryServer.Shutdown(ctx)
}

// queryHealth proves both that the query listener is reachable and that the
// caller supplied the query credential. It deliberately does not contact any
// telemetry backend: backend readiness is reported by the query endpoints.
func queryHealth(c config) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if c.queryToken == "" || !auth(r, c.queryToken) {
			value := r.Header.Get("Authorization")
			log.Printf("query access path=%s status=%d auth=false authorization_present=%t bearer_prefix=%t header_len=%d expected_len=%d", r.URL.Path, http.StatusUnauthorized, value != "", strings.HasPrefix(value, "Bearer "), len(value), len(c.queryToken))
			writeErr(w, http.StatusUnauthorized)
			return
		}
		if r.Method != http.MethodGet {
			log.Printf("query access path=%s status=%d auth=true", r.URL.Path, http.StatusMethodNotAllowed)
			writeErr(w, http.StatusMethodNotAllowed)
			return
		}
		log.Printf("query access path=%s status=%d auth=true", r.URL.Path, http.StatusOK)
		health(w, r)
	}
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
func queryHandler(c config, path string) http.HandlerFunc {
	sem := c.querySem
	if sem == nil {
		n := c.queryMaxConcurrent
		if n < 1 || n > maxQueryConcurrency {
			n = defaultQueryConcurrency
		}
		sem = make(chan struct{}, n)
	}
	return func(w http.ResponseWriter, r *http.Request) {
		if c.queryToken == "" || !auth(r, c.queryToken) {
			writeErr(w, http.StatusUnauthorized)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodPost {
			writeErr(w, 405)
			return
		}
		var in struct {
			Service  string `json:"service"`
			TraceID  string `json:"trace_id"`
			Project  string `json:"project"`
			Lookback string `json:"lookback"`
			Limit    int    `json:"limit"`
		}
		if r.Method == http.MethodPost {
			dec := json.NewDecoder(io.LimitReader(r.Body, 64<<10))
			dec.DisallowUnknownFields()
			if dec.Decode(&in) != nil {
				writeErr(w, 400)
				return
			}
			var extra any
			if dec.Decode(&extra) != io.EOF {
				writeErr(w, 400)
				return
			}
		} else {
			in.Service = r.URL.Query().Get("service")
			in.TraceID = r.URL.Query().Get("trace_id")
			in.Project = r.URL.Query().Get("project")
			in.Lookback = r.URL.Query().Get("lookback")
			for k := range r.URL.Query() {
				if k != "service" && k != "trace_id" && k != "project" && k != "lookback" && k != "limit" {
					writeErr(w, 400)
					return
				}
			}
			if n := r.URL.Query().Get("limit"); n != "" {
				parsed, e := strconv.Atoi(n)
				if e != nil || strconv.Itoa(parsed) != n {
					writeErr(w, 400)
					return
				}
				in.Limit = parsed
			}
		}
		if in.Limit == 0 {
			in.Limit = 50
		}
		if in.Service != "" {
			if query.ValidateService(in.Service) != nil {
				writeErr(w, 400)
				return
			}
		}
		if in.TraceID != "" && query.ValidateTraceID(in.TraceID) != nil {
			writeErr(w, 400)
			return
		}
		if path == "/v1/correlate" && in.TraceID == "" {
			writeErr(w, 400)
			return
		}
		if query.ValidateProject(in.Project) != nil || query.Limit(in.Limit) != nil {
			writeErr(w, 400)
			return
		}
		if in.Lookback == "" {
			in.Lookback = "15m"
		}
		if _, e := query.Lookback(in.Lookback); e != nil {
			writeErr(w, 400)
			return
		}
		select {
		case sem <- struct{}{}:
			defer func() { <-sem }()
		default:
			writeQueryOverloaded(w)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()
		data := map[string]any{"items": []any{}}
		backs := []status.Backend{}
		add := func(name string, v any, e error) {
			if e != nil {
				backs = append(backs, status.Backend{Name: name, Status: backendStatus(e), Error: safeError(e)})
				return
			}
			backs = append(backs, status.Backend{Name: name, Status: "ok"})
			data[name] = project(v)
		}
		end := time.Now()
		lb, _ := query.Lookback(in.Lookback)
		start := end.Add(-lb)
		switch path {
		case "/v1/services":
			v, e := retry(ctx, func() (any, error) { return c.query.Services(ctx) })
			add("traces", v, e)
		case "/v1/errors":
			v, e := retry(ctx, func() (any, error) {
				return c.query.LogsErrorsScoped(ctx, in.Service, in.Project, start, end, in.Limit)
			})
			add("logs", v, e)
			v, e = retry(ctx, func() (any, error) { return c.query.TracesQueryScoped(ctx, in.Service, in.Project, in.Limit) })
			add("traces", v, e)
		case "/v1/context":
			v, e := retry(ctx, func() (any, error) { return c.query.LogsQueryScoped(ctx, in.Service, in.Project, start, end, in.Limit) })
			add("logs", v, e)
			v, e = retry(ctx, func() (any, error) {
				return c.query.MetricsQueryScoped(ctx, in.Service, in.Project, start, end, 15*time.Second)
			})
			add("metrics", v, e)
		case "/v1/correlate":
			v, e := retry(ctx, func() (any, error) { return c.query.TraceQueryScoped(ctx, in.TraceID, in.Project) })
			if e == nil {
				r := correlation.Decode(in.TraceID, v)
				ls, le := traceWindow(v, start, end)
				lv, le2 := retry(ctx, func() (any, error) { return c.query.LogsTraceScoped(ctx, in.TraceID, in.Project, ls, le, in.Limit) })
				if le2 == nil {
					r.Logs = project(lv)
					backs = append(backs, status.Backend{Name: "logs", Status: "ok"})
				} else {
					backs = append(backs, status.Backend{Name: "logs", Status: backendStatus(le2), Error: safeError(le2)})
					r.Indicators = append(r.Indicators, "signal_not_observed")
				}
				mv, me := retry(ctx, func() (any, error) {
					return c.query.MetricsTraceScoped(ctx, r.Services, in.Project, ls, le, 15*time.Second)
				})
				if me == nil {
					r.Metrics = project(mv)
					backs = append(backs, status.Backend{Name: "metrics", Status: "ok"})
				} else {
					backs = append(backs, status.Backend{Name: "metrics", Status: backendStatus(me), Error: safeError(me)})
					r.Indicators = append(r.Indicators, "metrics_unavailable")
				}
				data["correlation"] = r
				backs = append(backs, status.Backend{Name: "traces", Status: "ok"})
			} else {
				add("traces", v, e)
			}
		}
		partial := false
		for _, b := range backs {
			if b.Status != "ok" {
				partial = true
			}
		}
		writeEnvelope(w, status.Envelope{SchemaVersion: "1.0", Data: data, Partial: partial, ContentTrust: "untrusted_telemetry", Backends: backs})
	}
}

var ansiRE = regexp.MustCompile(`[\x00-\x1f\x7f-\x9f\x1b]`)

func clean(s string) string { return ansiRE.ReplaceAllString(strings.ToValidUTF8(s, "�"), "") }
func project(v any) any {
	switch x := v.(type) {
	case string:
		return clean(x)
	case []any:
		for i := range x {
			x[i] = project(x[i])
		}
		return x
	case map[string]any:
		out := map[string]any{}
		for k, val := range x {
			lk := strings.ToLower(k)
			allowed := map[string]bool{"data": true, "items": true, "traceid": true, "trace_id": true, "spanid": true, "span_id": true, "operationname": true, "operation": true, "starttime": true, "start_time": true, "duration": true, "duration_ms": true, "processid": true, "process_id": true, "references": true, "spans": true, "processes": true, "service": true, "service_name": true, "status": true, "status_code": true, "severity_text": true, "message": true, "time": true, "timestamp": true, "metric": true, "value": true, "values": true, "result": true, "resulttype": true, "type": true, "name": true}
			if !allowed[lk] || strings.Contains(lk, "query") || strings.Contains(lk, "prompt") || strings.Contains(lk, "secret") || strings.Contains(lk, "token") || strings.Contains(lk, "password") || strings.Contains(lk, "body") || strings.Contains(lk, "sql") || strings.Contains(lk, "url") {
				continue
			}
			out[clean(k)] = project(val)
		}
		return out
	default:
		return v
	}
}
func retry(ctx context.Context, fn func() (any, error)) (any, error) {
	var v any
	var e error
	for i := 0; i < 2; i++ {
		v, e = fn()
		if e == nil {
			return v, nil
		}
		t := time.NewTimer(time.Duration(i+1) * 20 * time.Millisecond)
		select {
		case <-ctx.Done():
			t.Stop()
			return nil, ctx.Err()
		case <-t.C:
		}
	}
	return v, e
}
func backendStatus(e error) string {
	if errors.Is(e, query.ErrTraceNotStored) {
		return "trace_not_stored"
	}
	if errors.Is(e, query.ErrNoData) {
		return "no_matching_data"
	}
	if errors.Is(e, query.ErrBackendDecode) {
		return "backend_decode_error"
	}
	if errors.Is(e, query.ErrBackendResponse) {
		return "backend_unavailable"
	}
	if strings.Contains(e.Error(), "context deadline") || strings.Contains(e.Error(), "timeout") {
		return "timeout"
	}
	return "backend_unavailable"
}
func traceWindow(v any, fallbackStart, fallbackEnd time.Time) (time.Time, time.Time) {
	minT, maxT := time.Time{}, time.Time{}
	var walk func(any)
	walk = func(x any) {
		switch z := x.(type) {
		case map[string]any:
			for k, vv := range z {
				lk := strings.ToLower(k)
				if lk == "starttime" || lk == "start_time" {
					if n, ok := vv.(float64); ok {
						t := time.Unix(0, int64(n)*1000)
						if minT.IsZero() || t.Before(minT) {
							minT = t
						}
						if maxT.IsZero() || t.After(maxT) {
							maxT = t
						}
					}
				}
				if lk == "duration" {
					if n, ok := vv.(float64); ok && !minT.IsZero() {
						t := minT.Add(time.Duration(n) * time.Microsecond)
						if t.After(maxT) {
							maxT = t
						}
					}
				}
				walk(vv)
			}
		case []any:
			for _, vv := range z {
				walk(vv)
			}
		}
	}
	walk(v)
	if minT.IsZero() {
		return fallbackStart.Add(-2 * time.Minute), fallbackEnd.Add(2 * time.Minute)
	}
	return minT.Add(-2 * time.Minute), maxT.Add(2 * time.Minute)
}
func safeError(e error) string {
	msg := clean(e.Error())
	if strings.Contains(msg, "backend status") {
		return "backend returned an error"
	}
	if strings.Contains(msg, "dial ") || strings.Contains(msg, "lookup ") || strings.Contains(msg, "connection ") {
		return "backend unavailable"
	}
	if strings.Contains(msg, "context deadline") || strings.Contains(msg, "timeout") {
		return "backend timeout"
	}
	if len(msg) > 160 {
		msg = msg[:160]
	}
	return msg
}
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
func writeEnvelope(w http.ResponseWriter, e status.Envelope) {
	b, _ := json.Marshal(e)
	if len(b) > 1<<20 {
		e.Truncated = true
		e.Warnings = []string{"response_size_limit"}
		e.Data = map[string]any{"items": []any{}}
		b, _ = json.Marshal(e)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(b)
	_, _ = w.Write([]byte("\n"))
}

func limitHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		size := 0
		for key, values := range r.Header {
			size += len(key)
			for _, value := range values {
				size += len(value)
			}
		}
		if size > maxHeaderSize {
			writeErr(w, http.StatusRequestHeaderFieldsTooLarge)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func auth(r *http.Request, expected string) bool {
	value := r.Header.Get("Authorization")
	if !strings.HasPrefix(value, "Bearer ") {
		return false
	}
	got := strings.TrimPrefix(value, "Bearer ")
	// Hashing makes the constant-time comparison independent of token length.
	expectedHash := sha256.Sum256([]byte(expected))
	gotHash := sha256.Sum256([]byte(got))
	return subtle.ConstantTimeCompare(expectedHash[:], gotHash[:]) == 1 && len(got) == len(expected)
}

func ingest(c config, sem chan struct{}, path string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		status := handleIngest(c, sem, path, w, r)
		// Never log body, token, or request headers.
		log.Printf("access path=%s status=%d duration_ms=%d", path, status, time.Since(start).Milliseconds())
	})
}

func handleIngest(c config, sem chan struct{}, path string, w http.ResponseWriter, r *http.Request) int {
	if !auth(r, c.token) {
		writeErr(w, http.StatusUnauthorized)
		return http.StatusUnauthorized
	}
	if r.Method != http.MethodPost || r.URL.Path != path {
		writeErr(w, http.StatusMethodNotAllowed)
		return http.StatusMethodNotAllowed
	}
	contentType := strings.TrimSpace(strings.SplitN(r.Header.Get("Content-Type"), ";", 2)[0])
	if !strings.EqualFold(contentType, "application/x-protobuf") {
		writeErr(w, http.StatusBadRequest)
		return http.StatusBadRequest
	}
	if encoding := r.Header.Get("Content-Encoding"); encoding != "" && !strings.EqualFold(encoding, "identity") {
		writeErr(w, http.StatusBadRequest)
		return http.StatusBadRequest
	}
	if r.ContentLength > maxBody {
		writeErr(w, http.StatusRequestEntityTooLarge)
		return http.StatusRequestEntityTooLarge
	}
	select {
	case sem <- struct{}{}:
		defer func() { <-sem }()
	default:
		writeErr(w, http.StatusTooManyRequests)
		return http.StatusTooManyRequests
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBody+1))
	if err != nil || len(body) > maxBody {
		writeErr(w, http.StatusRequestEntityTooLarge)
		return http.StatusRequestEntityTooLarge
	}
	ctx, cancel := context.WithTimeout(r.Context(), requestLimit)
	defer cancel()
	forward, err := http.NewRequestWithContext(ctx, http.MethodPost, c.upstream+path, strings.NewReader(string(body)))
	if err != nil {
		writeErr(w, http.StatusBadGateway)
		return http.StatusBadGateway
	}
	forward.Header.Set("Content-Type", "application/x-protobuf")
	// Deliberately forward only the required content type. This excludes all
	// credentials, cookies, proxy and hop-by-hop headers.
	// OTLP forwarding is a write operation and must never follow a redirect to
	// an untrusted host. In particular, following a 307 could disclose the
	// complete telemetry body to the redirect target.
	forwardClient := *http.DefaultClient
	forwardClient.CheckRedirect = func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}
	resp, err := forwardClient.Do(forward)
	if err != nil {
		if ctx.Err() != nil {
			writeErr(w, http.StatusGatewayTimeout)
			return http.StatusGatewayTimeout
		}
		writeErr(w, http.StatusBadGateway)
		return http.StatusBadGateway
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode >= 500 {
		writeErr(w, http.StatusBadGateway)
		return http.StatusBadGateway
	}
	w.WriteHeader(resp.StatusCode)
	return resp.StatusCode
}

func version(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeErr(w, http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"schema_version": "1.0", "gateway_version": "2.0.0", "api_min": "1.0", "api_max": "1.0",
		"capabilities": []string{"ingest", "version", "health"},
		"ingest":       map[string]interface{}{"paths": ingestPaths, "content_type": "application/x-protobuf", "max_body_bytes": maxBody, "max_header_bytes": maxHeaderSize},
	})
}

func health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeErr(w, http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func writeErr(w http.ResponseWriter, status int) {
	http.Error(w, http.StatusText(status), status)
}

func writeQueryOverloaded(w http.ResponseWriter) {
	w.Header().Set("Retry-After", "1")
	http.Error(w, "query overloaded", http.StatusTooManyRequests)
}

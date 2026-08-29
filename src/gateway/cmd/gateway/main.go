package main

import (
	"agentotelstack/gateway/internal/query"
	"agentotelstack/gateway/internal/query/correlation"
	"agentotelstack/gateway/internal/status"
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	maxBody                 = 8 << 20
	maxHeaderSize           = 16 << 10
	requestLimit            = 10 * time.Second
	defaultQueryConcurrency = 16
	maxQueryConcurrency     = 128
	defaultIngestListenAddr = "0.0.0.0:4318"
	defaultQueryListenAddr  = "0.0.0.0:17777"
)

var ingestPaths = []string{"/v1/traces", "/v1/metrics", "/v1/logs"}

// Injected by the container build; direct local builds identify themselves as
// dev rather than advertising a stale release.
var buildVersion = "dev"

func gatewayVersion() string { return envOr("GATEWAY_VERSION", buildVersion) }

var forwardHTTPClient = &http.Client{
	Transport: http.DefaultTransport,
	CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	},
}

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
	qc := query.Client{Logs: envOr("GATEWAY_LOGS_URL", "http://victorialogs:9428"), Metrics: envOr("GATEWAY_METRICS_URL", "http://victoriametrics:8428"), Traces: envOr("GATEWAY_TRACES_URL", "http://victoriatraces:10428"), HTTP: query.NewHTTPClient(nil)}
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
		Addr:              envOr("GATEWAY_INGEST_LISTEN_ADDR", defaultIngestListenAddr),
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
	queryMux.HandleFunc("/v1/version", queryVersion)
	queryServer := &http.Server{Addr: envOr("GATEWAY_QUERY_LISTEN_ADDR", defaultQueryListenAddr), Handler: limitHeaders(queryMux), ReadHeaderTimeout: 2 * time.Second, ReadTimeout: requestLimit, WriteTimeout: requestLimit}

	// Bind both sockets before starting either HTTP server. If the second bind
	// fails, the first socket is closed and startup returns nonzero instead of
	// leaving a half-working gateway waiting forever for a signal.
	ingestListener, queryListener, err := bindListeners(server.Addr, queryServer.Addr)
	if err != nil {
		log.Fatal(err)
	}
	defer ingestListener.Close()
	defer queryListener.Close()

	serveErrors := make(chan error, 2)
	go serve(server, ingestListener, "gateway", serveErrors)
	go serve(queryServer, queryListener, "query gateway", serveErrors)

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	select {
	case <-signals:
		signal.Stop(signals)
	case err := <-serveErrors:
		signal.Stop(signals)
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("gateway listener stopped: %v", err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), requestLimit)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		log.Printf("gateway shutdown: %v", err)
	}
	if err := queryServer.Shutdown(ctx); err != nil {
		log.Printf("query gateway shutdown: %v", err)
	}
}

func bindListeners(ingestAddr, queryAddr string) (net.Listener, net.Listener, error) {
	if strings.TrimSpace(ingestAddr) == "" || strings.TrimSpace(queryAddr) == "" || strings.ContainsAny(ingestAddr+queryAddr, "\r\n") {
		return nil, nil, errors.New("invalid gateway listen address")
	}
	ingest, err := net.Listen("tcp", ingestAddr)
	if err != nil {
		return nil, nil, fmt.Errorf("bind gateway ingest listener %q: %w", ingestAddr, err)
	}
	query, err := net.Listen("tcp", queryAddr)
	if err != nil {
		_ = ingest.Close()
		return nil, nil, fmt.Errorf("bind gateway query listener %q: %w", queryAddr, err)
	}
	return ingest, query, nil
}

func serve(server *http.Server, listener net.Listener, name string, serveErrors chan<- error) {
	log.Printf("%s listening on %s", name, listener.Addr())
	serveErrors <- server.Serve(listener)
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
func gatewayEnvelopeKind(path string) string {
	return "gateway." + strings.TrimPrefix(path, "/v1/") + ".v1"
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
			if in.Project == "" {
				v, e := retry(ctx, func() (any, error) { return c.query.Services(ctx) })
				add("traces", v, e)
				break
			}
			results := runBackendQueries(ctx, []backendQuery{
				{name: "logs", fn: func(ctx context.Context) (any, error) {
					return retry(ctx, func() (any, error) { return c.query.LogsQueryScoped(ctx, "", in.Project, start, end, 500) })
				}},
				{name: "metrics", fn: func(ctx context.Context) (any, error) {
					return retry(ctx, func() (any, error) {
						return c.query.MetricsQueryScoped(ctx, "", in.Project, start, end, 15*time.Second)
					})
				}},
			})
			services := map[string]struct{}{}
			for _, result := range results {
				add(result.name, result.value, result.err)
				if result.err == nil {
					collectServiceNames(result.value, services)
				}
			}
			names := make([]string, 0, len(services))
			for name := range services {
				names = append(names, name)
			}
			sort.Strings(names)
			data["services"] = names
		case "/v1/errors":
			results := runBackendQueries(ctx, []backendQuery{
				{name: "logs", fn: func(ctx context.Context) (any, error) {
					return retry(ctx, func() (any, error) {
						return c.query.LogsErrorsScoped(ctx, in.Service, in.Project, start, end, in.Limit)
					})
				}},
				{name: "traces", fn: func(ctx context.Context) (any, error) {
					return retry(ctx, func() (any, error) {
						return c.query.TracesQueryScoped(ctx, in.Service, in.Project, start, end, in.Limit)
					})
				}},
			})
			for _, result := range results {
				add(result.name, result.value, result.err)
			}
		case "/v1/context":
			results := runBackendQueries(ctx, []backendQuery{
				{name: "logs", fn: func(ctx context.Context) (any, error) {
					return retry(ctx, func() (any, error) { return c.query.LogsQueryScoped(ctx, in.Service, in.Project, start, end, in.Limit) })
				}},
				{name: "metrics", fn: func(ctx context.Context) (any, error) {
					return retry(ctx, func() (any, error) {
						return c.query.MetricsQueryScoped(ctx, in.Service, in.Project, start, end, 15*time.Second)
					})
				}},
			})
			for _, result := range results {
				add(result.name, result.value, result.err)
			}
		case "/v1/correlate":
			v, e := retry(ctx, func() (any, error) { return c.query.TraceQueryScoped(ctx, in.TraceID, in.Project) })
			if e == nil {
				r := correlation.Decode(in.TraceID, v)
				ls, le := start, end
				if !r.StartTime.IsZero() && !r.EndTime.IsZero() {
					ls, le = r.StartTime.Add(-2*time.Minute), r.EndTime.Add(2*time.Minute)
				}
				results := runBackendQueries(ctx, []backendQuery{
					{name: "logs", fn: func(ctx context.Context) (any, error) {
						return retry(ctx, func() (any, error) { return c.query.LogsTraceScoped(ctx, in.TraceID, in.Project, ls, le, in.Limit) })
					}},
					{name: "metrics", fn: func(ctx context.Context) (any, error) {
						return retry(ctx, func() (any, error) {
							return c.query.MetricsTraceScoped(ctx, r.Services, in.Project, ls, le, 15*time.Second)
						})
					}},
				})
				for _, result := range results {
					if result.err == nil {
						if result.name == "logs" {
							r.Logs = project(result.value)
						} else {
							r.Metrics = project(result.value)
						}
						backs = append(backs, status.Backend{Name: result.name, Status: "ok"})
						continue
					}
					backs = append(backs, status.Backend{Name: result.name, Status: backendStatus(result.err), Error: safeError(result.err)})
					if result.name == "logs" {
						r.Indicators = append(r.Indicators, "signal_not_observed")
					} else {
						r.Indicators = append(r.Indicators, "metrics_unavailable")
					}
				}
				data["correlation"] = r
				backs = append(backs, status.Backend{Name: "traces", Status: "ok"})
			} else {
				add("traces", v, e)
			}
		}
		partial := false
		for _, b := range backs {
			if backendOperationalFailure(b.Status) {
				partial = true
			}
		}
		writeEnvelope(w, status.Envelope{
			SchemaVersion: "1.0",
			Kind:          gatewayEnvelopeKind(path),
			Data:          data,
			Partial:       partial,
			Freshness:     end.UTC().Format(time.RFC3339Nano),
			Scope: status.Scope{
				Project:  in.Project,
				Service:  in.Service,
				TraceID:  in.TraceID,
				Lookback: in.Lookback,
				Limit:    in.Limit,
			},
			ContentTrust: "untrusted_telemetry",
			Backends:     backs,
		})
	}
}

func collectServiceNames(v any, out map[string]struct{}) {
	switch x := v.(type) {
	case []any:
		for _, item := range x {
			collectServiceNames(item, out)
		}
	case map[string]any:
		for key, value := range x {
			if key == "service" || key == "service_name" || key == "service.name" {
				if name, ok := value.(string); ok && query.ValidateService(name) == nil {
					out[name] = struct{}{}
				}
			}
			collectServiceNames(value, out)
		}
	}
}

type backendQuery struct {
	name string
	fn   func(context.Context) (any, error)
}

type backendResult struct {
	name  string
	value any
	err   error
}

// runBackendQueries starts all independent backend calls before waiting for
// any result. Results are written back by input index so response ordering is
// deterministic even though completion order is not.
func runBackendQueries(ctx context.Context, queries []backendQuery) []backendResult {
	results := make([]backendResult, len(queries))
	var wg sync.WaitGroup
	wg.Add(len(queries))
	for i, backend := range queries {
		i, backend := i, backend
		go func() {
			defer wg.Done()
			value, err := backend.fn(ctx)
			results[i] = backendResult{name: backend.name, value: value, err: err}
		}()
	}
	wg.Wait()
	return results
}

var ansiRE = regexp.MustCompile(`[\x00-\x1f\x7f-\x9f\x1b]`)

var projectionKeys = map[string]struct{}{
	"data": {}, "items": {}, "traceid": {}, "trace_id": {}, "spanid": {}, "span_id": {},
	"operationname": {}, "operation": {}, "starttime": {}, "start_time": {}, "duration": {},
	"duration_ms": {}, "processid": {}, "process_id": {}, "references": {}, "spans": {},
	"processes": {}, "service": {}, "service_name": {}, "service.name": {}, "servicename": {}, "status": {}, "status_code": {},
	"severity_text": {}, "message": {}, "time": {}, "timestamp": {}, "_time": {}, "metric": {}, "value": {},
	"values": {}, "result": {}, "resulttype": {}, "type": {}, "name": {},
}

func clean(s string) string { return ansiRE.ReplaceAllString(strings.ToValidUTF8(s, "�"), "") }

// projectProcesses preserves Jaeger's process IDs as map keys so spans can be
// joined to their canonical process serviceName. The process values still pass
// through the same allowlist; arbitrary telemetry fields never become allowed
// merely because they are nested below this container.
func projectProcesses(v any) any {
	m, ok := v.(map[string]any)
	if !ok {
		return project(v)
	}
	out := map[string]any{}
	for k, value := range m {
		key := clean(k)
		if key == "" || len(key) > 128 {
			continue
		}
		out[key] = project(value)
	}
	return out
}

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
			if _, allowed := projectionKeys[lk]; !allowed || strings.Contains(lk, "query") || strings.Contains(lk, "prompt") || strings.Contains(lk, "secret") || strings.Contains(lk, "token") || strings.Contains(lk, "password") || strings.Contains(lk, "body") || strings.Contains(lk, "sql") || strings.Contains(lk, "url") {
				continue
			}
			if lk == "processes" {
				out[clean(k)] = projectProcesses(val)
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
	for attempt := 0; attempt < 2; attempt++ {
		v, e := fn()
		if e == nil {
			return v, nil
		}
		if attempt == 1 || !retryable(e) {
			return nil, e
		}
		t := time.NewTimer(20 * time.Millisecond)
		select {
		case <-ctx.Done():
			t.Stop()
			return nil, ctx.Err()
		case <-t.C:
		}
	}
	panic("unreachable")
}

func retryable(err error) bool {
	var backendErr query.BackendHTTPError
	if errors.As(err, &backendErr) {
		return backendErr.StatusCode == http.StatusTooManyRequests || backendErr.StatusCode == http.StatusBadGateway || backendErr.StatusCode == http.StatusServiceUnavailable || backendErr.StatusCode == http.StatusGatewayTimeout
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	var netErr interface {
		error
		Timeout() bool
		Temporary() bool
	}
	return errors.As(err, &netErr) && (netErr.Timeout() || netErr.Temporary())
}

// backendOperationalFailure keeps evidence absence distinct from an outage.
// no_matching_data, trace_not_stored, and signal_not_observed are valid query
// outcomes; unavailable, timeout, decode, and integrity failures are partial.
func backendOperationalFailure(status string) bool {
	switch status {
	case "ok", "no_matching", "no_matching_data", "trace_not_stored", "signal_not_observed", "unsupported":
		return false
	default:
		return true
	}
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
	forward, err := http.NewRequestWithContext(ctx, http.MethodPost, c.upstream+path, bytes.NewReader(body))
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
	resp, err := forwardHTTPClient.Do(forward)
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
	writeVersion(w, r, []string{"ingest", "version", "health"}, true)
}

func queryVersion(w http.ResponseWriter, r *http.Request) {
	writeVersion(w, r, []string{"context", "errors", "correlate", "services"}, false)
}

func writeVersion(w http.ResponseWriter, r *http.Request, capabilities []string, includeIngest bool) {
	if r.Method != http.MethodGet {
		writeErr(w, http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	body := map[string]interface{}{
		"schema_version": "1.0", "gateway_version": gatewayVersion(), "api_min": "1.0", "api_max": "1.0",
		"capabilities": capabilities,
	}
	if includeIngest {
		body["ingest"] = map[string]interface{}{"paths": ingestPaths, "content_type": "application/x-protobuf", "max_body_bytes": maxBody, "max_header_bytes": maxHeaderSize}
	}
	_ = json.NewEncoder(w).Encode(body)
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

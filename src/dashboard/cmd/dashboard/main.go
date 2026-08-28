package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"agentotelstack/dashboard/internal/proxy"
	"agentotelstack/dashboard/internal/ui"
)

const (
	defaultGatewayURL  = "http://gateway:17777"
	defaultListenAddr  = "127.0.0.1:3000"
	healthcheckTimeout = 750 * time.Millisecond
	serverTimeout      = 8 * time.Second
	maxHeaderBytes     = 16 << 10
	clientTokenLength  = 64
)

var clientTokenRE = regexp.MustCompile(`^[0-9a-f]{64}$`)

type config struct {
	gatewayURL  string
	queryToken  string
	clientToken string
	projectID   string
	listenAddr  string
}

func load() (config, error) {
	listenAddr := envOr("DASHBOARD_LISTEN_ADDR", defaultListenAddr)
	c := config{
		gatewayURL:  envOr("DASHBOARD_GATEWAY_URL", defaultGatewayURL),
		queryToken:  os.Getenv("DASHBOARD_QUERY_TOKEN"),
		clientToken: os.Getenv("DASHBOARD_CLIENT_TOKEN"),
		projectID:   os.Getenv("DASHBOARD_PROJECT_ID"),
		listenAddr:  listenAddr,
	}
	if err := validateListenAddr(listenAddr); err != nil {
		return config{}, err
	}
	if err := validateClientToken(c.clientToken); err != nil {
		return config{}, err
	}
	if c.clientToken == c.queryToken {
		return config{}, errors.New("dashboard client and query tokens must differ")
	}
	if err := proxy.ValidateConfig(proxy.Config{GatewayURL: c.gatewayURL, QueryToken: c.queryToken, ProjectID: c.projectID}); err != nil {
		return config{}, err
	}
	return c, nil
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func validateClientToken(token string) error {
	if len(token) != clientTokenLength || !clientTokenRE.MatchString(token) {
		return errors.New("invalid dashboard client token")
	}
	return nil
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		listenAddr := envOr("DASHBOARD_LISTEN_ADDR", defaultListenAddr)
		target, err := healthcheckTarget(listenAddr)
		if err != nil {
			os.Exit(1)
		}
		os.Exit(runHealthcheck(target))
	}
	c, err := load()
	if err != nil {
		log.Fatal(err)
	}
	handler, err := newHandler(c)
	if err != nil {
		log.Fatal(err)
	}
	server := &http.Server{
		Addr:              c.listenAddr,
		Handler:           handler,
		ReadHeaderTimeout: 2 * time.Second,
		ReadTimeout:       serverTimeout,
		WriteTimeout:      serverTimeout,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    maxHeaderBytes,
	}
	// Bind before starting the server so an occupied or malformed address is a
	// fatal startup error rather than a goroutine that waits forever for a signal.
	listener, err := bindListener(server.Addr)
	if err != nil {
		log.Fatalf("bind dashboard listener %q: %v", server.Addr, err)
	}
	defer listener.Close()
	serveErrors := make(chan error, 1)
	go func() {
		log.Printf("dashboard listening on %s", listener.Addr())
		serveErrors <- server.Serve(listener)
	}()

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	select {
	case <-signals:
		signal.Stop(signals)
	case err := <-serveErrors:
		signal.Stop(signals)
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("dashboard listener stopped: %v", err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), serverTimeout)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		log.Printf("dashboard shutdown: %v", err)
	}
}

func validateListenAddr(addr string) error {
	if strings.TrimSpace(addr) == "" || strings.ContainsAny(addr, "\r\n") {
		return errors.New("invalid dashboard listen address")
	}
	host, port, err := net.SplitHostPort(addr)
	if err != nil || port == "" {
		return errors.New("invalid dashboard listen address")
	}
	portNumber, err := strconv.Atoi(port)
	if err != nil || portNumber < 0 || portNumber > 65535 {
		return errors.New("invalid dashboard listen address")
	}
	if host == "" || host == "0.0.0.0" || host == "::" || strings.EqualFold(host, "localhost") {
		return nil
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return errors.New("invalid dashboard listen address")
	}
	return nil
}

func healthcheckTarget(addr string) (string, error) {
	if err := validateListenAddr(addr); err != nil {
		return "", err
	}
	host, port, _ := net.SplitHostPort(addr)
	if port == "0" {
		return "", errors.New("invalid dashboard healthcheck port")
	}
	if host == "" || host == "0.0.0.0" || strings.EqualFold(host, "localhost") {
		host = "127.0.0.1"
	} else if host == "::" {
		host = "::1"
	}
	return "http://" + net.JoinHostPort(host, port) + "/health", nil
}

func bindListener(addr string) (net.Listener, error) {
	if err := validateListenAddr(addr); err != nil {
		return nil, err
	}
	return net.Listen("tcp", addr)
}

func runHealthcheck(target string) int {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	client := &http.Client{Transport: transport, Timeout: healthcheckTimeout}
	resp, err := client.Get(target)
	if err != nil {
		return 1
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}

func newHandler(c config) (http.Handler, error) {
	adapter, err := proxy.New(proxy.Config{GatewayURL: c.gatewayURL, QueryToken: c.queryToken, ProjectID: c.projectID})
	if err != nil {
		return nil, err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/health", health)
	mux.Handle("/api/", dashboardClientAuth(adapter, c.clientToken))
	mux.Handle("/", ui.Handler())
	return securityHeaders(mux), nil
}

func dashboardClientAuth(next http.Handler, expected string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authorization := r.Header.Values("Authorization")
		if len(authorization) != 1 || !validDashboardAuthorization(authorization[0], expected) {
			httpJSONError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func validDashboardAuthorization(value, expected string) bool {
	prefix := "Dashboard "
	if !strings.HasPrefix(value, prefix) {
		return false
	}
	token := strings.TrimPrefix(value, prefix)
	if validateClientToken(token) != nil || validateClientToken(expected) != nil {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(token), []byte(expected)) == 1
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		// Docker Desktop/OrbStack can route a container on the app edge to a
		// published service IP even when the services do not share a Docker
		// network. Reject direct numeric-IP host requests at the HTTP boundary;
		// normal host-published browser requests use loopback or localhost.
		if nonLoopbackHost(r.Host) {
			httpJSONError(w, http.StatusForbidden, "host_not_allowed")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func nonLoopbackHost(raw string) bool {
	return !allowedHost(raw)
}

func allowedHost(raw string) bool {
	if raw == "" || strings.TrimSpace(raw) != raw {
		return false
	}
	host := raw
	if strings.HasPrefix(raw, "[") {
		end := strings.IndexByte(raw, ']')
		if end < 0 {
			return false
		}
		host = raw[1:end]
		rest := raw[end+1:]
		if !strings.Contains(host, ":") || (rest != "" && (len(rest) < 2 || rest[0] != ':' || !validHostPort(rest[1:]))) {
			return false
		}
	} else {
		if strings.Count(raw, ":") > 0 {
			if strings.Count(raw, ":") != 1 {
				return false
			}
			separator := strings.LastIndexByte(raw, ':')
			host, raw = raw[:separator], raw[separator+1:]
			if !validHostPort(raw) {
				return false
			}
		}
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	if strings.Contains(host, ":") {
		return net.ParseIP(host) != nil && net.ParseIP(host).Equal(net.ParseIP("::1"))
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.To4() != nil && ip.To4()[0] == 127
}

func validHostPort(port string) bool {
	if port == "" {
		return false
	}
	for _, r := range port {
		if r < '0' || r > '9' {
			return false
		}
	}
	n, err := strconv.Atoi(port)
	return err == nil && n >= 1 && n <= 65535
}

func health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		httpJSONError(w, http.StatusMethodNotAllowed, "method_not_allowed")
		return
	}
	if r.URL.RawQuery != "" {
		httpJSONError(w, http.StatusBadRequest, "invalid_query")
		return
	}
	if !localRequest(r) {
		httpJSONError(w, http.StatusForbidden, "local_only")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func localRequest(r *http.Request) bool {
	if r.RemoteAddr == "" {
		return false
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = strings.Trim(r.RemoteAddr, "[]")
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func httpJSONError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(`{"error":"` + code + `"}` + "\n"))
}

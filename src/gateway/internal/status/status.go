package status

type Backend struct {
	Name   string `json:"name"`
	Status string `json:"status"`
	Error  string `json:"error,omitempty"`
}

type Scope struct {
	Project  string `json:"project,omitempty"`
	Service  string `json:"service,omitempty"`
	TraceID  string `json:"trace_id,omitempty"`
	Lookback string `json:"lookback,omitempty"`
	Limit    int    `json:"limit,omitempty"`
}

type Envelope struct {
	SchemaVersion string    `json:"schema_version"`
	Kind          string    `json:"kind"`
	Data          any       `json:"data"`
	Partial       bool      `json:"partial"`
	Truncated     bool      `json:"truncated"`
	Warnings      []string  `json:"warnings,omitempty"`
	Freshness     string    `json:"freshness"`
	Scope         Scope     `json:"scope"`
	ContentTrust  string    `json:"content_trust"`
	Backends      []Backend `json:"backends,omitempty"`
}

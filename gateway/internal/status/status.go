package status

type Backend struct {
	Name   string `json:"name"`
	Status string `json:"status"`
	Error  string `json:"error,omitempty"`
}
type Envelope struct {
	SchemaVersion string         `json:"schema_version"`
	Data          any            `json:"data"`
	Partial       bool           `json:"partial"`
	Truncated     bool           `json:"truncated"`
	Warnings      []string       `json:"warnings,omitempty"`
	Freshness     string         `json:"freshness,omitempty"`
	Scope         map[string]any `json:"scope,omitempty"`
	ContentTrust  string         `json:"content_trust"`
	Backends      []Backend      `json:"backends,omitempty"`
}

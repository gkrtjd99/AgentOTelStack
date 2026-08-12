package query

import (
	"encoding/hex"
	"errors"
	"regexp"
	"strings"
	"time"
)

var serviceRE = regexp.MustCompile(`^[[:print:]]{1,128}$`)
var traceRE = regexp.MustCompile(`^[0-9a-f]{32}$`)
var projectRE = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$`)
var allowedLookback = map[string]time.Duration{"5m": 5 * time.Minute, "15m": 15 * time.Minute, "1h": time.Hour, "6h": 6 * time.Hour, "24h": 24 * time.Hour}

func ValidateService(s string) error {
	if s == "" || !serviceRE.MatchString(s) || strings.ContainsAny(s, "{}[]()=~!|,;\r\n\t\"\\") {
		return errors.New("invalid service")
	}
	return nil
}
func ValidateTraceID(s string) error {
	if !traceRE.MatchString(s) {
		return errors.New("invalid trace_id")
	}
	_, e := hex.DecodeString(s)
	return e
}
func ValidateProject(s string) error {
	if s != "" && !projectRE.MatchString(s) {
		return errors.New("invalid project")
	}
	return nil
}
func Lookback(s string) (time.Duration, error) {
	d, ok := allowedLookback[s]
	if !ok {
		return 0, errors.New("invalid lookback")
	}
	return d, nil
}
func Limit(n int) error {
	if n < 1 || n > 500 {
		return errors.New("invalid limit")
	}
	return nil
}

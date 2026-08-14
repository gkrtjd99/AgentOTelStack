// Command tempo-import-rewrite changes only Go import declarations.
//
// Tempo 2.10.3 predates the /v2 module-path convention.  The Grafana build
// adapts that source to github.com/grafana/tempo/v2, but must not rewrite
// runtime strings (for example the stable usage-statistics prefix).  Parsing
// the source and replacing only ast.ImportSpec.Path literals keeps that
// boundary explicit and leaves all other bytes untouched.
package main

import (
	"flag"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

type stringList []string

func (s *stringList) String() string { return strings.Join(*s, ",") }

func (s *stringList) Set(value string) error {
	*s = append(*s, value)
	return nil
}

type edit struct {
	start int
	end   int
	value []byte
}

type result struct {
	files   int
	imports int
}

func main() {
	var inputs stringList
	var fileLists stringList
	oldPrefix := flag.String("old-prefix", "", "old import path prefix")
	newPrefix := flag.String("new-prefix", "", "new import path prefix")
	expectedFiles := flag.Int("expected-files", -1, "expected number of files changed")
	expectedImports := flag.Int("expected-imports", -1, "expected number of imports changed")
	flag.Var(&inputs, "input", "Go file or directory to process; may be repeated")
	flag.Var(&fileLists, "file-list", "newline-delimited list of Go files to process; may be repeated")
	flag.Parse()

	if *oldPrefix == "" || *newPrefix == "" || len(inputs) == 0 && len(fileLists) == 0 {
		flag.Usage()
		os.Exit(2)
	}

	files, err := collectFiles(inputs, fileLists)
	if err != nil {
		fatal(err)
	}
	if len(files) == 0 {
		fatal(fmt.Errorf("no Go files found"))
	}

	got := result{}
	for _, filename := range files {
		changed, imports, err := rewriteFile(filename, *oldPrefix, *newPrefix)
		if err != nil {
			fatal(err)
		}
		if changed {
			got.files++
		}
		got.imports += imports
	}

	if *expectedFiles >= 0 && got.files != *expectedFiles {
		fatal(fmt.Errorf("changed file count: got %d, want %d", got.files, *expectedFiles))
	}
	if *expectedImports >= 0 && got.imports != *expectedImports {
		fatal(fmt.Errorf("changed import count: got %d, want %d", got.imports, *expectedImports))
	}
	fmt.Printf("tempo import rewrite: files=%d imports=%d\n", got.files, got.imports)
}

func collectFiles(inputs, fileLists []string) ([]string, error) {
	seen := make(map[string]struct{})
	var files []string
	add := func(filename string) error {
		if filepath.Ext(filename) != ".go" {
			return fmt.Errorf("input is not a Go file: %s", filename)
		}
		absolute, err := filepath.Abs(filename)
		if err != nil {
			return err
		}
		if _, ok := seen[absolute]; ok {
			return nil
		}
		info, err := os.Stat(absolute)
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("input is not a regular file: %s", filename)
		}
		seen[absolute] = struct{}{}
		files = append(files, absolute)
		return nil
	}

	for _, input := range inputs {
		info, err := os.Stat(input)
		if err != nil {
			return nil, err
		}
		if !info.IsDir() {
			if err := add(input); err != nil {
				return nil, err
			}
			continue
		}
		if err := filepath.WalkDir(input, func(path string, entry os.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if entry.IsDir() {
				return nil
			}
			if filepath.Ext(path) == ".go" {
				return add(path)
			}
			return nil
		}); err != nil {
			return nil, err
		}
	}

	for _, listName := range fileLists {
		contents, err := os.ReadFile(listName)
		if err != nil {
			return nil, err
		}
		for _, line := range strings.Split(string(contents), "\n") {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			if err := add(line); err != nil {
				return nil, err
			}
		}
	}

	sort.Strings(files)
	return files, nil
}

func rewriteFile(filename, oldPrefix, newPrefix string) (bool, int, error) {
	source, err := os.ReadFile(filename)
	if err != nil {
		return false, 0, err
	}
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filename, source, parser.ParseComments)
	if err != nil {
		return false, 0, fmt.Errorf("parse %s: %w", filename, err)
	}

	edits, err := importEdits(fset, file.Imports, oldPrefix, newPrefix)
	if err != nil {
		return false, 0, fmt.Errorf("inspect imports in %s: %w", filename, err)
	}

	if len(edits) == 0 {
		return false, 0, nil
	}

	updated := append([]byte(nil), source...)
	for index := len(edits) - 1; index >= 0; index-- {
		change := edits[index]
		updated = append(updated[:change.start], append(change.value, updated[change.end:]...)...)
	}
	if err := os.WriteFile(filename, updated, 0o644); err != nil {
		return false, 0, err
	}
	return true, len(edits), nil
}

func importEdits(fset *token.FileSet, imports []*ast.ImportSpec, oldPrefix, newPrefix string) ([]edit, error) {
	var edits []edit
	for _, spec := range imports {
		path, err := strconv.Unquote(spec.Path.Value)
		if err != nil {
			return nil, fmt.Errorf("unquote %s: %w", spec.Path.Value, err)
		}
		if path == newPrefix || strings.HasPrefix(path, newPrefix+"/") {
			continue
		}
		if path != oldPrefix && !strings.HasPrefix(path, oldPrefix+"/") {
			continue
		}

		position := fset.PositionFor(spec.Path.Pos(), false)
		end := fset.PositionFor(spec.Path.End(), false)
		edits = append(edits, edit{
			start: position.Offset,
			end:   end.Offset,
			value: []byte(strconv.Quote(newPrefix + strings.TrimPrefix(path, oldPrefix))),
		})
	}
	return edits, nil
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "tempo import rewrite:", err)
	os.Exit(1)
}

// docs — CLI for querying parsed documentation databases.
//
// Commands:
//
//	search   <query>          Hybrid FTS5 + semantic search
//	chunk    <id>             Fetch a chunk by integer ID
//	outline  <source_file>    Heading tree for a source file
//	corpuses                  List all corpora
//	files                     List all parsed files
//	related  <id>             Semantically similar chunks (requires embeddings)
//
// Output is compact JSON by default. Pass --pretty for human-readable output.
package main

import (
	"database/sql"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"sort"
	"strings"

	_ "modernc.org/sqlite"
)

// ── helpers ───────────────────────────────────────────────────────────────────

func die(msg string) {
	b, _ := json.Marshal(map[string]string{"error": msg})
	fmt.Fprintln(os.Stderr, string(b))
	os.Exit(1)
}

func out(v any, pretty bool) {
	var b []byte
	var err error
	if pretty {
		b, err = json.MarshalIndent(v, "", "  ")
	} else {
		b, err = json.Marshal(v)
	}
	if err != nil {
		die(err.Error())
	}
	fmt.Println(string(b))
}

func openDB(path string) *sql.DB {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		die(fmt.Sprintf("Database not found: %s\nParse some documentation first:\n  uv run scripts/parse_docs.py --input /path/to/docs --db ./docs.db --corpus-name mylib --corpus-version 1.0", path))
	}
	uri := fmt.Sprintf("file:%s?mode=ro&immutable=1", path)
	db, err := sql.Open("sqlite", uri)
	if err != nil {
		die(err.Error())
	}
	if _, err := db.Exec("PRAGMA foreign_keys=ON"); err != nil {
		die(err.Error())
	}
	return db
}

// corpusIDs returns corpus IDs matching the given name/version filters.
func corpusIDs(db *sql.DB, name, version string) []int64 {
	var rows *sql.Rows
	var err error
	if name == "" {
		rows, err = db.Query("SELECT id FROM corpuses")
	} else if version != "" {
		rows, err = db.Query("SELECT id FROM corpuses WHERE name = ? AND version = ?", name, version)
	} else {
		rows, err = db.Query("SELECT id FROM corpuses WHERE name = ?", name)
	}
	if err != nil {
		die(err.Error())
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			die(err.Error())
		}
		ids = append(ids, id)
	}
	return ids
}

func placeholders(n int) string {
	p := make([]string, n)
	for i := range p {
		p[i] = "?"
	}
	return strings.Join(p, ",")
}

func int64sToAny(ids []int64) []any {
	a := make([]any, len(ids))
	for i, id := range ids {
		a[i] = id
	}
	return a
}

// ── embedding math ────────────────────────────────────────────────────────────

func decodeEmbedding(blob []byte) []float32 {
	n := len(blob) / 4
	v := make([]float32, n)
	for i := range v {
		bits := binary.LittleEndian.Uint32(blob[i*4 : i*4+4])
		v[i] = math.Float32frombits(bits)
	}
	return v
}

func cosine(a, b []float32) float64 {
	var dot, na, nb float64
	for i := range a {
		dot += float64(a[i]) * float64(b[i])
		na += float64(a[i]) * float64(a[i])
		nb += float64(b[i]) * float64(b[i])
	}
	if na == 0 || nb == 0 {
		return 0
	}
	return dot / (math.Sqrt(na) * math.Sqrt(nb))
}

// ── search ────────────────────────────────────────────────────────────────────

type searchResult struct {
	ID             int64   `json:"id"`
	CorpusName     string  `json:"corpus_name"`
	CorpusVersion  string  `json:"corpus_version"`
	HeadingPath    string  `json:"heading_path"`
	Content        string  `json:"content"`
	TokenCount     int     `json:"token_count"`
	SourceFile     string  `json:"source_file"`
	Score          float64 `json:"score"`
}

func cmdSearch(db *sql.DB, query, corpus, version string, limit int) []searchResult {
	ids := corpusIDs(db, corpus, version)
	if len(ids) == 0 {
		return []searchResult{}
	}

	// Build FTS query: add wildcard suffix to each non-operator token
	ftsOps := map[string]bool{"AND": true, "OR": true, "NOT": true}
	parts := strings.Fields(query)
	tokens := make([]string, len(parts))
	for i, t := range parts {
		if strings.HasSuffix(t, "*") || ftsOps[t] {
			tokens[i] = t
		} else {
			tokens[i] = t + "*"
		}
	}
	ftsQuery := strings.Join(tokens, " OR ")

	ph := placeholders(len(ids))
	args := append([]any{ftsQuery}, int64sToAny(ids)...)
	args = append(args, limit*2)

	ftsSQL := fmt.Sprintf(`
		SELECT c.id, c.corpus_id, c.heading_path, c.content, c.content_plain,
		       c.token_count, c.embedding,
		       f.rel_path AS source_file,
		       cp.name AS corpus_name, cp.version AS corpus_version,
		       bm25(chunks_fts, 1, 10) AS fts_rank
		FROM chunks_fts
		JOIN chunks c ON c.id = chunks_fts.rowid
		JOIN files f ON f.id = c.file_id
		JOIN corpuses cp ON cp.id = c.corpus_id
		WHERE chunks_fts MATCH ?
		  AND c.corpus_id IN (%s)
		ORDER BY bm25(chunks_fts, 1, 10)
		LIMIT ?`, ph)

	rows, err := db.Query(ftsSQL, args...)
	if err != nil {
		// FTS syntax error — return empty rather than crashing
		return []searchResult{}
	}
	defer rows.Close()

	type ftsRow struct {
		id            int64
		headingPath   string
		content       string
		tokenCount    int
		embedding     []byte
		sourceFile    string
		corpusName    string
		corpusVersion string
		ftsRank       float64
	}

	var ftsRows []ftsRow
	for rows.Next() {
		var r ftsRow
		var corpusID int64
		var emb []byte
		if err := rows.Scan(&r.id, &corpusID, &r.headingPath, &r.content, new(string),
			&r.tokenCount, &emb, &r.sourceFile, &r.corpusName, &r.corpusVersion, &r.ftsRank); err != nil {
			die(err.Error())
		}
		r.embedding = emb
		ftsRows = append(ftsRows, r)
	}

	// Normalise BM25 scores (BM25 is negative; lower = better)
	ftsScores := map[int64]float64{}
	if len(ftsRows) > 0 {
		lo, hi := ftsRows[0].ftsRank, ftsRows[0].ftsRank
		for _, r := range ftsRows {
			if r.ftsRank < lo {
				lo = r.ftsRank
			}
			if r.ftsRank > hi {
				hi = r.ftsRank
			}
		}
		span := hi - lo
		if span == 0 {
			span = 1
		}
		for _, r := range ftsRows {
			ftsScores[r.id] = 1.0 - (r.ftsRank-lo)/span
		}
	}

	// Build result map
	type entry struct {
		searchResult
		embedding []byte
	}
	results := map[int64]*entry{}
	for _, r := range ftsRows {
		results[r.id] = &entry{
			searchResult: searchResult{
				ID:            r.id,
				CorpusName:    r.corpusName,
				CorpusVersion: r.corpusVersion,
				HeadingPath:   r.headingPath,
				Content:       r.content,
				TokenCount:    r.tokenCount,
				SourceFile:    r.sourceFile,
				Score:         ftsScores[r.id],
			},
			embedding: r.embedding,
		}
	}

	// Semantic re-ranking: load all embeddings for the corpus set
	embSQL := fmt.Sprintf(
		"SELECT id, embedding FROM chunks WHERE corpus_id IN (%s) AND embedding IS NOT NULL", ph)
	embRows, err := db.Query(embSQL, int64sToAny(ids)...)
	if err == nil {
		defer embRows.Close()

		type embEntry struct {
			id  int64
			vec []float32
		}
		var allEmbs []embEntry
		for embRows.Next() {
			var eid int64
			var blob []byte
			if err := embRows.Scan(&eid, &blob); err != nil {
				continue
			}
			allEmbs = append(allEmbs, embEntry{id: eid, vec: decodeEmbedding(blob)})
		}

		// We don't have an embedder at query time in the Go binary, so semantic
		// re-ranking only applies when an FTS result already has an embedding —
		// we use those stored embeddings to compute mutual similarity against
		// a centroid of the top FTS hits (a proxy for query intent).
		if len(allEmbs) > 0 && len(ftsRows) > 0 {
			// Build centroid from top-3 FTS hits that have embeddings
			var centroid []float32
			used := 0
			for _, r := range ftsRows {
				if len(r.embedding) == 0 || used >= 3 {
					break
				}
				vec := decodeEmbedding(r.embedding)
				if centroid == nil {
					centroid = make([]float32, len(vec))
				}
				for i, v := range vec {
					centroid[i] += v
				}
				used++
			}
			if used > 0 {
				for i := range centroid {
					centroid[i] /= float32(used)
				}

				// Score all embeddings against centroid
				type simEntry struct {
					id  int64
					sim float64
				}
				sims := make([]simEntry, len(allEmbs))
				for i, e := range allEmbs {
					sims[i] = simEntry{id: e.id, sim: cosine(centroid, e.vec)}
				}
				sort.Slice(sims, func(i, j int) bool { return sims[i].sim > sims[j].sim })

				// Merge top semantic hits into results
				for _, s := range sims[:min(limit*2, len(sims))] {
					if s.sim <= 0 {
						break
					}
					if r, ok := results[s.id]; ok {
						r.Score = 0.6*ftsScores[s.id] + 0.4*s.sim
					} else {
						// Fetch chunk from DB
						row := db.QueryRow(`
							SELECT c.id, c.heading_path, c.content, c.token_count,
							       f.rel_path AS source_file,
							       cp.name AS corpus_name, cp.version AS corpus_version
							FROM chunks c
							JOIN files f ON f.id = c.file_id
							JOIN corpuses cp ON cp.id = c.corpus_id
							WHERE c.id = ?`, s.id)
						var e entry
						if err := row.Scan(&e.ID, &e.HeadingPath, &e.Content, &e.TokenCount,
							&e.SourceFile, &e.CorpusName, &e.CorpusVersion); err == nil {
							e.Score = 0.4 * s.sim
							results[s.id] = &e
						}
					}
				}
			}
		}
	}

	// Sort and trim
	ranked := make([]searchResult, 0, len(results))
	for _, e := range results {
		ranked = append(ranked, e.searchResult)
	}
	sort.Slice(ranked, func(i, j int) bool { return ranked[i].Score > ranked[j].Score })
	if len(ranked) > limit {
		ranked = ranked[:limit]
	}
	return ranked
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// ── chunk ─────────────────────────────────────────────────────────────────────

type chunkResult struct {
	ID            int64  `json:"id"`
	CorpusName    string `json:"corpus_name"`
	CorpusVersion string `json:"corpus_version"`
	SourceFile    string `json:"source_file"`
	HeadingPath   string `json:"heading_path"`
	HeadingLevel  int    `json:"heading_level"`
	SectionAnchor string `json:"section_anchor"`
	Content       string `json:"content"`
	ContentPlain  string `json:"content_plain"`
	TokenCount    int    `json:"token_count"`
}

func cmdChunk(db *sql.DB, id int64) any {
	row := db.QueryRow(`
		SELECT c.id, c.heading_path, c.heading_level, c.section_anchor,
		       c.content, c.content_plain, c.token_count,
		       f.rel_path AS source_file,
		       cp.name AS corpus_name, cp.version AS corpus_version
		FROM chunks c
		JOIN files f ON f.id = c.file_id
		JOIN corpuses cp ON cp.id = c.corpus_id
		WHERE c.id = ?`, id)
	var r chunkResult
	if err := row.Scan(&r.ID, &r.HeadingPath, &r.HeadingLevel, &r.SectionAnchor,
		&r.Content, &r.ContentPlain, &r.TokenCount,
		&r.SourceFile, &r.CorpusName, &r.CorpusVersion); err != nil {
		if err == sql.ErrNoRows {
			return map[string]any{}
		}
		die(err.Error())
	}
	return r
}

// ── outline ───────────────────────────────────────────────────────────────────

type outlineEntry struct {
	ID            int64  `json:"id"`
	HeadingPath   string `json:"heading_path"`
	HeadingLevel  int    `json:"heading_level"`
	SectionAnchor string `json:"section_anchor"`
	TokenCount    int    `json:"token_count"`
}

func cmdOutline(db *sql.DB, sourceFile, corpus, version string) []outlineEntry {
	ids := corpusIDs(db, corpus, version)
	if len(ids) == 0 {
		return []outlineEntry{}
	}
	ph := placeholders(len(ids))
	args := append([]any{sourceFile}, int64sToAny(ids)...)
	q := fmt.Sprintf(`
		SELECT c.id, c.heading_path, c.heading_level, c.section_anchor, c.token_count
		FROM chunks c
		JOIN files f ON f.id = c.file_id
		WHERE f.rel_path = ?
		  AND c.corpus_id IN (%s)
		ORDER BY c.id`, ph)
	rows, err := db.Query(q, args...)
	if err != nil {
		die(err.Error())
	}
	defer rows.Close()
	var result []outlineEntry
	for rows.Next() {
		var e outlineEntry
		if err := rows.Scan(&e.ID, &e.HeadingPath, &e.HeadingLevel, &e.SectionAnchor, &e.TokenCount); err != nil {
			die(err.Error())
		}
		result = append(result, e)
	}
	if result == nil {
		return []outlineEntry{}
	}
	return result
}

// ── corpuses ──────────────────────────────────────────────────────────────────

type corpusEntry struct {
	Name       string `json:"name"`
	Version    string `json:"version"`
	FileCount  int    `json:"file_count"`
	ChunkCount int    `json:"chunk_count"`
	CreatedAt  string `json:"created_at"`
}

func cmdCorpuses(db *sql.DB) []corpusEntry {
	rows, err := db.Query(`
		SELECT cp.name, cp.version, cp.created_at,
		       (SELECT COUNT(*) FROM files f WHERE f.corpus_id = cp.id) AS file_count,
		       (SELECT COUNT(*) FROM chunks c WHERE c.corpus_id = cp.id) AS chunk_count
		FROM corpuses cp
		ORDER BY cp.name, cp.version`)
	if err != nil {
		die(err.Error())
	}
	defer rows.Close()
	var result []corpusEntry
	for rows.Next() {
		var e corpusEntry
		if err := rows.Scan(&e.Name, &e.Version, &e.CreatedAt, &e.FileCount, &e.ChunkCount); err != nil {
			die(err.Error())
		}
		result = append(result, e)
	}
	if result == nil {
		return []corpusEntry{}
	}
	return result
}

// ── files ─────────────────────────────────────────────────────────────────────

type fileEntry struct {
	CorpusName    string `json:"corpus_name"`
	CorpusVersion string `json:"corpus_version"`
	RelPath       string `json:"rel_path"`
	ChunkCount    int    `json:"chunk_count"`
	ParsedAt      string `json:"parsed_at"`
}

func cmdFiles(db *sql.DB, corpus, version string) []fileEntry {
	ids := corpusIDs(db, corpus, version)
	if len(ids) == 0 {
		return []fileEntry{}
	}
	ph := placeholders(len(ids))
	q := fmt.Sprintf(`
		SELECT f.rel_path, f.chunk_count, f.parsed_at,
		       cp.name AS corpus_name, cp.version AS corpus_version
		FROM files f
		JOIN corpuses cp ON cp.id = f.corpus_id
		WHERE f.corpus_id IN (%s)
		ORDER BY cp.name, cp.version, f.rel_path`, ph)
	rows, err := db.Query(q, int64sToAny(ids)...)
	if err != nil {
		die(err.Error())
	}
	defer rows.Close()
	var result []fileEntry
	for rows.Next() {
		var e fileEntry
		if err := rows.Scan(&e.RelPath, &e.ChunkCount, &e.ParsedAt, &e.CorpusName, &e.CorpusVersion); err != nil {
			die(err.Error())
		}
		result = append(result, e)
	}
	if result == nil {
		return []fileEntry{}
	}
	return result
}

// ── related ───────────────────────────────────────────────────────────────────

func cmdRelated(db *sql.DB, id int64, limit int) []searchResult {
	var blob []byte
	var corpusID int64
	row := db.QueryRow("SELECT embedding, corpus_id FROM chunks WHERE id = ?", id)
	if err := row.Scan(&blob, &corpusID); err != nil || len(blob) == 0 {
		return []searchResult{}
	}
	refVec := decodeEmbedding(blob)

	rows, err := db.Query(
		"SELECT id, embedding FROM chunks WHERE corpus_id = ? AND embedding IS NOT NULL", corpusID)
	if err != nil {
		die(err.Error())
	}
	defer rows.Close()

	type sim struct {
		id  int64
		val float64
	}
	var sims []sim
	for rows.Next() {
		var eid int64
		var eblob []byte
		if err := rows.Scan(&eid, &eblob); err != nil {
			continue
		}
		if eid == id {
			continue
		}
		sims = append(sims, sim{id: eid, val: cosine(refVec, decodeEmbedding(eblob))})
	}
	sort.Slice(sims, func(i, j int) bool { return sims[i].val > sims[j].val })

	var result []searchResult
	for _, s := range sims {
		if s.val <= 0 || len(result) >= limit {
			break
		}
		r := db.QueryRow(`
			SELECT c.id, c.heading_path, c.content, c.token_count,
			       f.rel_path AS source_file,
			       cp.name AS corpus_name, cp.version AS corpus_version
			FROM chunks c
			JOIN files f ON f.id = c.file_id
			JOIN corpuses cp ON cp.id = c.corpus_id
			WHERE c.id = ?`, s.id)
		var e searchResult
		if err := r.Scan(&e.ID, &e.HeadingPath, &e.Content, &e.TokenCount,
			&e.SourceFile, &e.CorpusName, &e.CorpusVersion); err == nil {
			e.Score = s.val
			result = append(result, e)
		}
	}
	if result == nil {
		return []searchResult{}
	}
	return result
}

// reorderArgs moves all --flag and --flag=val tokens to the front so Go's flag
// package (which stops parsing at first non-flag arg) picks them up even when
// the user puts flags after the positional argument.
// e.g. ["myquery", "--limit", "3"] → ["--limit", "3", "myquery"]
func reorderArgs(args []string) []string {
	var flags, positionals []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if strings.HasPrefix(a, "-") {
			flags = append(flags, a)
			// If this flag takes a value (doesn't contain = and next arg doesn't start with -)
			if !strings.Contains(a, "=") && i+1 < len(args) && !strings.HasPrefix(args[i+1], "-") {
				i++
				flags = append(flags, args[i])
			}
		} else {
			positionals = append(positionals, a)
		}
	}
	return append(flags, positionals...)
}

// ── main ──────────────────────────────────────────────────────────────────────

func usage() {
	fmt.Fprintln(os.Stderr, `docs — query parsed documentation databases

Usage:
  docs --db <path> [--pretty] <command> [args]

Commands:
  search   <query> [--corpus <name>] [--version <ver>] [--limit <n>]
  chunk    <id>
  outline  <source_file> [--corpus <name>] [--version <ver>]
  corpuses
  files    [--corpus <name>] [--version <ver>]
  related  <id> [--limit <n>]`)
	os.Exit(1)
}

func main() {
	// Global flags
	globalFlags := flag.NewFlagSet("docs", flag.ContinueOnError)
	dbPath := globalFlags.String("db", "", "Path to SQLite database (required)")
	pretty := globalFlags.Bool("pretty", false, "Pretty-print JSON output")
	if err := globalFlags.Parse(os.Args[1:]); err != nil || globalFlags.NArg() == 0 {
		usage()
	}
	if *dbPath == "" {
		die("--db is required. Pass the path to your SQLite database.")
	}

	remaining := globalFlags.Args()
	cmd := remaining[0]
	cmdArgs := remaining[1:]

	db := openDB(*dbPath)
	defer db.Close()

	switch cmd {
	case "search":
		fs := flag.NewFlagSet("search", flag.ExitOnError)
		corpus := fs.String("corpus", "", "Filter to corpus name")
		version := fs.String("version", "", "Filter to corpus version")
		limit := fs.Int("limit", 10, "Max results")
		fs.Parse(reorderArgs(cmdArgs))
		if fs.NArg() < 1 {
			die("search requires a query argument")
		}
		out(cmdSearch(db, fs.Arg(0), *corpus, *version, *limit), *pretty)

	case "chunk":
		fs := flag.NewFlagSet("chunk", flag.ExitOnError)
		fs.Parse(cmdArgs)
		if fs.NArg() < 1 {
			die("chunk requires an id argument")
		}
		var id int64
		fmt.Sscan(fs.Arg(0), &id)
		out(cmdChunk(db, id), *pretty)

	case "outline":
		fs := flag.NewFlagSet("outline", flag.ExitOnError)
		corpus := fs.String("corpus", "", "Filter to corpus name")
		version := fs.String("version", "", "Filter to corpus version")
		fs.Parse(reorderArgs(cmdArgs))
		if fs.NArg() < 1 {
			die("outline requires a source_file argument")
		}
		out(cmdOutline(db, fs.Arg(0), *corpus, *version), *pretty)

	case "corpuses":
		out(cmdCorpuses(db), *pretty)

	case "files":
		fs := flag.NewFlagSet("files", flag.ExitOnError)
		corpus := fs.String("corpus", "", "Filter to corpus name")
		version := fs.String("version", "", "Filter to corpus version")
		fs.Parse(cmdArgs)
		out(cmdFiles(db, *corpus, *version), *pretty)

	case "related":
		fs := flag.NewFlagSet("related", flag.ExitOnError)
		limit := fs.Int("limit", 5, "Max results")
		fs.Parse(reorderArgs(cmdArgs))
		if fs.NArg() < 1 {
			die("related requires an id argument")
		}
		var id int64
		fmt.Sscan(fs.Arg(0), &id)
		out(cmdRelated(db, id, *limit), *pretty)

	default:
		die(fmt.Sprintf("unknown command: %s", cmd))
	}
}

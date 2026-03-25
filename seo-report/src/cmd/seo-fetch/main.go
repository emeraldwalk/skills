package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"gopkg.in/yaml.v3"

	"github.com/seo-fetch/seo-fetch/internal/ga4"
	"github.com/seo-fetch/seo-fetch/internal/gsc"
	"github.com/seo-fetch/seo-fetch/internal/report"
	"github.com/seo-fetch/seo-fetch/internal/store"
)

type Config struct {
	Site            string `yaml:"site"`             // Human-readable site name, e.g. "example.com"
	GA4PropertyID   string `yaml:"ga4_property_id"`  // Numeric GA4 property ID
	GSCSiteURL      string `yaml:"gsc_site_url"`     // Exact GSC property URL
	CredentialsFile string `yaml:"credentials_file"` // Path to service account JSON
	DBFile          string `yaml:"db_file"`          // SQLite file path
	ReportsDir      string `yaml:"reports_dir"`      // Directory for HTML reports
	LookbackDays    int    `yaml:"lookback_days"`    // Days of data to fetch (default 28)
}

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config %s: %w", path, err)
	}
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	// Defaults
	if cfg.CredentialsFile == "" {
		cfg.CredentialsFile = "credentials/service-account.json"
	}
	if cfg.DBFile == "" {
		cfg.DBFile = "data/seo.db"
	}
	if cfg.ReportsDir == "" {
		cfg.ReportsDir = "reports"
	}
	if cfg.LookbackDays == 0 {
		cfg.LookbackDays = 28
	}
	return &cfg, nil
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	configFile := "seo.yaml"
	// Allow --config flag before subcommand
	args := os.Args[1:]
	for i, a := range args {
		if (a == "--config" || a == "-c") && i+1 < len(args) {
			configFile = args[i+1]
			args = append(args[:i], args[i+2:]...)
			break
		}
	}

	if len(args) == 0 {
		usage()
		os.Exit(1)
	}

	cmd := args[0]

	switch cmd {
	case "pull":
		cfg := mustLoadConfig(configFile)
		mustPull(cfg)
	case "report":
		cfg := mustLoadConfig(configFile)
		mustReport(cfg)
	case "run":
		cfg := mustLoadConfig(configFile)
		mustPull(cfg)
		mustReport(cfg)
	case "status":
		cfg := mustLoadConfig(configFile)
		mustStatus(cfg)
	case "init":
		writeExampleConfig()
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", cmd)
		usage()
		os.Exit(1)
	}
}

func mustLoadConfig(path string) *Config {
	cfg, err := loadConfig(path)
	if err != nil {
		fatalf("config error: %v", err)
	}
	if cfg.GA4PropertyID == "" {
		fatalf("ga4_property_id is required in %s", path)
	}
	if cfg.GSCSiteURL == "" {
		fatalf("gsc_site_url is required in %s", path)
	}
	return cfg
}

func mustPull(cfg *Config) {
	ctx := context.Background()
	today := time.Now().UTC().Format("2006-01-02")

	fmt.Println("→ Opening database:", cfg.DBFile)
	if err := os.MkdirAll(dirOf(cfg.DBFile), 0755); err != nil {
		fatalf("create db dir: %v", err)
	}
	db, err := store.Open(cfg.DBFile)
	if err != nil {
		fatalf("open db: %v", err)
	}
	defer db.Close()

	// GA4
	fmt.Println("→ Fetching GA4 data...")
	ga4Start, ga4End := ga4.DateRange(cfg.LookbackDays)
	ga4Client, err := ga4.New(ctx, cfg.CredentialsFile, cfg.GA4PropertyID)
	if err != nil {
		fatalf("GA4 client: %v", err)
	}
	pages, err := ga4Client.FetchPages(ctx, ga4Start, ga4End, 200)
	if err != nil {
		fatalf("GA4 fetch: %v", err)
	}
	fmt.Printf("   %d pages fetched (%s to %s)\n", len(pages), ga4Start, ga4End)

	var ga4Rows []store.GA4Page
	var totalSessions, totalNewUsers, totalConversions int64
	var totalRevenue float64
	for _, p := range pages {
		totalSessions += p.Sessions
		totalNewUsers += p.NewUsers
		totalConversions += p.Conversions
		totalRevenue += p.Revenue
		ga4Rows = append(ga4Rows, store.GA4Page{
			SnapshotDate:       today,
			DateRangeStart:     ga4Start,
			DateRangeEnd:       ga4End,
			PagePath:           p.PagePath,
			Sessions:           p.Sessions,
			NewUsers:           p.NewUsers,
			BounceRate:         p.BounceRate,
			AvgSessionDuration: p.AvgSessionDuration,
			Conversions:        p.Conversions,
			Revenue:            p.Revenue,
		})
	}
	if err := db.InsertGA4Pages(ga4Rows); err != nil {
		fatalf("insert GA4 pages: %v", err)
	}

	// GSC
	fmt.Println("→ Fetching GSC data...")
	gscStart, gscEnd := gsc.DateRange(cfg.LookbackDays)
	gscClient, err := gsc.New(ctx, cfg.CredentialsFile, cfg.GSCSiteURL)
	if err != nil {
		fatalf("GSC client: %v", err)
	}
	queries, err := gscClient.FetchQueries(ctx, gscStart, gscEnd, 500)
	if err != nil {
		fatalf("GSC fetch: %v", err)
	}
	fmt.Printf("   %d queries fetched (%s to %s)\n", len(queries), gscStart, gscEnd)

	var gscRows []store.GSCQuery
	var totalClicks, totalImpressions int64
	var totalPosition float64
	for _, q := range queries {
		totalClicks += q.Clicks
		totalImpressions += q.Impressions
		totalPosition += q.Position
		gscRows = append(gscRows, store.GSCQuery{
			SnapshotDate:   today,
			DateRangeStart: gscStart,
			DateRangeEnd:   gscEnd,
			Query:          q.Query,
			Page:           q.Page,
			Clicks:         q.Clicks,
			Impressions:    q.Impressions,
			CTR:            q.CTR,
			Position:       q.Position,
		})
	}
	if err := db.InsertGSCQueries(gscRows); err != nil {
		fatalf("insert GSC queries: %v", err)
	}

	avgPos := 0.0
	if len(queries) > 0 {
		avgPos = totalPosition / float64(len(queries))
	}

	snap := store.Snapshot{
		SnapshotDate:     today,
		TotalSessions:    totalSessions,
		TotalNewUsers:    totalNewUsers,
		TotalClicks:      totalClicks,
		TotalImpressions: totalImpressions,
		AvgPosition:      avgPos,
		TotalConversions: totalConversions,
		TotalRevenue:     totalRevenue,
	}
	if err := db.UpsertSnapshot(snap); err != nil {
		fatalf("upsert snapshot: %v", err)
	}

	fmt.Printf("✓ Snapshot saved for %s\n", today)
}

func mustReport(cfg *Config) {
	db, err := store.Open(cfg.DBFile)
	if err != nil {
		fatalf("open db: %v", err)
	}
	defer db.Close()

	today := time.Now().UTC().Format("2006-01-02")

	snaps, err := db.RecentSnapshots(12)
	if err != nil {
		fatalf("load snapshots: %v", err)
	}
	if len(snaps) == 0 {
		fatalf("no snapshots found — run `seo-fetch pull` first")
	}

	pages, err := db.LatestGA4Pages()
	if err != nil {
		fatalf("load pages: %v", err)
	}
	queries, err := db.LatestGSCQueries()
	if err != nil {
		fatalf("load queries: %v", err)
	}

	latest := snaps[0]
	dateStart := ""
	dateEnd := ""
	if len(pages) > 0 {
		dateStart = pages[0].DateRangeStart
		dateEnd = pages[0].DateRangeEnd
	}

	siteName := cfg.Site
	if siteName == "" {
		siteName = cfg.GSCSiteURL
	}

	data := report.ReportData{
		Site:           siteName,
		Date:           today,
		DateRangeStart: dateStart,
		DateRangeEnd:   dateEnd,
		Snap:           latest,
		History:        reverseSnapshots(snaps),
		Pages:          pages,
		Queries:        queries,
	}

	filename, err := report.Generate(data, cfg.ReportsDir)
	if err != nil {
		fatalf("generate report: %v", err)
	}
	fmt.Println("✓ Report written:", filename)
}

func mustStatus(cfg *Config) {
	db, err := store.Open(cfg.DBFile)
	if err != nil {
		fatalf("open db: %v", err)
	}
	defer db.Close()

	dates, err := db.SnapshotDates()
	if err != nil {
		fatalf("load snapshots: %v", err)
	}
	if len(dates) == 0 {
		fmt.Println("No snapshots yet. Run `seo-fetch pull` to collect data.")
		return
	}
	fmt.Printf("Snapshots (%d total):\n", len(dates))
	for _, d := range dates {
		fmt.Println(" ", d)
	}
}

func writeExampleConfig() {
	example := `# seo-fetch configuration
site: "example.com"
ga4_property_id: "123456789"
gsc_site_url: "https://www.example.com/"
credentials_file: "credentials/service-account.json"
db_file: "data/seo.db"
reports_dir: "reports"
lookback_days: 28
`
	if _, err := os.Stat("seo.yaml"); err == nil {
		fmt.Println("seo.yaml already exists, not overwriting.")
		return
	}
	if err := os.WriteFile("seo.yaml", []byte(example), 0644); err != nil {
		fatalf("write seo.yaml: %v", err)
	}
	fmt.Println("✓ Created seo.yaml — fill in your GA4 property ID and GSC site URL.")
}

func usage() {
	fmt.Println(`seo-fetch — GA4 + GSC data collection and reporting

Usage:
  seo-fetch [--config seo.yaml] <command>

Commands:
  init      Create an example seo.yaml config file
  pull      Fetch GA4 + GSC data and store in SQLite
  report    Generate HTML report from stored data
  run       Pull then report (most common)
  status    Show stored snapshot dates

Config file (seo.yaml):
  site              Human-readable site name
  ga4_property_id   Numeric GA4 property ID (required)
  gsc_site_url      Exact GSC property URL (required)
  credentials_file  Path to service account JSON (default: credentials/service-account.json)
  db_file           SQLite file path (default: data/seo.db)
  reports_dir       HTML output directory (default: reports)
  lookback_days     Days of data to fetch (default: 28)`)
}

func dirOf(path string) string {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' || path[i] == '\\' {
			return path[:i]
		}
	}
	return "."
}

func reverseSnapshots(s []store.Snapshot) []store.Snapshot {
	out := make([]store.Snapshot, len(s))
	for i, v := range s {
		out[len(s)-1-i] = v
	}
	return out
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "error: "+format+"\n", args...)
	os.Exit(1)
}

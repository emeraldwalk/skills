---
name: seo-report
description: Runs the seo-fetch Go CLI to pull GA4 and Google Search Console data, store snapshots in SQLite, generate an HTML report, and provide narrative SEO analysis. Works for any site — not hardcoded to a specific domain. Use when the user asks to run an SEO report, check search performance, analyze organic traffic, review top queries or pages, identify SEO opportunities, or invoke `/seo-report`.
---

# seo-report

## Structure

The skill ships with the full Go source and pre-built binaries for multiple platforms:

```
seo-report/
├── bin/
│   ├── seo-fetch.sh            # Wrapper script — auto-selects binary by OS/arch
│   ├── seo-fetch-darwin-amd64  # macOS Intel
│   ├── seo-fetch-darwin-arm64  # macOS Apple Silicon
│   └── seo-fetch-linux-amd64   # Linux x86_64
├── src/                        # Go source (rebuild for other platforms)
│   ├── cmd/seo-fetch/
│   └── internal/{ga4,gsc,store,report}/
├── references/queries.md       # Ready-to-run SQLite analysis queries
└── SKILL.md
```

Use `bin/seo-fetch.sh` as the entry point — it detects `uname -s` / `uname -m` and delegates to the correct binary.

## First-time setup

1. **Create a config file** in the project directory:
   ```bash
   /path/to/seo-report/bin/seo-fetch.sh init   # creates seo.yaml with example values
   ```
   Edit `seo.yaml` — only `ga4_property_id` and `gsc_site_url` are required.

2. **Add credentials**: place the Google service account JSON at the path in `credentials_file` (default: `credentials/service-account.json`).

3. **Google Cloud prerequisites** (one-time, done in browser):
   - Enable **Google Analytics Data API** and **Google Search Console API**
   - Create a service account, download JSON key
   - Grant it **Viewer** access in GA4 and **Full** access in GSC

## Workflow

```bash
/path/to/seo-report/bin/seo-fetch.sh run       # Pull GA4 + GSC data, then generate HTML report (most common)
/path/to/seo-report/bin/seo-fetch.sh pull      # Fetch data only
/path/to/seo-report/bin/seo-fetch.sh report    # Regenerate HTML from stored data
/path/to/seo-report/bin/seo-fetch.sh status    # Show stored snapshot dates
```

Run from the directory containing `seo.yaml` (the user's project directory, not the skill directory). Output: `data/seo.db` (SQLite) + `reports/YYYY-MM-DD.html`.

The wrapper is at `bin/seo-fetch.sh` inside this skill directory. Use its absolute path, or copy the script + relevant platform binary into the user's project.

## Analysis

After pulling, query the database for deeper analysis — see [references/queries.md](references/queries.md).

Summarize findings across four lenses:
- **Top performers** — pages/queries driving the most sessions or clicks
- **Opportunity queries** — high impressions, low CTR (< 3%) → title/meta improvements
- **Low-hanging fruit** — position 4–10 queries → small content updates to reach top 3
- **Regressions** — week-over-week drops in sessions or clicks

## seo.yaml reference

| Key | Default | Notes |
|---|---|---|
| `site` | — | Human-readable name shown in report header |
| `ga4_property_id` | required | Numeric GA4 property ID |
| `gsc_site_url` | required | Exact GSC URL, e.g. `https://www.example.com/` |
| `credentials_file` | `credentials/service-account.json` | Service account JSON |
| `db_file` | `data/seo.db` | SQLite file |
| `reports_dir` | `reports` | HTML output directory |
| `lookback_days` | `28` | Days of data to fetch |

## Rebuilding the binary

```bash
cd seo-report/src

# macOS Intel
go build -o ../bin/seo-fetch-darwin-amd64 ./cmd/seo-fetch

# macOS Apple Silicon
GOOS=darwin GOARCH=arm64 go build -o ../bin/seo-fetch-darwin-arm64 ./cmd/seo-fetch

# Linux x86_64
GOOS=linux GOARCH=amd64 go build -o ../bin/seo-fetch-linux-amd64 ./cmd/seo-fetch
```

Requires Go 1.21+. Uses `modernc.org/sqlite` (pure Go — no CGO, no system deps). Cross-compilation works out of the box.

## Notes

- GSC has ~3 day lag; dates are adjusted automatically
- `conversions`/`revenue` return 0 until GA4 conversion tracking is configured
- Trends become meaningful after 4–6 weekly snapshots

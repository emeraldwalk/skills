---
name: seo-report
description: Runs the seo-fetch Go CLI to pull GA4 and Google Search Console data, store snapshots in SQLite, generate an HTML report, and provide narrative SEO analysis. Works for any site — not hardcoded to a specific domain. Use when the user asks to run an SEO report, check search performance, analyze organic traffic, review top queries or pages, identify SEO opportunities, or invoke `/seo-report`.
---

# seo-report

## Structure

The skill ships with the full Go source and a pre-built binary:

```
seo-report/
├── bin/seo-fetch          # Pre-built binary (linux/amd64)
├── src/                   # Go source (rebuild for other platforms)
│   ├── cmd/seo-fetch/
│   └── internal/{ga4,gsc,store,report}/
├── references/queries.md  # Ready-to-run SQLite analysis queries
└── SKILL.md
```

## First-time setup

1. **Create a config file** in the project directory:
   ```bash
   /path/to/seo-report/bin/seo-fetch init   # creates seo.yaml with example values
   ```
   Edit `seo.yaml` — only `ga4_property_id` and `gsc_site_url` are required.

2. **Add credentials**: place the Google service account JSON at the path in `credentials_file` (default: `credentials/service-account.json`).

3. **Google Cloud prerequisites** (one-time, done in browser):
   - Enable **Google Analytics Data API** and **Google Search Console API**
   - Create a service account, download JSON key
   - Grant it **Viewer** access in GA4 and **Full** access in GSC

## Workflow

```bash
/path/to/seo-report/bin/seo-fetch run       # Pull GA4 + GSC data, then generate HTML report (most common)
/path/to/seo-report/bin/seo-fetch pull      # Fetch data only
/path/to/seo-report/bin/seo-fetch report    # Regenerate HTML from stored data
/path/to/seo-report/bin/seo-fetch status    # Show stored snapshot dates
```

Run from the directory containing `seo.yaml` (the user's project directory, not the skill directory). Output: `data/seo.db` (SQLite) + `reports/YYYY-MM-DD.html`.

The binary is at `bin/seo-fetch` inside this skill directory. Use its absolute path, or copy it into the user's project.

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
cd src && go build -o ../bin/seo-fetch ./cmd/seo-fetch
```

Requires Go 1.21+. Uses `modernc.org/sqlite` (pure Go — no CGO, no system deps).

## Notes

- GSC has ~3 day lag; dates are adjusted automatically
- `conversions`/`revenue` return 0 until GA4 conversion tracking is configured
- Trends become meaningful after 4–6 weekly snapshots

package report

import (
	"fmt"
	"html/template"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/seo-fetch/seo-fetch/internal/store"
)

const htmlTemplate = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SEO Report — {{.Site}} — {{.Date}}</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: system-ui, sans-serif; background: #f8f9fa; color: #212529; }
  header { background: #1a1a2e; color: white; padding: 1.5rem 2rem; }
  header h1 { font-size: 1.4rem; }
  header p { font-size: 0.85rem; opacity: 0.7; margin-top: 0.25rem; }
  main { max-width: 1200px; margin: 2rem auto; padding: 0 1rem; }
  .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 1rem; margin-bottom: 2rem; }
  .card { background: white; border-radius: 8px; padding: 1.25rem; box-shadow: 0 1px 3px rgba(0,0,0,.1); }
  .card .label { font-size: 0.75rem; text-transform: uppercase; letter-spacing: .05em; color: #6c757d; }
  .card .value { font-size: 1.8rem; font-weight: 700; margin-top: 0.25rem; }
  .card .delta { font-size: 0.8rem; margin-top: 0.25rem; }
  .delta.up { color: #198754; }
  .delta.down { color: #dc3545; }
  section { background: white; border-radius: 8px; padding: 1.5rem; box-shadow: 0 1px 3px rgba(0,0,0,.1); margin-bottom: 1.5rem; }
  section h2 { font-size: 1rem; margin-bottom: 1rem; color: #1a1a2e; }
  .chart-wrap { max-height: 260px; }
  table { width: 100%; border-collapse: collapse; font-size: 0.875rem; }
  th { text-align: left; padding: 0.5rem 0.75rem; border-bottom: 2px solid #dee2e6; color: #6c757d; font-weight: 600; }
  td { padding: 0.5rem 0.75rem; border-bottom: 1px solid #f1f3f5; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: #f8f9fa; }
  .num { text-align: right; font-variant-numeric: tabular-nums; }
  .page-path { max-width: 340px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .badge { display: inline-block; padding: 0.15rem 0.5rem; border-radius: 4px; font-size: 0.75rem; }
  .badge-warn { background: #fff3cd; color: #856404; }
  .badge-ok { background: #d1e7dd; color: #0a3622; }
</style>
</head>
<body>
<header>
  <h1>SEO Report — {{.Site}}</h1>
  <p>Generated {{.Date}} &nbsp;·&nbsp; Data window: {{.DateRangeStart}} to {{.DateRangeEnd}}</p>
</header>
<main>

<!-- Summary Cards -->
<div class="summary">
  <div class="card">
    <div class="label">Sessions</div>
    <div class="value">{{fmtInt .Snap.TotalSessions}}</div>
  </div>
  <div class="card">
    <div class="label">New Users</div>
    <div class="value">{{fmtInt .Snap.TotalNewUsers}}</div>
  </div>
  <div class="card">
    <div class="label">Clicks (GSC)</div>
    <div class="value">{{fmtInt .Snap.TotalClicks}}</div>
  </div>
  <div class="card">
    <div class="label">Impressions</div>
    <div class="value">{{fmtInt .Snap.TotalImpressions}}</div>
  </div>
  <div class="card">
    <div class="label">Avg Position</div>
    <div class="value">{{fmtFloat1 .Snap.AvgPosition}}</div>
  </div>
  {{if .Snap.TotalConversions}}
  <div class="card">
    <div class="label">Conversions</div>
    <div class="value">{{fmtInt .Snap.TotalConversions}}</div>
  </div>
  {{end}}
</div>

<!-- Sessions Trend -->
{{if gt (len .History) 1}}
<section>
  <h2>Sessions Over Time</h2>
  <div class="chart-wrap"><canvas id="sessionsChart"></canvas></div>
</section>
<script>
new Chart(document.getElementById('sessionsChart'), {
  type: 'line',
  data: {
    labels: [{{range .History}}'{{.SnapshotDate}}',{{end}}],
    datasets: [{
      label: 'Sessions',
      data: [{{range .History}}{{.TotalSessions}},{{end}}],
      borderColor: '#1a1a2e', backgroundColor: 'rgba(26,26,46,0.08)', tension: 0.3, fill: true
    }]
  },
  options: { plugins: { legend: { display: false } }, scales: { y: { beginAtZero: true } }, maintainAspectRatio: false }
});
</script>
{{end}}

<!-- Top Pages -->
<section>
  <h2>Top Pages by Sessions</h2>
  <table>
    <thead><tr>
      <th>Page</th>
      <th class="num">Sessions</th>
      <th class="num">New Users</th>
      <th class="num">Bounce Rate</th>
      <th class="num">Avg Duration</th>
    </tr></thead>
    <tbody>
    {{range .Pages}}
    <tr>
      <td class="page-path" title="{{.PagePath}}">{{.PagePath}}</td>
      <td class="num">{{fmtInt .Sessions}}</td>
      <td class="num">{{fmtInt .NewUsers}}</td>
      <td class="num">{{fmtPct .BounceRate}}</td>
      <td class="num">{{fmtDuration .AvgSessionDuration}}</td>
    </tr>
    {{end}}
    </tbody>
  </table>
</section>

<!-- Top Queries -->
<section>
  <h2>Top Queries (GSC)</h2>
  <table>
    <thead><tr>
      <th>Query</th>
      <th class="num">Clicks</th>
      <th class="num">Impressions</th>
      <th class="num">CTR</th>
      <th class="num">Position</th>
    </tr></thead>
    <tbody>
    {{range .Queries}}
    <tr>
      <td>{{.Query}}</td>
      <td class="num">{{fmtInt .Clicks}}</td>
      <td class="num">{{fmtInt .Impressions}}</td>
      <td class="num">{{fmtPct .CTR}}</td>
      <td class="num">{{fmtFloat1 .Position}}</td>
    </tr>
    {{end}}
    </tbody>
  </table>
</section>

<!-- Opportunities: high impressions, low CTR -->
{{if .Opportunities}}
<section>
  <h2>Opportunities — High Impressions, Low CTR</h2>
  <p style="font-size:.8rem;color:#6c757d;margin-bottom:.75rem">Queries with &gt;50 impressions and &lt;3% CTR. Consider improving title tags or meta descriptions.</p>
  <table>
    <thead><tr>
      <th>Query</th>
      <th class="num">Impressions</th>
      <th class="num">Clicks</th>
      <th class="num">CTR</th>
      <th class="num">Position</th>
    </tr></thead>
    <tbody>
    {{range .Opportunities}}
    <tr>
      <td>{{.Query}}</td>
      <td class="num">{{fmtInt .Impressions}}</td>
      <td class="num">{{fmtInt .Clicks}}</td>
      <td class="num"><span class="badge badge-warn">{{fmtPct .CTR}}</span></td>
      <td class="num">{{fmtFloat1 .Position}}</td>
    </tr>
    {{end}}
    </tbody>
  </table>
</section>
{{end}}

<!-- Low-hanging fruit: position 4-10 -->
{{if .LowHanging}}
<section>
  <h2>Low-Hanging Fruit — Position 4–10</h2>
  <p style="font-size:.8rem;color:#6c757d;margin-bottom:.75rem">Queries close to top 3. Small content improvements could push these into higher-CTR positions.</p>
  <table>
    <thead><tr>
      <th>Query</th>
      <th class="num">Position</th>
      <th class="num">Impressions</th>
      <th class="num">Clicks</th>
      <th class="num">CTR</th>
    </tr></thead>
    <tbody>
    {{range .LowHanging}}
    <tr>
      <td>{{.Query}}</td>
      <td class="num"><span class="badge badge-warn">{{fmtFloat1 .Position}}</span></td>
      <td class="num">{{fmtInt .Impressions}}</td>
      <td class="num">{{fmtInt .Clicks}}</td>
      <td class="num">{{fmtPct .CTR}}</td>
    </tr>
    {{end}}
    </tbody>
  </table>
</section>
{{end}}

</main>
</body>
</html>`

type ReportData struct {
	Site           string
	Date           string
	DateRangeStart string
	DateRangeEnd   string
	Snap           store.Snapshot
	History        []store.Snapshot
	Pages          []store.GA4Page
	Queries        []store.GSCQuery
	Opportunities  []store.GSCQuery
	LowHanging     []store.GSCQuery
}

func Generate(data ReportData, outputDir string) (string, error) {
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return "", fmt.Errorf("create output dir: %w", err)
	}

	funcMap := template.FuncMap{
		"fmtInt": func(v int64) string {
			if v >= 1_000_000 {
				return fmt.Sprintf("%.1fM", float64(v)/1_000_000)
			}
			if v >= 1_000 {
				return fmt.Sprintf("%.1fK", float64(v)/1_000)
			}
			return fmt.Sprintf("%d", v)
		},
		"fmtFloat1": func(v float64) string { return fmt.Sprintf("%.1f", v) },
		"fmtPct":    func(v float64) string { return fmt.Sprintf("%.1f%%", v*100) },
		"fmtDuration": func(secs float64) string {
			d := time.Duration(secs) * time.Second
			m := int(d.Minutes())
			s := int(d.Seconds()) % 60
			return fmt.Sprintf("%dm%ds", m, s)
		},
	}

	tmpl, err := template.New("report").Funcs(funcMap).Parse(htmlTemplate)
	if err != nil {
		return "", fmt.Errorf("parse template: %w", err)
	}

	// Filter derived slices
	for _, q := range data.Queries {
		if q.Impressions > 50 && q.CTR < 0.03 {
			data.Opportunities = append(data.Opportunities, q)
		}
		if q.Position >= 4 && q.Position <= 10 {
			data.LowHanging = append(data.LowHanging, q)
		}
	}
	// Sort opportunities by impressions desc (already sorted from DB by clicks, re-sort)
	sortByImpressions(data.Opportunities)
	if len(data.Opportunities) > 20 {
		data.Opportunities = data.Opportunities[:20]
	}
	sortByImpressions(data.LowHanging)
	if len(data.LowHanging) > 20 {
		data.LowHanging = data.LowHanging[:20]
	}

	filename := filepath.Join(outputDir, data.Date+".html")
	// Sanitize site name for filename
	safeSite := strings.NewReplacer("https://", "", "http://", "", "/", "_", ".", "_").Replace(data.Site)
	_ = safeSite // kept for potential future multi-site naming

	f, err := os.Create(filename)
	if err != nil {
		return "", fmt.Errorf("create report file: %w", err)
	}
	defer f.Close()

	if err := tmpl.Execute(f, data); err != nil {
		return "", fmt.Errorf("render template: %w", err)
	}
	return filename, nil
}

func sortByImpressions(rows []store.GSCQuery) {
	for i := 1; i < len(rows); i++ {
		for j := i; j > 0 && rows[j].Impressions > rows[j-1].Impressions; j-- {
			rows[j], rows[j-1] = rows[j-1], rows[j]
		}
	}
}

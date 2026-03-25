# SEO Analysis Queries

Run these with `sqlite3 data/seo.db` or via any SQLite client.

## Trend Overview

```sql
-- Week-over-week summary (last 8 snapshots)
SELECT snapshot_date, total_sessions, total_clicks, total_impressions, avg_position
FROM snapshots
ORDER BY snapshot_date DESC
LIMIT 8;
```

## Top Pages (latest snapshot)

```sql
-- Top pages by sessions
SELECT page_path, sessions, new_users, bounce_rate, avg_session_duration
FROM ga4_pages
WHERE snapshot_date = (SELECT MAX(snapshot_date) FROM ga4_pages)
ORDER BY sessions DESC
LIMIT 20;

-- Top store pages
SELECT page_path, sessions, new_users, bounce_rate
FROM ga4_pages
WHERE snapshot_date = (SELECT MAX(snapshot_date) FROM ga4_pages)
  AND page_path LIKE '/store/%'
ORDER BY sessions DESC
LIMIT 20;
```

## Opportunity Queries (high impressions, low CTR)

```sql
-- Queries with >50 impressions and <3% CTR — candidates for title/meta improvements
SELECT query, impressions, clicks, ctr, position
FROM gsc_queries
WHERE snapshot_date = (SELECT MAX(snapshot_date) FROM gsc_queries)
  AND impressions > 50
  AND ctr < 0.03
ORDER BY impressions DESC
LIMIT 20;
```

## Low-Hanging Fruit (position 4–10)

```sql
-- Queries ranking 4–10 — close to top 3, worth targeting with content updates
SELECT query, position, clicks, impressions, ctr
FROM gsc_queries
WHERE snapshot_date = (SELECT MAX(snapshot_date) FROM gsc_queries)
  AND position BETWEEN 4 AND 10
ORDER BY impressions DESC
LIMIT 20;
```

## Regressions (compare last two snapshots)

```sql
-- Sessions regression: pages that dropped most between last two snapshots
SELECT a.page_path,
       a.sessions AS current_sessions,
       b.sessions AS prior_sessions,
       (a.sessions - b.sessions) AS delta
FROM ga4_pages a
JOIN ga4_pages b ON a.page_path = b.page_path
WHERE a.snapshot_date = (SELECT MAX(snapshot_date) FROM ga4_pages)
  AND b.snapshot_date = (
    SELECT MAX(snapshot_date) FROM ga4_pages
    WHERE snapshot_date < (SELECT MAX(snapshot_date) FROM ga4_pages)
  )
ORDER BY delta ASC
LIMIT 20;
```

## Top Queries Overall

```sql
SELECT query, clicks, impressions, ctr, position
FROM gsc_queries
WHERE snapshot_date = (SELECT MAX(snapshot_date) FROM gsc_queries)
ORDER BY clicks DESC
LIMIT 25;
```

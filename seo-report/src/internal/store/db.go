package store

import (
	"database/sql"
	"fmt"

	_ "modernc.org/sqlite"
)

type DB struct {
	conn *sql.DB
}

func Open(path string) (*DB, error) {
	conn, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	db := &DB{conn: conn}
	if err := db.migrate(); err != nil {
		return nil, err
	}
	return db, nil
}

func (db *DB) Close() error {
	return db.conn.Close()
}

func (db *DB) migrate() error {
	_, err := db.conn.Exec(`
		CREATE TABLE IF NOT EXISTS ga4_pages (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			snapshot_date TEXT NOT NULL,
			date_range_start TEXT NOT NULL,
			date_range_end TEXT NOT NULL,
			page_path TEXT NOT NULL,
			sessions INTEGER,
			new_users INTEGER,
			bounce_rate REAL,
			avg_session_duration REAL,
			conversions INTEGER,
			revenue REAL
		);

		CREATE TABLE IF NOT EXISTS gsc_queries (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			snapshot_date TEXT NOT NULL,
			date_range_start TEXT NOT NULL,
			date_range_end TEXT NOT NULL,
			query TEXT NOT NULL,
			page TEXT,
			clicks INTEGER,
			impressions INTEGER,
			ctr REAL,
			position REAL
		);

		CREATE TABLE IF NOT EXISTS snapshots (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			snapshot_date TEXT NOT NULL UNIQUE,
			total_sessions INTEGER,
			total_new_users INTEGER,
			total_clicks INTEGER,
			total_impressions INTEGER,
			avg_position REAL,
			total_conversions INTEGER,
			total_revenue REAL
		);
	`)
	return err
}

type GA4Page struct {
	SnapshotDate       string
	DateRangeStart     string
	DateRangeEnd       string
	PagePath           string
	Sessions           int64
	NewUsers           int64
	BounceRate         float64
	AvgSessionDuration float64
	Conversions        int64
	Revenue            float64
}

type GSCQuery struct {
	SnapshotDate   string
	DateRangeStart string
	DateRangeEnd   string
	Query          string
	Page           string
	Clicks         int64
	Impressions    int64
	CTR            float64
	Position       float64
}

type Snapshot struct {
	SnapshotDate     string
	TotalSessions    int64
	TotalNewUsers    int64
	TotalClicks      int64
	TotalImpressions int64
	AvgPosition      float64
	TotalConversions int64
	TotalRevenue     float64
}

func (db *DB) DeleteSnapshotData(snapshotDate string) error {
	tx, err := db.conn.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM ga4_pages WHERE snapshot_date = ?`, snapshotDate); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM gsc_queries WHERE snapshot_date = ?`, snapshotDate); err != nil {
		return err
	}
	return tx.Commit()
}

func (db *DB) InsertGA4Pages(pages []GA4Page) error {
	tx, err := db.conn.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(`INSERT INTO ga4_pages
		(snapshot_date, date_range_start, date_range_end, page_path, sessions, new_users, bounce_rate, avg_session_duration, conversions, revenue)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for _, p := range pages {
		_, err := stmt.Exec(p.SnapshotDate, p.DateRangeStart, p.DateRangeEnd, p.PagePath,
			p.Sessions, p.NewUsers, p.BounceRate, p.AvgSessionDuration, p.Conversions, p.Revenue)
		if err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (db *DB) InsertGSCQueries(queries []GSCQuery) error {
	tx, err := db.conn.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(`INSERT INTO gsc_queries
		(snapshot_date, date_range_start, date_range_end, query, page, clicks, impressions, ctr, position)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for _, q := range queries {
		_, err := stmt.Exec(q.SnapshotDate, q.DateRangeStart, q.DateRangeEnd, q.Query, q.Page,
			q.Clicks, q.Impressions, q.CTR, q.Position)
		if err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (db *DB) UpsertSnapshot(s Snapshot) error {
	_, err := db.conn.Exec(`INSERT INTO snapshots
		(snapshot_date, total_sessions, total_new_users, total_clicks, total_impressions, avg_position, total_conversions, total_revenue)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(snapshot_date) DO UPDATE SET
			total_sessions=excluded.total_sessions,
			total_new_users=excluded.total_new_users,
			total_clicks=excluded.total_clicks,
			total_impressions=excluded.total_impressions,
			avg_position=excluded.avg_position,
			total_conversions=excluded.total_conversions,
			total_revenue=excluded.total_revenue`,
		s.SnapshotDate, s.TotalSessions, s.TotalNewUsers, s.TotalClicks, s.TotalImpressions,
		s.AvgPosition, s.TotalConversions, s.TotalRevenue)
	return err
}

func (db *DB) SnapshotDates() ([]string, error) {
	rows, err := db.conn.Query(`SELECT snapshot_date FROM snapshots ORDER BY snapshot_date DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var dates []string
	for rows.Next() {
		var d string
		if err := rows.Scan(&d); err != nil {
			return nil, err
		}
		dates = append(dates, d)
	}
	return dates, nil
}

func (db *DB) LatestGA4Pages() ([]GA4Page, error) {
	rows, err := db.conn.Query(`SELECT snapshot_date, date_range_start, date_range_end, page_path,
		sessions, new_users, bounce_rate, avg_session_duration, conversions, revenue
		FROM ga4_pages WHERE snapshot_date = (SELECT MAX(snapshot_date) FROM ga4_pages)
		ORDER BY sessions DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var pages []GA4Page
	for rows.Next() {
		var p GA4Page
		if err := rows.Scan(&p.SnapshotDate, &p.DateRangeStart, &p.DateRangeEnd, &p.PagePath,
			&p.Sessions, &p.NewUsers, &p.BounceRate, &p.AvgSessionDuration, &p.Conversions, &p.Revenue); err != nil {
			return nil, err
		}
		pages = append(pages, p)
	}
	return pages, nil
}

func (db *DB) LatestGSCQueries() ([]GSCQuery, error) {
	rows, err := db.conn.Query(`SELECT snapshot_date, date_range_start, date_range_end, query, page,
		clicks, impressions, ctr, position
		FROM gsc_queries WHERE snapshot_date = (SELECT MAX(snapshot_date) FROM gsc_queries)
		ORDER BY clicks DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var queries []GSCQuery
	for rows.Next() {
		var q GSCQuery
		if err := rows.Scan(&q.SnapshotDate, &q.DateRangeStart, &q.DateRangeEnd, &q.Query, &q.Page,
			&q.Clicks, &q.Impressions, &q.CTR, &q.Position); err != nil {
			return nil, err
		}
		queries = append(queries, q)
	}
	return queries, nil
}

func (db *DB) RecentSnapshots(n int) ([]Snapshot, error) {
	rows, err := db.conn.Query(`SELECT snapshot_date, total_sessions, total_new_users,
		total_clicks, total_impressions, avg_position, total_conversions, total_revenue
		FROM snapshots ORDER BY snapshot_date DESC LIMIT ?`, n)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var snaps []Snapshot
	for rows.Next() {
		var s Snapshot
		if err := rows.Scan(&s.SnapshotDate, &s.TotalSessions, &s.TotalNewUsers,
			&s.TotalClicks, &s.TotalImpressions, &s.AvgPosition, &s.TotalConversions, &s.TotalRevenue); err != nil {
			return nil, err
		}
		snaps = append(snaps, s)
	}
	return snaps, nil
}

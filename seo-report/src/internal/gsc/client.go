package gsc

import (
	"context"
	"fmt"
	"time"

	"google.golang.org/api/option"
	searchconsole "google.golang.org/api/searchconsole/v1"
)

type Client struct {
	svc     *searchconsole.Service
	siteURL string
}


func New(ctx context.Context, credentialsFile, siteURL string) (*Client, error) {
	svc, err := searchconsole.NewService(ctx, option.WithCredentialsFile(credentialsFile))
	if err != nil {
		return nil, fmt.Errorf("create GSC client: %w", err)
	}
	return &Client{svc: svc, siteURL: siteURL}, nil
}

type QueryRow struct {
	Query       string
	Page        string
	Clicks      int64
	Impressions int64
	CTR         float64
	Position    float64
}

func (c *Client) FetchQueries(ctx context.Context, startDate, endDate string, rowLimit int64) ([]QueryRow, error) {
	req := &searchconsole.SearchAnalyticsQueryRequest{
		StartDate:  startDate,
		EndDate:    endDate,
		Dimensions: []string{"query", "page"},
		RowLimit:   rowLimit,
	}

	resp, err := c.svc.Searchanalytics.Query(c.siteURL, req).Context(ctx).Do()
	if err != nil {
		return nil, fmt.Errorf("GSC searchAnalytics.query: %w", err)
	}

	var rows []QueryRow
	for _, row := range resp.Rows {
		r := QueryRow{
			Clicks:      int64(row.Clicks),
			Impressions: int64(row.Impressions),
			CTR:         row.Ctr,
			Position:    row.Position,
		}
		if len(row.Keys) > 0 {
			r.Query = row.Keys[0]
		}
		if len(row.Keys) > 1 {
			r.Page = row.Keys[1]
		}
		rows = append(rows, r)
	}
	return rows, nil
}

// DateRange returns start/end dates for GSC (which has ~3 day lag).
func DateRange(lookbackDays int) (start, end string) {
	now := time.Now().UTC()
	end = now.AddDate(0, 0, -3).Format("2006-01-02")
	start = now.AddDate(0, 0, -(lookbackDays + 3)).Format("2006-01-02")
	return
}

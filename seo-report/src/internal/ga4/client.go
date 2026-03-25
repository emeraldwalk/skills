package ga4

import (
	"context"
	"fmt"
	"strconv"
	"time"

	analyticsdata "google.golang.org/api/analyticsdata/v1beta"
	"google.golang.org/api/option"
)

type Client struct {
	svc        *analyticsdata.Service
	propertyID string
}

func New(ctx context.Context, credentialsFile, propertyID string) (*Client, error) {
	svc, err := analyticsdata.NewService(ctx, option.WithCredentialsFile(credentialsFile))
	if err != nil {
		return nil, fmt.Errorf("create GA4 client: %w", err)
	}
	return &Client{svc: svc, propertyID: propertyID}, nil
}

type PageRow struct {
	PagePath           string
	Sessions           int64
	NewUsers           int64
	BounceRate         float64
	AvgSessionDuration float64
	Conversions        int64
	Revenue            float64
}

func (c *Client) FetchPages(ctx context.Context, startDate, endDate string, limit int64) ([]PageRow, error) {
	req := &analyticsdata.RunReportRequest{
		DateRanges: []*analyticsdata.DateRange{{
			StartDate: startDate,
			EndDate:   endDate,
		}},
		Dimensions: []*analyticsdata.Dimension{
			{Name: "pagePath"},
		},
		Metrics: []*analyticsdata.Metric{
			{Name: "sessions"},
			{Name: "newUsers"},
			{Name: "bounceRate"},
			{Name: "averageSessionDuration"},
			{Name: "conversions"},
			{Name: "totalRevenue"},
		},
		OrderBys: []*analyticsdata.OrderBy{{
			Metric: &analyticsdata.MetricOrderBy{MetricName: "sessions"},
			Desc:   true,
		}},
		Limit: limit,
	}

	resp, err := c.svc.Properties.RunReport("properties/"+c.propertyID, req).Context(ctx).Do()
	if err != nil {
		return nil, fmt.Errorf("GA4 runReport: %w", err)
	}

	var rows []PageRow
	for _, row := range resp.Rows {
		r := PageRow{
			PagePath:           row.DimensionValues[0].Value,
			Sessions:           parseInt(row.MetricValues[0].Value),
			NewUsers:           parseInt(row.MetricValues[1].Value),
			BounceRate:         parseFloat(row.MetricValues[2].Value),
			AvgSessionDuration: parseFloat(row.MetricValues[3].Value),
			Conversions:        parseInt(row.MetricValues[4].Value),
			Revenue:            parseFloat(row.MetricValues[5].Value),
		}
		rows = append(rows, r)
	}
	return rows, nil
}

// DateRange returns start/end dates for a lookback window ending today.
func DateRange(lookbackDays int) (start, end string) {
	now := time.Now().UTC()
	end = now.Format("2006-01-02")
	start = now.AddDate(0, 0, -lookbackDays).Format("2006-01-02")
	return
}

func parseInt(s string) int64 {
	v, _ := strconv.ParseInt(s, 10, 64)
	return v
}

func parseFloat(s string) float64 {
	v, _ := strconv.ParseFloat(s, 64)
	return v
}

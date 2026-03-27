package cmd

import (
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type DraftMeta struct {
	Width    int    `json:"width"`
	Height   int    `json:"height"`
	Source   string `json:"source"`
	Modified bool   `json:"modified"`
	Created  string `json:"created"`
}

// draftPath returns the draft PNG path for a given primary file.
// e.g. /path/to/some-file.png -> /path/to/some-file.draft.png
func draftPath(filePath string) string {
	ext := filepath.Ext(filePath)
	base := strings.TrimSuffix(filePath, ext)
	return base + ".draft" + ext
}

// draftMetaPath returns the metadata JSON path for a given primary file.
// e.g. /path/to/some-file.png -> /path/to/some-file.draft.json
func draftMetaPath(filePath string) string {
	ext := filepath.Ext(filePath)
	base := strings.TrimSuffix(filePath, ext)
	return base + ".draft.json"
}

func draftExists(filePath string) bool {
	_, err := os.Stat(draftPath(filePath))
	return err == nil
}

func loadDraft(filePath string) (*image.NRGBA, error) {
	f, err := os.Open(draftPath(filePath))
	if err != nil {
		return nil, fmt.Errorf("no draft for %q, run 'pixedit open' or 'pixedit new' first", filePath)
	}
	defer f.Close()

	img, err := png.Decode(f)
	if err != nil {
		return nil, fmt.Errorf("failed to decode draft: %w", err)
	}

	bounds := img.Bounds()
	out := image.NewNRGBA(bounds)
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			out.Set(x, y, img.At(x, y))
		}
	}
	return out, nil
}

func saveDraft(img *image.NRGBA, filePath string) error {
	f, err := os.Create(draftPath(filePath))
	if err != nil {
		return fmt.Errorf("failed to write draft: %w", err)
	}
	defer f.Close()
	return png.Encode(f, img)
}

func loadMeta(filePath string) (*DraftMeta, error) {
	data, err := os.ReadFile(draftMetaPath(filePath))
	if err != nil {
		return nil, err
	}
	var m DraftMeta
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, err
	}
	return &m, nil
}

func saveMeta(m *DraftMeta, filePath string) error {
	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(draftMetaPath(filePath), data, 0644)
}

func requireDraft(filePath string) (*image.NRGBA, *DraftMeta, error) {
	if !draftExists(filePath) {
		return nil, nil, fmt.Errorf("no draft for %q, run 'pixedit open' or 'pixedit new' first", filePath)
	}
	img, err := loadDraft(filePath)
	if err != nil {
		return nil, nil, err
	}
	meta, err := loadMeta(filePath)
	if err != nil {
		bounds := img.Bounds()
		meta = &DraftMeta{
			Width:  bounds.Max.X,
			Height: bounds.Max.Y,
		}
	}
	return img, meta, nil
}

func colorToHex(c color.Color) string {
	r, g, b, _ := c.RGBA()
	return fmt.Sprintf("#%02X%02X%02X", r>>8, g>>8, b>>8)
}

func parseHex(s string) (color.NRGBA, error) {
	if len(s) > 0 && s[0] == '#' {
		s = s[1:]
	}
	if len(s) == 3 {
		s = string([]byte{s[0], s[0], s[1], s[1], s[2], s[2]})
	}
	if len(s) != 6 {
		return color.NRGBA{}, fmt.Errorf("invalid color %q, expected hex like #FF0000", "#"+s)
	}
	var r, g, b uint8
	_, err := fmt.Sscanf(s, "%02X%02X%02X", &r, &g, &b)
	if err != nil {
		return color.NRGBA{}, fmt.Errorf("invalid color %q", "#"+s)
	}
	return color.NRGBA{R: r, G: g, B: b, A: 255}, nil
}

func newMeta(w, h int, source string) *DraftMeta {
	return &DraftMeta{
		Width:    w,
		Height:   h,
		Source:   source,
		Modified: false,
		Created:  time.Now().Format(time.RFC3339),
	}
}

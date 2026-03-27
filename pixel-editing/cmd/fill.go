package cmd

import (
	"fmt"
	"strconv"

	"github.com/spf13/cobra"
)

var fillCmd = &cobra.Command{
	Use:   "fill <file> <x> <y> <width> <height> <color>",
	Short: "Fill a rectangular region with a color",
	Long: `Fill a rectangular region of the draft with a solid color.

The region is defined by its top-left corner (x, y) and its dimensions.
All coordinates are 0-indexed from the top-left corner. Requires an open draft.

Arguments:
  file    Primary PNG path with an open draft
  x       X coordinate of the top-left corner
  y       Y coordinate of the top-left corner
  width   Width of the region in pixels (must be > 0)
  height  Height of the region in pixels (must be > 0)
  color   Hex color: #FF0000, #F00, or FF0000

Output:
  x=<x> y=<y> width=<w> height=<h> color=#RRGGBB pixels=<count>

Example:
  pixedit fill sprite.png 0 0 16 16 FFFFFF`,
	Args: cobra.ExactArgs(6),
	RunE: func(cmd *cobra.Command, args []string) error {
		file := args[0]
		x, err := strconv.Atoi(args[1])
		if err != nil {
			return fmt.Errorf("invalid x %q", args[1])
		}
		y, err := strconv.Atoi(args[2])
		if err != nil {
			return fmt.Errorf("invalid y %q", args[2])
		}
		w, err := strconv.Atoi(args[3])
		if err != nil || w <= 0 {
			return fmt.Errorf("invalid width %q", args[3])
		}
		h, err := strconv.Atoi(args[4])
		if err != nil || h <= 0 {
			return fmt.Errorf("invalid height %q", args[4])
		}
		c, err := parseHex(args[5])
		if err != nil {
			return err
		}

		img, meta, err := requireDraft(file)
		if err != nil {
			return err
		}

		b := img.Bounds()
		if x < b.Min.X || y < b.Min.Y || x+w > b.Max.X || y+h > b.Max.Y {
			return fmt.Errorf("region (%d,%d)+%dx%d out of bounds (width=%d height=%d)", x, y, w, h, meta.Width, meta.Height)
		}

		for py := y; py < y+h; py++ {
			for px := x; px < x+w; px++ {
				img.Set(px, py, c)
			}
		}

		if err := saveDraft(img, file); err != nil {
			return err
		}

		meta.Modified = true
		if err := saveMeta(meta, file); err != nil {
			return err
		}

		fmt.Printf("x=%d y=%d width=%d height=%d color=%s pixels=%d\n", x, y, w, h, colorToHex(c), w*h)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(fillCmd)
}

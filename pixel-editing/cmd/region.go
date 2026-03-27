package cmd

import (
	"fmt"
	"strconv"

	"github.com/spf13/cobra"
)

var regionCmd = &cobra.Command{
	Use:   "region <file> <x> <y> <width> <height>",
	Short: "Read pixel colors in a rectangular region",
	Long: `Read the color of every pixel in a rectangular region of the draft.

Output begins with a header line, followed by one line per pixel.
All coordinates are 0-indexed from the top-left corner. Requires an open draft.

Arguments:
  file    Primary PNG path with an open draft
  x       X coordinate of the top-left corner
  y       Y coordinate of the top-left corner
  width   Width of the region in pixels (must be > 0)
  height  Height of the region in pixels (must be > 0)

Output:
  x=<x> y=<y> width=<w> height=<h>
  <px>,<py> #RRGGBB    (one line per pixel, left-to-right, top-to-bottom)

Example:
  pixedit region sprite.png 0 0 4 4`,
	Args: cobra.ExactArgs(5),
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

		img, meta, err := requireDraft(file)
		if err != nil {
			return err
		}

		b := img.Bounds()
		if x < b.Min.X || y < b.Min.Y || x+w > b.Max.X || y+h > b.Max.Y {
			return fmt.Errorf("region (%d,%d)+%dx%d out of bounds (width=%d height=%d)", x, y, w, h, meta.Width, meta.Height)
		}

		fmt.Printf("x=%d y=%d width=%d height=%d\n", x, y, w, h)
		for py := y; py < y+h; py++ {
			for px := x; px < x+w; px++ {
				c := img.At(px, py)
				fmt.Printf("%d,%d %s\n", px, py, colorToHex(c))
			}
		}
		return nil
	},
}

func init() {
	rootCmd.AddCommand(regionCmd)
}

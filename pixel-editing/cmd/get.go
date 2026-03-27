package cmd

import (
	"fmt"
	"strconv"

	"github.com/spf13/cobra"
)

var getCmd = &cobra.Command{
	Use:   "get <file> <x> <y>",
	Short: "Read the color of a single pixel",
	Long: `Read the color of a single pixel from the draft.

Coordinates are 0-indexed from the top-left corner. Requires an open draft
(run 'open' or 'new' first).

Arguments:
  file    Primary PNG path with an open draft
  x       X coordinate (0 = left edge)
  y       Y coordinate (0 = top edge)

Output:
  x=<x> y=<y> color=#RRGGBB r=<0-255> g=<0-255> b=<0-255>

Example:
  pixedit get sprite.png 3 7`,
	Args: cobra.ExactArgs(3),
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

		img, meta, err := requireDraft(file)
		if err != nil {
			return err
		}

		b := img.Bounds()
		if x < b.Min.X || x >= b.Max.X || y < b.Min.Y || y >= b.Max.Y {
			return fmt.Errorf("coordinates (%d,%d) out of bounds (width=%d height=%d)", x, y, meta.Width, meta.Height)
		}

		c := img.At(x, y)
		r, g, bl, _ := c.RGBA()
		hex := colorToHex(c)

		fmt.Printf("x=%d y=%d color=%s r=%d g=%d b=%d\n", x, y, hex, r>>8, g>>8, bl>>8)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(getCmd)
}

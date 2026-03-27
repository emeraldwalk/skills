package cmd

import (
	"fmt"
	"strconv"

	"github.com/spf13/cobra"
)

var setCmd = &cobra.Command{
	Use:   "set <file> <x> <y> <color>",
	Short: "Set a single pixel color (e.g. #FF0000)",
	Long: `Set the color of a single pixel in the draft.

Coordinates are 0-indexed from the top-left corner. Requires an open draft.
The '#' prefix in color is optional; quote it in shells to avoid expansion.

Arguments:
  file    Primary PNG path with an open draft
  x       X coordinate (0 = left edge)
  y       Y coordinate (0 = top edge)
  color   Hex color: #FF0000, #F00, or FF0000

Output:
  x=<x> y=<y> color=#RRGGBB

Example:
  pixedit set sprite.png 3 7 '#FF0000'`,
	Args: cobra.ExactArgs(4),
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
		c, err := parseHex(args[3])
		if err != nil {
			return err
		}

		img, meta, err := requireDraft(file)
		if err != nil {
			return err
		}

		b := img.Bounds()
		if x < b.Min.X || x >= b.Max.X || y < b.Min.Y || y >= b.Max.Y {
			return fmt.Errorf("coordinates (%d,%d) out of bounds (width=%d height=%d)", x, y, meta.Width, meta.Height)
		}

		img.Set(x, y, c)

		if err := saveDraft(img, file); err != nil {
			return err
		}

		meta.Modified = true
		if err := saveMeta(meta, file); err != nil {
			return err
		}

		fmt.Printf("x=%d y=%d color=%s\n", x, y, colorToHex(c))
		return nil
	},
}

func init() {
	rootCmd.AddCommand(setCmd)
}

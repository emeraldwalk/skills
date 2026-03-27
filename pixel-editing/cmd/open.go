package cmd

import (
	"fmt"
	"image"
	"image/png"
	"os"

	"github.com/spf13/cobra"
)

var openCmd = &cobra.Command{
	Use:   "open <file>",
	Short: "Open a PNG file into a draft for editing",
	Long: `Copy a PNG file into a draft for editing.

The draft is written to <dir>/<name>.draft.png beside the original file.
Edit the draft using get/set/fill/region, then 'save' to write back.

Arguments:
  file    Path to an existing PNG file

Output:
  draft=open width=<w> height=<h> source=<file> path=<draft-path>

Example:
  pixedit open artwork.png`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		file := args[0]

		f, err := os.Open(file)
		if err != nil {
			return fmt.Errorf("cannot open file %q: %w", file, err)
		}
		defer f.Close()

		src, err := png.Decode(f)
		if err != nil {
			return fmt.Errorf("failed to decode PNG %q: %w", file, err)
		}

		bounds := src.Bounds()
		img := image.NewNRGBA(bounds)
		for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
			for x := bounds.Min.X; x < bounds.Max.X; x++ {
				img.Set(x, y, src.At(x, y))
			}
		}

		if err := saveDraft(img, file); err != nil {
			return err
		}

		w := bounds.Max.X - bounds.Min.X
		h := bounds.Max.Y - bounds.Min.Y
		if err := saveMeta(newMeta(w, h, file), file); err != nil {
			return err
		}

		fmt.Printf("draft=open width=%d height=%d source=%s path=%s\n", w, h, file, draftPath(file))
		return nil
	},
}

func init() {
	rootCmd.AddCommand(openCmd)
}

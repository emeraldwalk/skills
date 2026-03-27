package cmd

import (
	"fmt"
	"image"
	"image/color"
	"strconv"

	"github.com/spf13/cobra"
)

var newCmd = &cobra.Command{
	Use:   "new <file> <width> <height>",
	Short: "Create a new blank canvas at the given file path",
	Long: `Create a new blank canvas and save it as a draft beside the given file path.

The draft is written to <dir>/<name>.draft.png (e.g. foo.draft.png for foo.png).
The canvas is filled with opaque black (#000000) by default.

Arguments:
  file    Target PNG path (e.g. sprite.png). Does not need to exist yet.
  width   Canvas width in pixels (must be > 0)
  height  Canvas height in pixels (must be > 0)

Output:
  draft=new width=<w> height=<h> path=<draft-path>

Example:
  pixedit new sprite.png 16 16`,
	Args: cobra.ExactArgs(3),
	RunE: func(cmd *cobra.Command, args []string) error {
		file := args[0]
		w, err := strconv.Atoi(args[1])
		if err != nil || w <= 0 {
			return fmt.Errorf("invalid width %q", args[1])
		}
		h, err := strconv.Atoi(args[2])
		if err != nil || h <= 0 {
			return fmt.Errorf("invalid height %q", args[2])
		}

		img := image.NewNRGBA(image.Rect(0, 0, w, h))
		for y := 0; y < h; y++ {
			for x := 0; x < w; x++ {
				img.Set(x, y, color.NRGBA{0, 0, 0, 255})
			}
		}

		if err := saveDraft(img, file); err != nil {
			return err
		}
		if err := saveMeta(newMeta(w, h, ""), file); err != nil {
			return err
		}

		fmt.Printf("draft=new width=%d height=%d path=%s\n", w, h, draftPath(file))
		return nil
	},
}

func init() {
	rootCmd.AddCommand(newCmd)
}

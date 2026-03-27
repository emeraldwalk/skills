package cmd

import (
	"fmt"
	"image/png"
	"os"

	"github.com/spf13/cobra"
)

var saveCmd = &cobra.Command{
	Use:   "save <file>",
	Short: "Save the draft back to the original file",
	Long: `Write the current draft back to the primary file path.

Overwrites the original file with the draft contents. The draft and its
metadata are kept — use 'close' to remove them.

Arguments:
  file    Primary PNG path to save the draft into

Output:
  saved=<file> width=<w> height=<h>

Example:
  pixedit save artwork.png`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		file := args[0]

		img, meta, err := requireDraft(file)
		if err != nil {
			return err
		}

		f, err := os.Create(file)
		if err != nil {
			return fmt.Errorf("cannot write file %q: %w", file, err)
		}
		defer f.Close()

		if err := png.Encode(f, img); err != nil {
			return fmt.Errorf("failed to encode PNG: %w", err)
		}

		meta.Modified = false
		meta.Source = file
		if err := saveMeta(meta, file); err != nil {
			return err
		}

		fmt.Printf("saved=%s width=%d height=%d\n", file, meta.Width, meta.Height)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(saveCmd)
}

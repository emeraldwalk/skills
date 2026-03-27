package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

var statusCmd = &cobra.Command{
	Use:   "status <file>",
	Short: "Show draft info for the given file",
	Long: `Show information about the current draft for the given file.

Run this before editing to confirm a draft is open and get image dimensions.

Arguments:
  file    Primary PNG path to check

Output (draft exists):
  status=open width=<w> height=<h> modified=<true|false> source=<path> path=<draft-path>

Output (no draft):
  status=no_draft

Example:
  pixedit status artwork.png`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		file := args[0]

		if !draftExists(file) {
			fmt.Println("status=no_draft")
			return nil
		}

		meta, err := loadMeta(file)
		if err != nil {
			img, err2 := loadDraft(file)
			if err2 != nil {
				return err2
			}
			b := img.Bounds()
			fmt.Printf("status=open width=%d height=%d modified=unknown source=unknown path=%s\n",
				b.Max.X, b.Max.Y, draftPath(file))
			return nil
		}

		source := meta.Source
		if source == "" {
			source = "none"
		}
		fmt.Printf("status=open width=%d height=%d modified=%v source=%s path=%s\n",
			meta.Width, meta.Height, meta.Modified, source, draftPath(file))
		return nil
	},
}

func init() {
	rootCmd.AddCommand(statusCmd)
}

package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var closeCmd = &cobra.Command{
	Use:   "close <file>",
	Short: "Discard the draft for the given file",
	Long: `Discard the draft and metadata for the given file without saving.

Deletes <name>.draft.png and <name>.draft.json if they exist.
Use 'save' instead to preserve changes.

Arguments:
  file    Primary PNG path whose draft should be discarded

Output:
  status=closed     (draft deleted)
  status=no_draft   (no draft existed)

Example:
  pixedit close artwork.png`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		file := args[0]

		if !draftExists(file) {
			fmt.Println("status=no_draft")
			return nil
		}

		os.Remove(draftPath(file))
		os.Remove(draftMetaPath(file))

		fmt.Println("status=closed")
		return nil
	},
}

func init() {
	rootCmd.AddCommand(closeCmd)
}

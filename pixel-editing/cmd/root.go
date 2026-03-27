package cmd

import (
	"os"

	"github.com/spf13/cobra"
)

var rootCmd = &cobra.Command{
	Use:   "pixedit",
	Short: "A pixel art editor for AI agents",
	Long: `pixedit is a CLI pixel art editor designed for use by AI agents.

All commands require the primary file path as the first argument. Edits are
staged in a draft file beside the original (e.g. foo.draft.png for foo.png)
until saved with 'pixedit save <file>'.

Output is key=value pairs on stdout. Errors go to stderr; exit code 1 on failure.

Colors are specified as hex: #FF0000, #F00, or FF0000 (3 or 6 digits).
Coordinates are 0-indexed from the top-left corner.

Workflow:
  pixedit new <file> <w> <h>          create blank canvas
  pixedit open <file>                 open existing PNG
  pixedit status <file>               check draft state and dimensions
  pixedit get/set/fill/region <file>  inspect and edit pixels
  pixedit save <file>                 write draft back to file
  pixedit close <file>                discard draft without saving`,
	SilenceUsage: true,
}

func Execute() {
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

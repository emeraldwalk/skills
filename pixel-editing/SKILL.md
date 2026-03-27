---
name: pixel-editing
description: Edits PNG images pixel-by-pixel using the pixedit CLI tool. Use when asked to create, modify, inspect, or manipulate pixel art or PNG images — including setting pixel colors, filling regions, reading color values, opening/saving files, or any raster image editing task. Triggers on requests like "edit this image", "create pixel art", "change the color of this region", "read pixel colors", or any task involving PNG pixel manipulation.
---

# pixedit

CLI pixel art editor for agents. Operates on PNG files with a draft-based workflow: edits go to a `.draft.png` beside the original until explicitly saved.

## Launching pixedit

Use the OS-agnostic wrapper — it auto-selects the right binary for the current platform:

```bash
scripts/pixedit.sh <command> [args]   # Linux / macOS
scripts\pixedit.bat <command> [args]  # Windows
```

The wrapper looks for a platform binary in `bin/pixedit-<os>-<arch>[.exe]` and falls back to a bare `pixedit` binary in the project root. Run `scripts/pixedit.sh --help` to confirm it's working.

To build a platform binary manually:

```bash
GOOS=linux GOARCH=amd64 go build -o bin/pixedit-linux-amd64 .
```

## Workflow

```
open/new → get/set/fill/region (repeat) → save → close (optional cleanup)
```

1. **Open or create** a file to start a draft
2. **Check status** to confirm dimensions before editing
3. **Inspect and edit** pixels using `get`, `set`, `fill`, `region`
4. **Save** the draft back to the original file
5. **Close** to discard the draft if needed

All commands take the primary file path as the first argument. The draft is stored at `<dir>/<name>.draft.png` beside the original, with metadata at `<name>.draft.json`.

## Commands

All output is `key=value` pairs on stdout (machine-parseable). Errors go to stderr; exit code 1 on failure. Run any command with `--help` for full argument and output documentation.

### Open / Create

```bash
pixedit open <file>
# draft=open width=N height=N source=<file> path=<file.draft.png>

pixedit new <file> <width> <height>
# draft=new width=N height=N path=<file.draft.png>
```

### Status / Close

```bash
pixedit status <file>
# status=open width=N height=N modified=true/false source=<file> path=<draft>
# status=no_draft

pixedit close <file>
# status=closed  |  status=no_draft
```

### Save

```bash
pixedit save <file>
# saved=<file> width=N height=N
```

### Pixel Operations

```bash
pixedit get <file> <x> <y>
# x=N y=N color=#RRGGBB r=N g=N b=N

pixedit set <file> <x> <y> <color>
# x=N y=N color=#RRGGBB

pixedit fill <file> <x> <y> <width> <height> <color>
# x=N y=N width=N height=N color=#RRGGBB pixels=N

pixedit region <file> <x> <y> <width> <height>
# x=N y=N width=N height=N
# x,y #RRGGBB   (one line per pixel, left-to-right top-to-bottom)
```

**Colors:** `#FF0000`, `#F00`, or `FF0000`. Quote `#` in shells: `'#FF0000'`.
**Coordinates:** 0-indexed from top-left. Operations return an error on out-of-bounds access.

## Example Workflows

**Edit an existing image:**

```bash
pixedit open artwork.png
pixedit status artwork.png          # confirm width/height before editing
pixedit set artwork.png 10 20 '#FF0000'
pixedit fill artwork.png 0 0 8 8 '#0000FF'
pixedit save artwork.png
```

**Create a new 16×16 sprite:**

```bash
pixedit new sprite.png 16 16
pixedit fill sprite.png 0 0 16 16 FFFFFF   # white background
pixedit set sprite.png 8 8 '#FF0000'        # red center pixel
pixedit save sprite.png
```

**Inspect a region:**

```bash
pixedit region artwork.png 0 0 4 4   # returns all 16 pixel colors
```

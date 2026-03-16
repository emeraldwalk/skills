---
name: godot-docs
description: Look up Godot 4.x API documentation — classes, methods, properties, signals, enums. Use when implementing any Godot feature, when you need to know how a Godot class works, or before writing any Godot code.
---

Search Godot 4.x class reference docs via the `docs-reading` CLI. Run all commands from the `docs-reading` skill directory.

The DB is pre-scoped to Godot — always pass `--corpus godot` to all commands.

## Typical workflow

```bash
# 1. Search first — usually sufficient. Results include chunk IDs and source files.
uv run scripts/docs.py search "CharacterBody3D move_and_slide" --corpus godot

# 2. Fetch a specific chunk if you need full content
uv run scripts/docs.py chunk 1234

# 3. When exploring a whole class — get the outline first, then fetch specific chunks
uv run scripts/docs.py outline "doc/classes/CharacterBody3D.xml" --corpus godot
uv run scripts/docs.py chunk 1234

# 4. Find semantically similar chunks (requires embeddings)
uv run scripts/docs.py related 1234
```

## Setup (one-time human step)

Clone the Godot repo and parse the docs:

```bash
cd ~/.claude/skills/docs-reading

uv run scripts/parse_godot.py \
  --godot-repo /path/to/godot \
  --db dbs/godot.db \
  --corpus-name godot \
  --corpus-version 4.6
```

No further configuration needed — no MCP server, no settings changes.

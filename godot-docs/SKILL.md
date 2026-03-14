---
name: godot-docs
description: Look up Godot 4.x API documentation — classes, methods, properties, signals, enums. Use when implementing any Godot feature, when you need to know how a Godot class works, or before writing any Godot code.
---

Search Godot 4.x class reference docs via the `godot-docs` MCP server.

The MCP server is pre-configured for Godot — no corpus filters needed. You may omit `corpus_name` and `corpus_version` from all calls.

## Typical workflow

1. **Search first** — this is usually sufficient. Results include content, chunk IDs, and source files:
   ```
   search_docs(query="CharacterBody3D move_and_slide")
   ```
2. **Fetch if needed** — if a search result's content is truncated or you need the full chunk:
   ```
   get_chunk(chunk_id=1234)
   ```
3. **Browse only when exploring a whole class** — get the outline of all chunks in a file, then fetch specific ones:
   ```
   get_doc_outline(source_file="doc/classes/CharacterBody3D.xml")
   get_chunk(chunk_id=1234)
   ```
4. **Related** — find semantically similar chunks:
   ```
   get_related_chunks(chunk_id=1234)
   ```

## Setup

### 1. Parse the Godot docs

Clone the Godot repo and run the parser once:

```bash
cd /Users/bingles/.claude/skills/docs-reading

uv run scripts/parse_godot.py \
  --godot-repo /path/to/godot \
  --db dbs/godot.db \
  --corpus-name godot \
  --corpus-version 4.6
```

### 2. Configure the MCP server in `~/.claude.json`

Add this entry under `"mcpServers"`:

```json
"godot-docs": {
  "type": "stdio",
  "command": "uv",
  "args": [
    "run",
    "--python", "3.12",
    "/Users/bingles/.claude/skills/docs-reading/scripts/mcp_server.py",
    "--db", "/Users/bingles/.claude/skills/docs-reading/dbs/godot.db",
    "--corpus-name", "godot",
    "--corpus-version", "4.6"
  ],
  "env": {}
}
```

### 3. Restart Claude Code

The MCP server starts automatically on next launch. Tools (`search_docs`, `get_chunk`, etc.) will appear under the `godot-docs` server.

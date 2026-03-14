---
name: docs-reading
description: Parses technical documentation corpora (Markdown or Godot XML) into a local SQLite database with full-text and semantic search, then serves them to agents via an MCP server. Use when an agent needs to read, search, or reference documentation for a library, framework, or engine — especially large docs that would exceed context limits.
---

## Overview

docs-reading is a two-phase pipeline:

1. **Parse** — A human runs a parser script once to ingest documentation into a local SQLite database with FTS5 full-text search and optional sentence-embedding vectors. Multiple corpora and versions can coexist in a single DB.
2. **Serve** — An MCP server exposes 6 tools that agents use to search, browse, and retrieve documentation at query time without ever loading the raw files into context.

## Parsing (human setup step)

### Generic Markdown

```bash
uv run scripts/parse_docs.py \
  --input /path/to/docs \
  --db ./docs.db \
  --corpus-name mylib \
  --corpus-version 1.0
```

Options: `--glob "**/*.md"` (default), `--max-tokens 512`, `--min-tokens 50`, `--no-embeddings`, `--force`

### Godot XML

```bash
uv run scripts/parse_godot.py \
  --godot-repo ./godot \
  --db ./godot.db \
  --corpus-name godot \
  --corpus-version 4.6
```

Parses the engine's native XML class reference (one chunk per method/property/signal/enum). Version is auto-detected from `version.py` if `--corpus-version` is omitted.

### Multi-corpus workflow

Multiple corpora can share one DB — just run parsers targeting the same `--db`:

```bash
uv run scripts/parse_docs.py --input ./react-docs --db ./project.db --corpus-name react --corpus-version 18
uv run scripts/parse_docs.py --input ./typescript-docs --db ./project.db --corpus-name typescript --corpus-version 5.4
```

### Embeddings (optional but recommended)

```bash
uv run scripts/add_embeddings.py --db ./docs.db
# Limit to one corpus:
uv run scripts/add_embeddings.py --db ./project.db --corpus-name react --corpus-version 18
```

The first run downloads the `all-MiniLM-L6-v2` model (~80 MB, cached locally).

## MCP Server (agent consumption)

Start the server pointing at your database:

```bash
# Single corpus
uv run scripts/mcp_server.py --db ./godot.db --corpus-name godot --corpus-version 4.6

# Multi-corpus (search across all corpora)
uv run scripts/mcp_server.py --db ./project.db
```

### Claude Code MCP config

Add to your `claude_code` settings (`~/.claude/settings.json` or project `.claude/settings.json`):

```json
{
  "mcpServers": {
    "docs-reading": {
      "command": "uv",
      "args": [
        "run",
        "/path/to/skills/docs-reading/scripts/mcp_server.py",
        "--db", "/path/to/your/docs.db",
        "--corpus-name", "godot",
        "--corpus-version", "4.6"
      ]
    }
  }
}
```

For multi-corpus, omit `--corpus-name` and `--corpus-version`.

## Agent usage guidance

Always pass `corpus_name` (and `corpus_version` if relevant) to `search_docs` unless you explicitly want cross-corpus results. Without a filter, results from multiple versions of the same library will mix and may conflict.

Typical agent workflow:
1. Call `list_corpuses` to confirm what's available and which versions are loaded.
2. Call `search_docs` with `corpus_name` and `corpus_version` set.
3. Use `get_doc_outline` to browse a file's structure before fetching full chunks.
4. Call `get_chunk` by ID to retrieve full content for a specific result.

## MCP Tools available to agents

| Tool | Description |
|------|-------------|
| `search_docs` | Hybrid FTS5 + semantic search. Accepts `query`, `limit`, optional `corpus_name`/`corpus_version` filters. |
| `get_chunk` | Fetch full content of a chunk by integer ID. |
| `get_doc_outline` | Heading tree for a source file — useful before fetching full content. |
| `list_files` | List all parsed files with corpus, version, path, chunk count. |
| `list_corpuses` | List all corpora with file and chunk counts. |
| `get_related_chunks` | Semantically similar chunks to a given chunk ID (requires embeddings). |

## Dependencies

Scripts use `uv run` with inline dependency blocks — no install step needed. Just run with `uv run scripts/<script>.py ...` and uv handles the environment automatically.

Requires `uv` to be installed: https://docs.astral.sh/uv/getting-started/installation/

**Python version note:** `parse_docs.py` and `parse_godot.py` work on any Python version when run with `--no-embeddings` (no heavy dependencies). Generating embeddings requires Python ≤ 3.13 because `torch` (a `sentence-transformers` dependency) has no wheels for Python 3.14+ yet. Use `add_embeddings.py` on a Python ≤ 3.13 environment to add embeddings after a no-embeddings parse.

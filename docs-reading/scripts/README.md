# docs-mcp

A local MCP server that parses markdown technical documentation into an AI-agent-optimized format, stored in SQLite with full-text + semantic search.

## Stack

| Component | Tool | Why |
|-----------|------|-----|
| Parser | Python + mistune | Fast, spec-compliant markdown AST |
| Storage | SQLite + FTS5 | Zero-infra, file-based, built-in full-text search |
| Embeddings | sentence-transformers (`all-MiniLM-L6-v2`) | 80MB, fully local, no API key |
| MCP Server | fastmcp | Minimal boilerplate, stdio transport |
| Clients | Claude Code CLI + VS Code (Claude/Copilot) | Config included |

## Setup

### 1. Install dependencies

```bash
pip install mcp mistune sentence-transformers numpy
```

> The embedding model (~80MB) downloads automatically on first use and is cached locally. No API key needed.

---

## Godot 4.x Quick Start (recommended)

The native Godot XML parser is the best option for Godot docs. It parses
the engine's source-of-truth class reference directly — no conversion needed,
exact method signatures, full type information.

```bash
# 1. Clone the Godot engine repo (shallow = fast, ~200MB)
git clone --depth 1 --branch 4.6-stable https://github.com/godotengine/godot.git

# 2. Parse the class reference (fast mode first, add embeddings after)
python parser/parse_godot.py --godot-repo ./godot --db ./godot46.db --no-embeddings

# 3. Add embeddings (downloads model on first run)
python parser/add_embeddings.py --db ./godot46.db

# 4. Test search
python scripts/search_cli.py --db ./godot46.db "move character physics"

# 5. Start MCP server
python server/mcp_server.py --db ./godot46.db
```

**Include module docs** (GDNative, NavigationServer, etc.):
```bash
python parser/parse_godot.py --godot-repo ./godot --db ./godot46.db --all-modules
```

**Updating to a new Godot version:**
```bash
cd godot && git fetch && git checkout 4.7-stable && cd ..
python parser/parse_godot.py --godot-repo ./godot --db ./godot46.db
# Only changed files are re-parsed
```

---

## Generic Markdown Docs

For non-Godot markdown documentation corpora:

```bash
python parser/parse_docs.py \
  --input /path/to/docs \
  --db ./docs.db \
  --max-tokens 512 \
  --min-tokens 50 \
  --glob "**/*.md" \
  --no-embeddings
```

---

## Parsing Details

### Godot XML Strategy (one chunk per API member)

Each class XML file is parsed into fine-grained chunks:

| Chunk type | Content | Typical tokens |
|------------|---------|----------------|
| Class overview | brief + full description + API index | 100–400 |
| Method | signature + parameters + return type + description | 80–300 |
| Property | type + default + getter/setter + description | 50–150 |
| Signal | signature + parameters + description | 40–120 |
| Enum | all constants in the enum with values + descriptions | 60–200 |

This means a query for `move_and_slide` returns exactly that method's chunk —
not the entire CharacterBody2D page. Agents get precise, token-efficient context.

### Markdown Strategy (heading-aware chunks)

Documents are split heading-aware with a 512-token cap. Each heading + content
forms a chunk, oversized sections split on paragraph boundaries, undersized
chunks merged with siblings.

### Re-parsing / Incremental Updates

Files are SHA-256 hashed. Re-running only re-parses changed files:
```bash
python parser/parse_godot.py --godot-repo ./godot --db ./godot46.db
# "[  42/1200] Skipped CharacterBody2D.xml (unchanged)"
# "[  43/1200] Parsed  Input.xml  18 chunks"
```

---

## MCP Tools

The server exposes these tools to agents:

| Tool | Description |
|------|-------------|
| `search_docs` | Hybrid FTS5 + semantic search. Returns ranked chunks with context. |
| `get_chunk` | Fetch a specific chunk by ID |
| `get_doc_outline` | Return the heading tree for a source file |
| `list_files` | List all parsed files with metadata |
| `get_related_chunks` | Find chunks semantically similar to a given chunk ID |

---

## Project Structure

```
docs-mcp/
├── parser/
│   ├── parse_godot.py       # Godot XML class ref parser (primary)
│   ├── godot_xml_parser.py  # XML → chunks logic (one chunk per method/property/signal/enum)
│   ├── parse_docs.py        # Generic markdown parser
│   ├── chunker.py           # Heading-aware markdown chunker
│   ├── add_embeddings.py    # Add embeddings to an existing DB
│   ├── embedder.py          # sentence-transformers wrapper
│   └── db.py                # SQLite schema + helpers
├── server/
│   └── mcp_server.py        # MCP server (5 tools)
├── config/
│   ├── claude_code.json     # Claude Code CLI config snippet
│   └── vscode_mcp.json      # VS Code .vscode/mcp.json
├── scripts/
│   └── search_cli.py        # CLI search for testing
└── README.md
```

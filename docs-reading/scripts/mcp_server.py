#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9,<3.14"
# dependencies = [
#   "fastmcp",
#   "sentence-transformers",
#   "numpy",
# ]
# ///
"""
mcp_server.py — MCP server for the docs-reading skill.

Exposes 6 tools to AI agents for searching and browsing parsed documentation:
  search_docs       — Hybrid FTS5 + semantic search
  get_chunk         — Fetch a chunk by ID
  get_doc_outline   — Heading tree for a source file
  list_files        — List all parsed files
  list_corpuses     — List all known corpuses
  get_related_chunks — Semantically similar chunks

Usage:
    # Single corpus
    python scripts/mcp_server.py --db ./godot.db --corpus-name godot --corpus-version 4.6

    # Multi-corpus (search across everything)
    python scripts/mcp_server.py --db ./project.db
"""

import argparse
import sys
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).parent))

from db import get_connection, decode_embedding, list_corpuses as db_list_corpuses

_SKILL_DBS = Path(__file__).parent.parent / "dbs"


def _resolve_db(db_arg: str | None) -> Path:
    """Return DB path: explicit arg, auto-detected from dbs/, or error."""
    if db_arg:
        return Path(db_arg)
    dbs = list(_SKILL_DBS.glob("*.db")) if _SKILL_DBS.exists() else []
    if len(dbs) == 1:
        print(f"Using {dbs[0]}")
        return dbs[0]
    if len(dbs) > 1:
        names = "\n  ".join(str(d) for d in dbs)
        print(f"ERROR: Multiple databases found — specify one with --db:\n  {names}")
        sys.exit(1)
    print(f"ERROR: No database found in {_SKILL_DBS}. Parse some docs first.")
    sys.exit(1)

# ── fastmcp import ────────────────────────────────────────────────────────────
try:
    from fastmcp import FastMCP
except ImportError:
    try:
        from mcp.server.fastmcp import FastMCP
    except ImportError:
        print(
            "ERROR: fastmcp / mcp package not found.\n"
            "Install with: pip install fastmcp\n"
            "  or:         pip install mcp"
        )
        sys.exit(1)

# ── numpy (optional, for cosine similarity) ───────────────────────────────────
try:
    import numpy as np
    _HAS_NUMPY = True
except ImportError:
    _HAS_NUMPY = False

# ── Global state set at startup ───────────────────────────────────────────────
_db_path: str = ""
_default_corpus_name: Optional[str] = None
_default_corpus_version: Optional[str] = None

# Embedding cache: (corpus_id) → {"ids": [...], "matrix": np.ndarray}
_embedding_cache: dict = {}


# ── Helpers ───────────────────────────────────────────────────────────────────

def _conn():
    return get_connection(_db_path)


def _resolve_corpus_filter(
    corpus_name: Optional[str],
    corpus_version: Optional[str],
) -> tuple[Optional[str], Optional[str]]:
    """Apply caller-supplied filters, falling back to server defaults."""
    name    = corpus_name    if corpus_name    is not None else _default_corpus_name
    version = corpus_version if corpus_version is not None else _default_corpus_version
    return name, version


def _corpus_ids_for(
    conn,
    corpus_name: Optional[str],
    corpus_version: Optional[str],
) -> list[int]:
    """Return corpus_id list matching the given name/version filters."""
    if corpus_name is None:
        rows = conn.execute("SELECT id FROM corpuses").fetchall()
        return [r["id"] for r in rows]

    if corpus_version is not None:
        row = conn.execute(
            "SELECT id FROM corpuses WHERE name = ? AND version = ?",
            (corpus_name, corpus_version),
        ).fetchone()
        return [row["id"]] if row else []

    rows = conn.execute(
        "SELECT id FROM corpuses WHERE name = ?", (corpus_name,)
    ).fetchall()
    return [r["id"] for r in rows]


def _cosine_similarity(a, b_matrix):
    """
    Compute cosine similarity between vector `a` and each row of `b_matrix`.
    Returns a 1-D numpy array of scores.
    """
    a = np.array(a, dtype=np.float32)
    a_norm = np.linalg.norm(a)
    if a_norm == 0:
        return np.zeros(len(b_matrix))
    a = a / a_norm
    norms = np.linalg.norm(b_matrix, axis=1, keepdims=True)
    norms = np.where(norms == 0, 1.0, norms)
    b_normed = b_matrix / norms
    return b_normed @ a


def _load_embeddings_for_corpora(conn, corpus_ids: list[int]) -> Optional[dict]:
    """
    Load all embeddings for the given corpus IDs into a cache entry.
    Returns None if no embeddings exist or numpy is unavailable.
    """
    if not _HAS_NUMPY or not corpus_ids:
        return None

    cache_key = tuple(sorted(corpus_ids))
    if cache_key in _embedding_cache:
        return _embedding_cache[cache_key]

    placeholders = ",".join("?" * len(corpus_ids))
    rows = conn.execute(
        f"SELECT id, embedding FROM chunks WHERE corpus_id IN ({placeholders}) AND embedding IS NOT NULL",
        corpus_ids,
    ).fetchall()

    if not rows:
        return None

    ids = []
    vecs = []
    for r in rows:
        ids.append(r["id"])
        vecs.append(decode_embedding(r["embedding"]))

    matrix = np.array(vecs, dtype=np.float32)
    entry = {"ids": ids, "matrix": matrix}
    _embedding_cache[cache_key] = entry
    return entry


# ── MCP server setup ──────────────────────────────────────────────────────────

mcp = FastMCP(
    name="docs-reading",
    instructions=(
        "Search and browse technical documentation stored in a local SQLite database. "
        "Use search_docs for keyword or semantic queries. Use get_doc_outline to explore "
        "a file's structure before fetching full content. Use list_files and list_corpuses "
        "to discover what documentation is available."
    ),
)


# ── Tool: search_docs ─────────────────────────────────────────────────────────

@mcp.tool()
def search_docs(
    query: str,
    limit: int = 10,
    corpus_name: str = None,
    corpus_version: str = None,
) -> list[dict]:
    """
    Hybrid FTS5 + semantic search across parsed documentation.

    Combines BM25 full-text search with cosine similarity on sentence embeddings,
    deduplicates results, and re-ranks with a weighted blend (60% FTS, 40% semantic).
    Falls back to FTS-only if embeddings are unavailable.

    Args:
        query: Natural language or keyword search query.
        limit: Maximum number of results to return (default 10).
        corpus_name: Filter to a specific corpus (e.g. "godot"). If omitted, searches all.
        corpus_version: Further filter to a specific version (e.g. "4.6").

    Returns:
        List of dicts: {id, corpus_name, corpus_version, heading_path, content,
                        token_count, score, source_file}
    """
    name, version = _resolve_corpus_filter(corpus_name, corpus_version)
    conn = _conn()
    corpus_ids = _corpus_ids_for(conn, name, version)

    if not corpus_ids:
        return []

    # ── FTS5 search ───────────────────────────────────────────────────────────
    # Build a prefix-match FTS5 query joined with OR so that partial matches
    # still return results (e.g. "arguments" not in index won't kill the query).
    # Each token gets a trailing * so "CharacterBody" matches "CharacterBody2D".
    _FTS5_OPERATORS = {"AND", "OR", "NOT"}
    tokens = [
        t if t.endswith("*") or t in _FTS5_OPERATORS else t + "*"
        for t in query.split()
    ]
    fts_query = " OR ".join(tokens)

    placeholders = ",".join("?" * len(corpus_ids))
    fts_rows = conn.execute(
        f"""SELECT c.id, c.corpus_id, c.heading_path, c.content, c.content_plain,
                   c.token_count, c.file_id, c.embedding,
                   f.rel_path AS source_file,
                   cp.name AS corpus_name, cp.version AS corpus_version,
                   bm25(chunks_fts, 1, 10) AS fts_rank
            FROM chunks_fts
            JOIN chunks c ON c.id = chunks_fts.rowid
            JOIN files f ON f.id = c.file_id
            JOIN corpuses cp ON cp.id = c.corpus_id
            WHERE chunks_fts MATCH ?
              AND c.corpus_id IN ({placeholders})
            ORDER BY bm25(chunks_fts, 1, 10)
            LIMIT ?""",
        (fts_query, *corpus_ids, limit * 2),
    ).fetchall()

    # Normalise FTS ranks (rank is negative in FTS5; lower = better match)
    fts_scores: dict[int, float] = {}
    if fts_rows:
        ranks = [r["fts_rank"] for r in fts_rows]
        min_rank = min(ranks)
        max_rank = max(ranks)
        span = max_rank - min_rank if max_rank != min_rank else 1.0
        for r in fts_rows:
            # Map to [0,1] where 1 = best match
            fts_scores[r["id"]] = 1.0 - (r["fts_rank"] - min_rank) / span

    # Build result dict keyed by chunk id
    results: dict[int, dict] = {}
    for r in fts_rows:
        results[r["id"]] = {
            "id": r["id"],
            "corpus_name": r["corpus_name"],
            "corpus_version": r["corpus_version"],
            "heading_path": r["heading_path"],
            "content": r["content"],
            "token_count": r["token_count"],
            "source_file": r["source_file"],
            "score": fts_scores.get(r["id"], 0.0),
            "_embedding": r["embedding"],
        }

    # ── Semantic search (if numpy + embeddings available) ─────────────────────
    emb_cache = _load_embeddings_for_corpora(conn, corpus_ids)
    if emb_cache is not None:
        try:
            from embedder import embed_texts
            query_vec = embed_texts([query])[0]
        except Exception:
            query_vec = None

        if query_vec is not None:
            sims = _cosine_similarity(query_vec, emb_cache["matrix"])
            # Top-k by cosine similarity
            top_k_idx = sims.argsort()[::-1][: limit * 2]

            for idx in top_k_idx:
                chunk_id = emb_cache["ids"][idx]
                sim_score = float(sims[idx])
                if sim_score <= 0.0:
                    continue

                if chunk_id in results:
                    # Blend: 60% FTS + 40% semantic
                    fts_s = fts_scores.get(chunk_id, 0.0)
                    results[chunk_id]["score"] = 0.6 * fts_s + 0.4 * sim_score
                else:
                    # Fetch full row from DB
                    row = conn.execute(
                        """SELECT c.id, c.heading_path, c.content, c.token_count,
                                  f.rel_path AS source_file,
                                  cp.name AS corpus_name, cp.version AS corpus_version
                           FROM chunks c
                           JOIN files f ON f.id = c.file_id
                           JOIN corpuses cp ON cp.id = c.corpus_id
                           WHERE c.id = ?""",
                        (chunk_id,),
                    ).fetchone()
                    if row:
                        results[chunk_id] = {
                            "id": row["id"],
                            "corpus_name": row["corpus_name"],
                            "corpus_version": row["corpus_version"],
                            "heading_path": row["heading_path"],
                            "content": row["content"],
                            "token_count": row["token_count"],
                            "source_file": row["source_file"],
                            "score": 0.4 * sim_score,
                            "_embedding": None,
                        }

    # ── Rank, clean, and return ───────────────────────────────────────────────
    ranked = sorted(results.values(), key=lambda x: x["score"], reverse=True)[:limit]
    for r in ranked:
        r.pop("_embedding", None)

    return ranked


# ── Tool: get_chunk ───────────────────────────────────────────────────────────

@mcp.tool()
def get_chunk(chunk_id: int) -> dict:
    """
    Fetch the full content of a specific chunk by its integer ID.

    Returns a dict with: id, corpus_name, corpus_version, source_file,
    heading_path, heading_level, section_anchor, content, content_plain,
    token_count. Returns an empty dict if not found.
    """
    conn = _conn()
    row = conn.execute(
        """SELECT c.*, f.rel_path AS source_file,
                  cp.name AS corpus_name, cp.version AS corpus_version
           FROM chunks c
           JOIN files f ON f.id = c.file_id
           JOIN corpuses cp ON cp.id = c.corpus_id
           WHERE c.id = ?""",
        (chunk_id,),
    ).fetchone()

    if not row:
        return {}

    return {
        "id": row["id"],
        "corpus_name": row["corpus_name"],
        "corpus_version": row["corpus_version"],
        "source_file": row["source_file"],
        "heading_path": row["heading_path"],
        "heading_level": row["heading_level"],
        "section_anchor": row["section_anchor"],
        "content": row["content"],
        "content_plain": row["content_plain"],
        "token_count": row["token_count"],
    }


# ── Tool: get_doc_outline ─────────────────────────────────────────────────────

@mcp.tool()
def get_doc_outline(
    source_file: str,
    corpus_name: str = None,
    corpus_version: str = None,
) -> list[dict]:
    """
    Return the heading outline for a specific source file.

    Useful for understanding a file's structure before fetching full content.
    The source_file value should match the rel_path stored during parsing
    (e.g. "CharacterBody2D.xml" or "guide/installation.md").

    Args:
        source_file: Relative path of the file (as stored in the DB).
        corpus_name: Optional corpus filter.
        corpus_version: Optional version filter.

    Returns:
        List of {id, heading_path, heading_level, section_anchor, token_count},
        ordered as they appear in the document.
    """
    name, version = _resolve_corpus_filter(corpus_name, corpus_version)
    conn = _conn()
    corpus_ids = _corpus_ids_for(conn, name, version)

    if not corpus_ids:
        return []

    placeholders = ",".join("?" * len(corpus_ids))
    rows = conn.execute(
        f"""SELECT c.id, c.heading_path, c.heading_level, c.section_anchor, c.token_count
            FROM chunks c
            JOIN files f ON f.id = c.file_id
            WHERE f.rel_path = ?
              AND c.corpus_id IN ({placeholders})
            ORDER BY c.id""",
        (source_file, *corpus_ids),
    ).fetchall()

    return [
        {
            "id": r["id"],
            "heading_path": r["heading_path"],
            "heading_level": r["heading_level"],
            "section_anchor": r["section_anchor"],
            "token_count": r["token_count"],
        }
        for r in rows
    ]


# ── Tool: list_files ──────────────────────────────────────────────────────────

@mcp.tool()
def list_files(
    corpus_name: str = None,
    corpus_version: str = None,
) -> list[dict]:
    """
    List all parsed documentation files with metadata.

    Args:
        corpus_name: Optional filter to a specific corpus.
        corpus_version: Optional filter to a specific version.

    Returns:
        List of {corpus_name, corpus_version, rel_path, chunk_count, parsed_at}.
    """
    name, version = _resolve_corpus_filter(corpus_name, corpus_version)
    conn = _conn()
    corpus_ids = _corpus_ids_for(conn, name, version)

    if not corpus_ids:
        return []

    placeholders = ",".join("?" * len(corpus_ids))
    rows = conn.execute(
        f"""SELECT f.rel_path, f.chunk_count, f.parsed_at,
                   cp.name AS corpus_name, cp.version AS corpus_version
            FROM files f
            JOIN corpuses cp ON cp.id = f.corpus_id
            WHERE f.corpus_id IN ({placeholders})
            ORDER BY cp.name, cp.version, f.rel_path""",
        corpus_ids,
    ).fetchall()

    return [
        {
            "corpus_name": r["corpus_name"],
            "corpus_version": r["corpus_version"],
            "rel_path": r["rel_path"],
            "chunk_count": r["chunk_count"],
            "parsed_at": r["parsed_at"],
        }
        for r in rows
    ]


# ── Tool: list_corpuses ───────────────────────────────────────────────────────

@mcp.tool()
def list_corpuses() -> list[dict]:
    """
    List all documentation corpuses stored in the database.

    Returns:
        List of {name, version, file_count, chunk_count, created_at}.
    """
    conn = _conn()
    rows = conn.execute(
        """SELECT cp.id, cp.name, cp.version, cp.created_at,
                  (SELECT COUNT(*) FROM files f WHERE f.corpus_id = cp.id) AS file_count,
                  (SELECT COUNT(*) FROM chunks c WHERE c.corpus_id = cp.id) AS chunk_count
           FROM corpuses cp
           ORDER BY cp.name, cp.version"""
    ).fetchall()

    return [
        {
            "name": r["name"],
            "version": r["version"],
            "file_count": r["file_count"],
            "chunk_count": r["chunk_count"],
            "created_at": r["created_at"],
        }
        for r in rows
    ]


# ── Tool: get_related_chunks ──────────────────────────────────────────────────

@mcp.tool()
def get_related_chunks(chunk_id: int, limit: int = 5) -> list[dict]:
    """
    Find chunks semantically similar to a given chunk using embedding cosine similarity.

    Requires that embeddings were generated during (or after) parsing.
    Falls back to an empty list if embeddings are unavailable.

    Args:
        chunk_id: The ID of the reference chunk.
        limit: Number of similar chunks to return (default 5).

    Returns:
        Same shape as search_docs: {id, corpus_name, corpus_version, heading_path,
        content, token_count, source_file, score}.
    """
    if not _HAS_NUMPY:
        return []

    conn = _conn()

    # Fetch the reference chunk's embedding
    ref = conn.execute(
        "SELECT embedding, corpus_id FROM chunks WHERE id = ?", (chunk_id,)
    ).fetchone()

    if not ref or ref["embedding"] is None:
        return []

    ref_vec = decode_embedding(ref["embedding"])

    # Load embeddings for the same corpus
    corpus_ids = [ref["corpus_id"]]
    emb_cache = _load_embeddings_for_corpora(conn, corpus_ids)
    if emb_cache is None:
        return []

    sims = _cosine_similarity(ref_vec, emb_cache["matrix"])
    # Sort descending, skip the reference chunk itself
    top_idx = sims.argsort()[::-1]

    results = []
    for idx in top_idx:
        cid = emb_cache["ids"][idx]
        if cid == chunk_id:
            continue
        score = float(sims[idx])
        if score <= 0.0:
            break

        row = conn.execute(
            """SELECT c.id, c.heading_path, c.content, c.token_count,
                      f.rel_path AS source_file,
                      cp.name AS corpus_name, cp.version AS corpus_version
               FROM chunks c
               JOIN files f ON f.id = c.file_id
               JOIN corpuses cp ON cp.id = c.corpus_id
               WHERE c.id = ?""",
            (cid,),
        ).fetchone()

        if row:
            results.append({
                "id": row["id"],
                "corpus_name": row["corpus_name"],
                "corpus_version": row["corpus_version"],
                "heading_path": row["heading_path"],
                "content": row["content"],
                "token_count": row["token_count"],
                "source_file": row["source_file"],
                "score": score,
            })

        if len(results) >= limit:
            break

    return results


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(description="docs-reading MCP server")
    p.add_argument("--db",              default=None, help="Path to SQLite database (default: auto-detect from dbs/)")
    p.add_argument("--corpus-name",     default=None,  help="Default corpus to search (optional)")
    p.add_argument("--corpus-version",  default=None,  help="Default corpus version (optional)")
    args = p.parse_args()

    db_path = _resolve_db(args.db).resolve()
    if not db_path.exists():
        print(f"ERROR: Database not found: {db_path}")
        print("Parse some documentation first:")
        print("  python scripts/parse_docs.py --input /path/to/docs --db ./docs.db --corpus-name mylib --corpus-version 1.0")
        sys.exit(1)

    global _db_path, _default_corpus_name, _default_corpus_version
    _db_path = str(db_path)
    _default_corpus_name = args.corpus_name
    _default_corpus_version = args.corpus_version

    if not _HAS_NUMPY:
        print("WARNING: numpy not installed — semantic search disabled (FTS only).")
        print("  Install with: pip install numpy")

    corpus_info = ""
    if args.corpus_name:
        corpus_info = f" [{args.corpus_name}"
        if args.corpus_version:
            corpus_info += f" {args.corpus_version}"
        corpus_info += "]"

    print(f"docs-reading MCP server starting")
    print(f"  DB    : {db_path}")
    print(f"  Scope : {corpus_info or 'all corpuses'}")
    print(f"  Numpy : {'yes (hybrid search enabled)' if _HAS_NUMPY else 'no (FTS only)'}")

    mcp.run()


if __name__ == "__main__":
    main()

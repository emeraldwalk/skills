#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9,<3.14"
# dependencies = [
#   "numpy",
# ]
# ///
"""
docs.py — CLI for querying parsed documentation databases.

Commands:
    search   <query>          Hybrid FTS5 + semantic search
    chunk    <id>             Fetch a chunk by integer ID
    outline  <source_file>    Heading tree for a source file
    corpuses                  List all corpora
    files                     List all parsed files
    related  <id>             Semantically similar chunks

Output is compact JSON by default (optimized for agents).
Use --pretty for human-readable output.

Usage:
    uv run scripts/docs.py search "move_and_slide physics" --corpus godot --version 4.6
    uv run scripts/docs.py chunk 4821
    uv run scripts/docs.py outline "CharacterBody2D.xml" --corpus godot
    uv run scripts/docs.py corpuses
    uv run scripts/docs.py files --corpus godot
    uv run scripts/docs.py related 4821 --limit 5
"""

import argparse
import json
import sys
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).parent))

from db import get_connection, decode_embedding, list_corpuses as db_list_corpuses

_SKILL_DBS = Path(__file__).parent.parent / "dbs"


# ── Helpers ───────────────────────────────────────────────────────────────────

def _resolve_db(db_arg: Optional[str]) -> Path:
    if db_arg:
        return Path(db_arg)
    dbs = list(_SKILL_DBS.glob("*.db")) if _SKILL_DBS.exists() else []
    if len(dbs) == 1:
        return dbs[0]
    if len(dbs) > 1:
        names = "\n  ".join(str(d) for d in dbs)
        _die(f"Multiple databases found — specify one with --db:\n  {names}")
    _die(f"No database found in {_SKILL_DBS}. Parse some docs first.")


def _die(msg: str) -> None:
    print(json.dumps({"error": msg}), file=sys.stderr)
    sys.exit(1)


def _out(data, pretty: bool) -> None:
    if pretty:
        print(json.dumps(data, indent=2))
    else:
        print(json.dumps(data, separators=(",", ":")))


def _corpus_ids_for(conn, name: Optional[str], version: Optional[str]) -> list:
    if name is None:
        return [r["id"] for r in conn.execute("SELECT id FROM corpuses").fetchall()]
    if version is not None:
        row = conn.execute(
            "SELECT id FROM corpuses WHERE name = ? AND version = ?", (name, version)
        ).fetchone()
        return [row["id"]] if row else []
    return [
        r["id"]
        for r in conn.execute("SELECT id FROM corpuses WHERE name = ?", (name,)).fetchall()
    ]


# ── numpy / embedder (optional) ───────────────────────────────────────────────

try:
    import numpy as np
    _HAS_NUMPY = True
except ImportError:
    _HAS_NUMPY = False

_embedding_cache: dict = {}


def _cosine_similarity(a, b_matrix):
    a = np.array(a, dtype=np.float32)
    norm = np.linalg.norm(a)
    if norm == 0:
        return np.zeros(len(b_matrix))
    a = a / norm
    norms = np.linalg.norm(b_matrix, axis=1, keepdims=True)
    norms = np.where(norms == 0, 1.0, norms)
    return (b_matrix / norms) @ a


def _load_embeddings(conn, corpus_ids: list) -> Optional[dict]:
    if not _HAS_NUMPY or not corpus_ids:
        return None
    key = tuple(sorted(corpus_ids))
    if key in _embedding_cache:
        return _embedding_cache[key]
    placeholders = ",".join("?" * len(corpus_ids))
    rows = conn.execute(
        f"SELECT id, embedding FROM chunks WHERE corpus_id IN ({placeholders}) AND embedding IS NOT NULL",
        corpus_ids,
    ).fetchall()
    if not rows:
        return None
    ids, vecs = [], []
    for r in rows:
        ids.append(r["id"])
        vecs.append(decode_embedding(r["embedding"]))
    entry = {"ids": ids, "matrix": np.array(vecs, dtype=np.float32)}
    _embedding_cache[key] = entry
    return entry


# ── Commands ──────────────────────────────────────────────────────────────────

def cmd_search(conn, args) -> list:
    corpus_ids = _corpus_ids_for(conn, args.corpus, args.version)
    if not corpus_ids:
        return []

    # FTS5 — prefix-match each token so partial terms still hit
    _FTS5_OPS = {"AND", "OR", "NOT"}
    tokens = [t if t.endswith("*") or t in _FTS5_OPS else t + "*" for t in args.query.split()]
    fts_query = " OR ".join(tokens)
    placeholders = ",".join("?" * len(corpus_ids))

    fts_rows = conn.execute(
        f"""SELECT c.id, c.corpus_id, c.heading_path, c.content, c.content_plain,
                   c.token_count, c.embedding,
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
        (fts_query, *corpus_ids, args.limit * 2),
    ).fetchall()

    fts_scores: dict = {}
    if fts_rows:
        ranks = [r["fts_rank"] for r in fts_rows]
        lo, hi = min(ranks), max(ranks)
        span = hi - lo if hi != lo else 1.0
        for r in fts_rows:
            fts_scores[r["id"]] = 1.0 - (r["fts_rank"] - lo) / span

    results: dict = {}
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

    emb_cache = _load_embeddings(conn, corpus_ids)
    if emb_cache is not None:
        try:
            from embedder import embed_texts
            query_vec = embed_texts([args.query])[0]
        except Exception:
            query_vec = None

        if query_vec is not None:
            sims = _cosine_similarity(query_vec, emb_cache["matrix"])
            for idx in sims.argsort()[::-1][: args.limit * 2]:
                chunk_id = emb_cache["ids"][idx]
                sim = float(sims[idx])
                if sim <= 0.0:
                    continue
                if chunk_id in results:
                    results[chunk_id]["score"] = 0.6 * fts_scores.get(chunk_id, 0.0) + 0.4 * sim
                else:
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
                            "score": 0.4 * sim,
                            "_embedding": None,
                        }

    ranked = sorted(results.values(), key=lambda x: x["score"], reverse=True)[: args.limit]
    for r in ranked:
        r.pop("_embedding", None)
    return ranked


def cmd_chunk(conn, args) -> dict:
    row = conn.execute(
        """SELECT c.*, f.rel_path AS source_file,
                  cp.name AS corpus_name, cp.version AS corpus_version
           FROM chunks c
           JOIN files f ON f.id = c.file_id
           JOIN corpuses cp ON cp.id = c.corpus_id
           WHERE c.id = ?""",
        (args.id,),
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


def cmd_outline(conn, args) -> list:
    corpus_ids = _corpus_ids_for(conn, args.corpus, args.version)
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
        (args.source_file, *corpus_ids),
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


def cmd_corpuses(conn, args) -> list:
    rows = conn.execute(
        """SELECT cp.name, cp.version, cp.created_at,
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


def cmd_files(conn, args) -> list:
    corpus_ids = _corpus_ids_for(conn, args.corpus, args.version)
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


def cmd_related(conn, args) -> list:
    if not _HAS_NUMPY:
        _die("numpy is required for 'related' — install with: pip install numpy")

    ref = conn.execute(
        "SELECT embedding, corpus_id FROM chunks WHERE id = ?", (args.id,)
    ).fetchone()
    if not ref or ref["embedding"] is None:
        return []

    ref_vec = decode_embedding(ref["embedding"])
    emb_cache = _load_embeddings(conn, [ref["corpus_id"]])
    if emb_cache is None:
        return []

    sims = _cosine_similarity(ref_vec, emb_cache["matrix"])
    results = []
    for idx in sims.argsort()[::-1]:
        cid = emb_cache["ids"][idx]
        if cid == args.id:
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
        if len(results) >= args.limit:
            break
    return results


# ── Argument parser ───────────────────────────────────────────────────────────

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="docs.py",
        description="Query parsed documentation from a local SQLite database.",
    )
    p.add_argument("--db", default=None, help="Path to SQLite database (default: auto-detect from dbs/)")
    p.add_argument("--pretty", action="store_true", help="Pretty-print JSON output")

    sub = p.add_subparsers(dest="command", required=True)

    # search
    s = sub.add_parser("search", help="Hybrid FTS5 + semantic search")
    s.add_argument("query", help="Search query")
    s.add_argument("--corpus", default=None, help="Filter to corpus name")
    s.add_argument("--version", default=None, help="Filter to corpus version")
    s.add_argument("--limit", type=int, default=10, help="Max results (default: 10)")

    # chunk
    c = sub.add_parser("chunk", help="Fetch a chunk by ID")
    c.add_argument("id", type=int, help="Chunk ID")

    # outline
    o = sub.add_parser("outline", help="Heading tree for a source file")
    o.add_argument("source_file", help="Relative path as stored in DB (e.g. CharacterBody2D.xml)")
    o.add_argument("--corpus", default=None, help="Filter to corpus name")
    o.add_argument("--version", default=None, help="Filter to corpus version")

    # corpuses
    sub.add_parser("corpuses", help="List all corpora")

    # files
    f = sub.add_parser("files", help="List all parsed files")
    f.add_argument("--corpus", default=None, help="Filter to corpus name")
    f.add_argument("--version", default=None, help="Filter to corpus version")

    # related
    r = sub.add_parser("related", help="Semantically similar chunks (requires embeddings)")
    r.add_argument("id", type=int, help="Reference chunk ID")
    r.add_argument("--limit", type=int, default=5, help="Max results (default: 5)")

    return p


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    parser = build_parser()
    args = parser.parse_args()

    db_path = _resolve_db(args.db).resolve()
    if not db_path.exists():
        _die(
            f"Database not found: {db_path}\n"
            "Parse some documentation first:\n"
            "  uv run scripts/parse_docs.py --input /path/to/docs --db ./docs.db --corpus-name mylib --corpus-version 1.0"
        )

    conn = get_connection(str(db_path))

    dispatch = {
        "search":   cmd_search,
        "chunk":    cmd_chunk,
        "outline":  cmd_outline,
        "corpuses": cmd_corpuses,
        "files":    cmd_files,
        "related":  cmd_related,
    }

    result = dispatch[args.command](conn, args)
    _out(result, args.pretty)


if __name__ == "__main__":
    main()

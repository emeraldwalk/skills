#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9,<3.14"
# dependencies = [
#   "sentence-transformers",
#   "numpy",
# ]
# ///
"""
add_embeddings.py — Add or update embeddings for chunks that don't have them.

Useful when you did a fast initial parse with --no-embeddings, and want to
add semantic search capability without re-parsing.

Usage:
    python scripts/add_embeddings.py --db ./godot46.db
    python scripts/add_embeddings.py --db ./godot46.db --batch-size 128

    # Embed only a specific corpus
    python scripts/add_embeddings.py --db ./project.db --corpus-name react --corpus-version 18

    # Re-embed all chunks (including those already embedded)
    python scripts/add_embeddings.py --db ./docs.db --force
"""

import argparse
import math
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from db import get_connection, encode_embedding
from embedder import embed_texts

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
        names = "  \n".join(str(d) for d in dbs)
        print(f"ERROR: Multiple databases found — specify one with --db:\n  {names}")
        sys.exit(1)
    print(f"ERROR: No database found in {_SKILL_DBS}. Parse some docs first.")
    sys.exit(1)


def main():
    p = argparse.ArgumentParser(description="Add embeddings to parsed docs DB")
    p.add_argument("--db",              default=None, help="Path to SQLite database (default: auto-detect from dbs/)")
    p.add_argument("--batch-size",      type=int, default=64, help="Embedding batch size (default: 64)")
    p.add_argument("--force",           action="store_true", help="Re-embed all chunks, not just missing")
    p.add_argument("--corpus-name",     default=None, help="Limit to a specific corpus name")
    p.add_argument("--corpus-version",  default=None, help="Limit to a specific corpus version")
    args = p.parse_args()

    db_path = _resolve_db(args.db)
    if not db_path.exists():
        print(f"ERROR: Database not found: {db_path}")
        sys.exit(1)

    conn = get_connection(str(db_path))

    # Build corpus filter
    corpus_filter_sql = ""
    corpus_filter_params: list = []

    if args.corpus_name:
        # Resolve corpus_id(s) matching the name/version filter
        if args.corpus_version:
            row = conn.execute(
                "SELECT id FROM corpuses WHERE name = ? AND version = ?",
                (args.corpus_name, args.corpus_version),
            ).fetchone()
            corpus_ids = [row["id"]] if row else []
        else:
            rows = conn.execute(
                "SELECT id FROM corpuses WHERE name = ?", (args.corpus_name,)
            ).fetchall()
            corpus_ids = [r["id"] for r in rows]

        if not corpus_ids:
            scope = args.corpus_name
            if args.corpus_version:
                scope += f" {args.corpus_version}"
            print(f"ERROR: No corpus found matching '{scope}'")
            sys.exit(1)

        placeholders = ",".join("?" * len(corpus_ids))
        corpus_filter_sql = f" AND corpus_id IN ({placeholders})"
        corpus_filter_params = corpus_ids

    # Fetch chunks that need embedding
    if args.force:
        rows = conn.execute(
            f"SELECT id, content_plain FROM chunks WHERE 1=1{corpus_filter_sql}",
            corpus_filter_params,
        ).fetchall()
    else:
        rows = conn.execute(
            f"SELECT id, content_plain FROM chunks WHERE embedding IS NULL{corpus_filter_sql}",
            corpus_filter_params,
        ).fetchall()

    if not rows:
        print("All chunks already have embeddings.")
        return

    scope_desc = ""
    if args.corpus_name:
        scope_desc = f" in corpus '{args.corpus_name}"
        if args.corpus_version:
            scope_desc += f" {args.corpus_version}"
        scope_desc += "'"

    print(f"Embedding {len(rows)} chunks{scope_desc} (batch size {args.batch_size})...")
    print("(First run downloads ~80MB model)")
    print()

    start = time.time()
    texts = [r["content_plain"] for r in rows]
    ids = [r["id"] for r in rows]

    total_batches = math.ceil(len(texts) / args.batch_size)
    all_embeddings = []

    for i in range(0, len(texts), args.batch_size):
        batch_texts = texts[i : i + args.batch_size]
        batch_num = i // args.batch_size + 1
        print(f"  Batch {batch_num}/{total_batches} ({len(batch_texts)} chunks)...")
        embeddings = embed_texts(batch_texts)
        all_embeddings.extend(embeddings)

    # Bulk update
    print(f"\nWriting {len(all_embeddings)} embeddings to DB...")
    conn.executemany(
        "UPDATE chunks SET embedding = ? WHERE id = ?",
        [
            (encode_embedding(emb), chunk_id)
            for emb, chunk_id in zip(all_embeddings, ids)
        ],
    )
    conn.commit()

    elapsed = time.time() - start
    print(f"Done in {elapsed:.1f}s — {len(all_embeddings)} embeddings stored.")


if __name__ == "__main__":
    main()

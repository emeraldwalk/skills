#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9,<3.14"
# dependencies = []
# ///
"""
parse_docs.py — Generic heading-aware markdown parser for any documentation corpus.

Walks a directory tree, splits each markdown file into heading-aware chunks,
and stores them in a SQLite database with optional semantic embeddings.

Usage:
    python scripts/parse_docs.py \\
        --input /path/to/docs \\
        --db ./docs.db \\
        --corpus-name mylib \\
        --corpus-version 1.0

    # With all options:
    python scripts/parse_docs.py \\
        --input ./react-docs \\
        --db ./project.db \\
        --corpus-name react \\
        --corpus-version 18 \\
        --glob "**/*.md" \\
        --max-tokens 512 \\
        --min-tokens 50 \\
        --no-embeddings \\
        --force
"""

import argparse
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

_SKILL_DBS = Path(__file__).parent.parent / "dbs"

from db import (
    init_db,
    hash_file,
    get_file_record,
    get_or_create_corpus,
    upsert_file,
    delete_file_chunks,
    insert_chunks,
    update_file_chunk_count,
    list_all_files,
)

# ── Token counting ────────────────────────────────────────────────────────────

def approx_tokens(text: str) -> int:
    """Approximate token count: word count * 1.3."""
    return int(len(text.split()) * 1.3)


# ── Markdown stripping ────────────────────────────────────────────────────────

# Pre-compiled patterns for content_plain stripping
_RE_HEADING     = re.compile(r"^#{1,6}\s+", re.MULTILINE)
_RE_BOLD_ITALIC = re.compile(r"\*{1,3}([^*]+)\*{1,3}")
_RE_UNDER       = re.compile(r"_{1,3}([^_]+)_{1,3}")
_RE_CODE_BLOCK  = re.compile(r"```[^\n]*\n[\s\S]*?```", re.MULTILINE)
_RE_INLINE_CODE = re.compile(r"`([^`]+)`")
_RE_LINK        = re.compile(r"\[([^\]]+)\]\([^)]+\)")
_RE_IMAGE       = re.compile(r"!\[[^\]]*\]\([^)]+\)")
_RE_HTML_TAG    = re.compile(r"<[^>]+>")
_RE_MULTI_NL    = re.compile(r"\n{3,}")
_RE_BACKTICK    = re.compile(r"`+")


def strip_markdown(text: str) -> str:
    """
    Remove markdown formatting to produce plain text suitable for FTS/embeddings.

    Transformations:
      - Images            → (removed)
      - Links [t](url)    → t
      - Code fences       → (removed)
      - Inline code       → text only
      - Headings #        → text only
      - Bold/italic */_   → text only
      - HTML tags         → (removed)
      - Leftover backticks → (removed)
    """
    text = _RE_IMAGE.sub("", text)
    text = _RE_LINK.sub(r"\1", text)
    text = _RE_CODE_BLOCK.sub("", text)
    text = _RE_INLINE_CODE.sub(r"\1", text)
    text = _RE_HEADING.sub("", text)
    text = _RE_BOLD_ITALIC.sub(r"\1", text)
    text = _RE_UNDER.sub(r"\1", text)
    text = _RE_HTML_TAG.sub("", text)
    text = _RE_BACKTICK.sub("", text)
    text = _RE_MULTI_NL.sub("\n\n", text)
    return text.strip()


# ── Heading-aware chunker ─────────────────────────────────────────────────────

_HEADING_RE = re.compile(r"^(#{1,3})\s+(.+)", re.MULTILINE)


def _make_anchor(text: str) -> str:
    """GitHub-style heading anchor."""
    text = text.lower().strip()
    text = re.sub(r"[^\w\s-]", "", text)
    text = re.sub(r"\s+", "-", text)
    return "#" + text


def split_into_chunks(
    content: str,
    source_file: str,
    max_tokens: int = 512,
    min_tokens: int = 50,
) -> list:
    """
    Split a markdown document into heading-aware chunks.

    Strategy:
      1. Find all H1/H2/H3 headings and treat them as split points.
      2. Each chunk = heading text + body until next heading.
      3. Chunks exceeding max_tokens are split on paragraph boundaries.
      4. Chunks below min_tokens are merged with the next sibling.

    Returns a list of chunk dicts compatible with db.insert_chunks().
    """
    # Collect split positions: (line_start, heading_level, heading_text)
    splits = []
    for m in _HEADING_RE.finditer(content):
        level = len(m.group(1))
        title = m.group(2).strip()
        splits.append((m.start(), level, title))

    if not splits:
        # No headings — treat the whole file as one chunk
        plain = strip_markdown(content)
        return [{
            "source_file": source_file,
            "heading_path": source_file,
            "heading_level": 1,
            "section_anchor": _make_anchor(source_file),
            "content": content,
            "content_plain": plain,
            "token_count": approx_tokens(plain),
            "embedding": None,
        }]

    # Build raw sections: heading-path breadcrumb + body text
    sections = []
    breadcrumb: list[str] = []  # [h1_title, h2_title, h3_title] (may be shorter)

    for idx, (start, level, title) in enumerate(splits):
        end = splits[idx + 1][0] if idx + 1 < len(splits) else len(content)
        body = content[start:end]

        # Update breadcrumb
        # level 1 → index 0, level 2 → index 1, level 3 → index 2
        breadcrumb = breadcrumb[: level - 1] + [title]

        heading_path = " > ".join(breadcrumb)
        anchor = _make_anchor(title)

        sections.append({
            "source_file": source_file,
            "heading_path": heading_path,
            "heading_level": level,
            "section_anchor": anchor,
            "content": body.strip(),
            "content_plain": strip_markdown(body),
            "token_count": approx_tokens(strip_markdown(body)),
            "embedding": None,
        })

    # ── Split oversized sections on paragraph boundaries ──────────────────────
    expanded: list[dict] = []
    for sec in sections:
        if sec["token_count"] <= max_tokens:
            expanded.append(sec)
            continue

        # Split on double newlines (paragraphs)
        paragraphs = re.split(r"\n\n+", sec["content"])
        current_parts: list[str] = []
        current_tokens = 0
        part_index = 0

        for para in paragraphs:
            para_tokens = approx_tokens(strip_markdown(para))
            if current_parts and current_tokens + para_tokens > max_tokens:
                # Flush current accumulation
                chunk_content = "\n\n".join(current_parts)
                chunk_plain = strip_markdown(chunk_content)
                suffix = f" (part {part_index + 1})" if part_index > 0 else ""
                expanded.append({
                    **sec,
                    "heading_path": sec["heading_path"] + suffix,
                    "content": chunk_content,
                    "content_plain": chunk_plain,
                    "token_count": approx_tokens(chunk_plain),
                })
                part_index += 1
                current_parts = [para]
                current_tokens = para_tokens
            else:
                current_parts.append(para)
                current_tokens += para_tokens

        if current_parts:
            chunk_content = "\n\n".join(current_parts)
            chunk_plain = strip_markdown(chunk_content)
            suffix = f" (part {part_index + 1})" if part_index > 0 else ""
            expanded.append({
                **sec,
                "heading_path": sec["heading_path"] + suffix,
                "content": chunk_content,
                "content_plain": chunk_plain,
                "token_count": approx_tokens(chunk_plain),
            })

    # ── Merge undersized chunks with next sibling ─────────────────────────────
    merged: list[dict] = []
    i = 0
    while i < len(expanded):
        chunk = expanded[i]
        if chunk["token_count"] < min_tokens and i + 1 < len(expanded):
            nxt = expanded[i + 1]
            combined_content = chunk["content"] + "\n\n" + nxt["content"]
            combined_plain = strip_markdown(combined_content)
            merged.append({
                **chunk,
                "content": combined_content,
                "content_plain": combined_plain,
                "token_count": approx_tokens(combined_plain),
            })
            i += 2  # skip next (it was merged)
        else:
            merged.append(chunk)
            i += 1

    return merged


# ── File processing ───────────────────────────────────────────────────────────

def process_file(
    md_path: Path,
    rel_path: str,
    conn,
    corpus_id: int,
    generate_embeddings: bool,
    force: bool,
    max_tokens: int,
    min_tokens: int,
) -> tuple[str, int]:
    """Parse one markdown file. Returns (status, chunk_count)."""
    file_hash = hash_file(str(md_path))
    existing = get_file_record(conn, corpus_id, rel_path)

    if not force and existing and existing["file_hash"] == file_hash:
        return "skipped", existing["chunk_count"]

    try:
        content = md_path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise RuntimeError(f"Cannot read file: {exc}") from exc

    chunks = split_into_chunks(content, rel_path, max_tokens=max_tokens, min_tokens=min_tokens)
    if not chunks:
        return "empty", 0

    if generate_embeddings:
        from embedder import embed_texts
        plain_texts = [c["content_plain"] for c in chunks]
        embeddings = embed_texts(plain_texts)
        for chunk, emb in zip(chunks, embeddings):
            chunk["embedding"] = emb

    file_id = upsert_file(conn, corpus_id, rel_path, str(md_path), file_hash)
    delete_file_chunks(conn, file_id)
    insert_chunks(conn, file_id, corpus_id, chunks)
    update_file_chunk_count(conn, file_id)

    return "parsed", len(chunks)


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(
        description="Parse markdown documentation into a SQLite docs database"
    )
    p.add_argument("--input",           required=True, help="Root directory of documentation")
    p.add_argument("--db",              default=None, help="Path to output SQLite database (default: dbs/<corpus-name>.db)")
    p.add_argument("--corpus-name",     required=True, help="Corpus name (e.g. 'react', 'typescript')")
    p.add_argument("--corpus-version",  required=True, help="Corpus version (e.g. '18', '5.4')")
    p.add_argument("--glob",            default="**/*.md", help="File glob pattern (default: **/*.md)")
    p.add_argument("--max-tokens",      type=int, default=512, help="Max tokens per chunk (default: 512)")
    p.add_argument("--min-tokens",      type=int, default=50,  help="Min tokens to avoid merging (default: 50)")
    p.add_argument("--no-embeddings",   action="store_true", help="Skip embedding generation (fast mode)")
    p.add_argument("--force",           action="store_true", help="Re-parse all files even if unchanged")
    args = p.parse_args()

    input_dir = Path(args.input).resolve()
    if not input_dir.exists():
        print(f"ERROR: Input directory not found: {input_dir}")
        sys.exit(1)

    db_path = Path(args.db) if args.db else _SKILL_DBS / f"{args.corpus_name}.db"
    db_path.parent.mkdir(parents=True, exist_ok=True)

    md_files = sorted(input_dir.glob(args.glob))
    if not md_files:
        print(f"ERROR: No files matching '{args.glob}' found under {input_dir}")
        sys.exit(1)

    generate_embeddings = not args.no_embeddings

    print(f"docs-reading — Markdown parser")
    print(f"  Input  : {input_dir}")
    print(f"  DB     : {db_path}")
    print(f"  Corpus : {args.corpus_name} {args.corpus_version}")
    print(f"  Files  : {len(md_files)} files matching '{args.glob}'")
    print(f"  Tokens : max {args.max_tokens}, min {args.min_tokens}")
    print(f"  Embed  : {'no (fast mode)' if not generate_embeddings else 'yes — all-MiniLM-L6-v2'}")
    print(f"  Force  : {args.force}")
    print()

    conn = init_db(str(db_path))
    corpus_id = get_or_create_corpus(conn, args.corpus_name, args.corpus_version)

    stats = {"parsed": 0, "skipped": 0, "empty": 0, "error": 0, "total_chunks": 0}
    start = time.time()
    total = len(md_files)

    for i, md_path in enumerate(md_files, 1):
        try:
            rel_path = str(md_path.relative_to(input_dir))
        except ValueError:
            rel_path = md_path.name

        prefix = f"[{i:>4}/{total}]"

        try:
            status, chunk_count = process_file(
                md_path=md_path,
                rel_path=rel_path,
                conn=conn,
                corpus_id=corpus_id,
                generate_embeddings=generate_embeddings,
                force=args.force,
                max_tokens=args.max_tokens,
                min_tokens=args.min_tokens,
            )
        except Exception as exc:
            print(f"{prefix} ERROR   {rel_path}: {exc}")
            stats["error"] += 1
            continue

        stats[status] = stats.get(status, 0) + 1
        stats["total_chunks"] += chunk_count

        if status == "parsed":
            print(f"{prefix} Parsed  {rel_path:<50} {chunk_count:>4} chunks")
        elif status == "skipped":
            print(f"{prefix} Skipped {rel_path:<50} (unchanged)")
        elif status == "empty":
            print(f"{prefix} Empty   {rel_path:<50} (no chunks)")

    elapsed = time.time() - start
    print()
    print("=" * 60)
    print(f"Done in {elapsed:.1f}s")
    print(f"  Parsed : {stats['parsed']} files")
    print(f"  Skipped: {stats['skipped']} files (unchanged)")
    print(f"  Empty  : {stats.get('empty', 0)} files")
    print(f"  Errors : {stats['error']} files")
    print(f"  Chunks : {stats['total_chunks']} total")
    print(f"  DB     : {db_path}")
    print()
    print("Next steps:")
    if not generate_embeddings:
        print(f"  Add embeddings : python scripts/add_embeddings.py --db {db_path}")
    print(f"  Start server   : python scripts/mcp_server.py --db {db_path} "
          f"--corpus-name {args.corpus_name} --corpus-version {args.corpus_version}")


if __name__ == "__main__":
    main()

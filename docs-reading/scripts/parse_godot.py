#!/usr/bin/env python3
# /// script
# dependencies = [
#   "sentence-transformers",
#   "numpy",
# ]
# ///
"""
parse_godot.py — Parse Godot 4.x XML class reference docs into docs-mcp.

Targets the native XML format from godotengine/godot:
    godot/doc/classes/*.xml
    godot/modules/*/doc_classes/*.xml
    godot/platform/*/doc_classes/*.xml

Usage:
    # Clone the Godot repo first (shallow clone is fine):
    git clone --depth 1 --branch 4.6-stable https://github.com/godotengine/godot.git

    # Parse just the core classes
    python scripts/parse_godot.py --godot-repo ./godot --db ./godot46.db

    # Parse everything including modules
    python scripts/parse_godot.py --godot-repo ./godot --db ./godot46.db --all-modules

    # Parse with options
    python scripts/parse_godot.py \\
        --godot-repo ./godot \\
        --db ./godot46.db \\
        --corpus-name godot \\
        --corpus-version 4.6 \\
        --no-embeddings \\   # fast first pass, add embeddings later
        --force              # re-parse even if unchanged

After parsing, start the MCP server:
    python scripts/mcp_server.py --db ./godot46.db --corpus-name godot
"""

import argparse
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

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
from godot_xml_parser import parse_class_xml
from embedder import embed_texts


def _detect_godot_version(godot_repo: Path) -> str:
    """
    Try to detect the Godot version from the repo.

    Checks (in order):
      1. version.py in the repo root
      2. `git describe --tags` output
      3. Falls back to "unknown"
    """
    # 1. version.py
    version_py = godot_repo / "version.py"
    if version_py.exists():
        ns: dict = {}
        try:
            exec(version_py.read_text(encoding="utf-8"), ns)  # noqa: S102
            major = ns.get("major", "")
            minor = ns.get("minor", "")
            patch = ns.get("patch", "")
            status = ns.get("status", "")
            parts = [str(x) for x in [major, minor] if x != ""]
            version = ".".join(parts)
            if patch and str(patch) != "0":
                version += f".{patch}"
            if status and status not in ("stable", ""):
                version += f"-{status}"
            if version:
                return version
        except Exception:
            pass

    # 2. git describe
    try:
        tag = subprocess.check_output(
            ["git", "describe", "--tags", "--abbrev=0"],
            cwd=str(godot_repo),
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if tag:
            return tag
    except Exception:
        pass

    return "unknown"


def find_xml_files(godot_repo: Path, all_modules: bool) -> list[Path]:
    """
    Find all XML class reference files in a Godot repo.

    Core docs:     doc/classes/*.xml
    Module docs:   modules/*/doc_classes/*.xml
    Platform docs: platform/*/doc_classes/*.xml   (if --all-modules)
    Editor docs:   editor/doc_classes/*.xml        (if --all-modules)
    """
    files = []

    # Core class reference — always included
    core = godot_repo / "doc" / "classes"
    if core.exists():
        files.extend(sorted(core.glob("*.xml")))
    else:
        print(f"  WARNING: {core} not found — is this a Godot repo?")

    if all_modules:
        # Module docs
        for xml in sorted((godot_repo / "modules").glob("*/doc_classes/*.xml")):
            files.append(xml)
        # Platform docs
        for xml in sorted((godot_repo / "platform").glob("*/doc_classes/*.xml")):
            files.append(xml)
        # Editor docs
        for xml in sorted((godot_repo / "editor").glob("doc_classes/*.xml")):
            files.append(xml)

    return files


def process_file(
    xml_path: Path,
    rel_path: str,
    conn,
    corpus_id: int,
    generate_embeddings: bool,
    force: bool,
) -> tuple[str, int]:
    """Parse one XML file. Returns (status, chunk_count)."""
    file_hash = hash_file(str(xml_path))
    existing = get_file_record(conn, corpus_id, rel_path)

    if not force and existing and existing["file_hash"] == file_hash:
        return "skipped", existing["chunk_count"]

    chunks = parse_class_xml(xml_path)
    if not chunks:
        return "empty", 0

    if generate_embeddings:
        plain_texts = [c["content_plain"] for c in chunks]
        embeddings = embed_texts(plain_texts)
        for chunk, emb in zip(chunks, embeddings):
            chunk["embedding"] = emb

    file_id = upsert_file(conn, corpus_id, rel_path, str(xml_path), file_hash)
    delete_file_chunks(conn, file_id)
    insert_chunks(conn, file_id, corpus_id, chunks)
    update_file_chunk_count(conn, file_id)

    return "parsed", len(chunks)


def main():
    p = argparse.ArgumentParser(
        description="Parse Godot XML class reference docs into docs-mcp SQLite DB"
    )
    p.add_argument("--godot-repo",      required=True, help="Path to godotengine/godot repo root")
    p.add_argument("--db",              required=True, help="Path to output SQLite database")
    p.add_argument("--corpus-name",     default="godot", help="Corpus name (default: godot)")
    p.add_argument("--corpus-version",  default=None,
                   help="Corpus version (default: auto-detected from repo)")
    p.add_argument("--all-modules",     action="store_true",
                   help="Include module and platform docs")
    p.add_argument("--no-embeddings",   action="store_true",
                   help="Skip embedding generation (fast mode)")
    p.add_argument("--force",           action="store_true",
                   help="Re-parse all files even if unchanged")
    args = p.parse_args()

    godot_repo = Path(args.godot_repo).resolve()
    if not godot_repo.exists():
        print(f"ERROR: Godot repo not found: {godot_repo}")
        sys.exit(1)

    db_path = Path(args.db)
    db_path.parent.mkdir(parents=True, exist_ok=True)

    # Auto-detect version if not provided
    corpus_version = args.corpus_version or _detect_godot_version(godot_repo)

    xml_files = find_xml_files(godot_repo, args.all_modules)
    if not xml_files:
        print(f"ERROR: No XML class files found in {godot_repo}")
        print("Make sure you're pointing at a Godot engine repo (not godot-docs).")
        sys.exit(1)

    generate_embeddings = not args.no_embeddings

    print(f"docs-reading — Godot XML parser")
    print(f"  Repo   : {godot_repo}")
    print(f"  DB     : {db_path}")
    print(f"  Corpus : {args.corpus_name} {corpus_version}")
    print(f"  Files  : {len(xml_files)} XML class files")
    print(f"  Embed  : {'no (fast mode)' if not generate_embeddings else 'yes — all-MiniLM-L6-v2'}")
    print(f"  Force  : {args.force}")
    print()

    conn = init_db(str(db_path))
    corpus_id = get_or_create_corpus(conn, args.corpus_name, corpus_version)

    stats = {"parsed": 0, "skipped": 0, "empty": 0, "error": 0, "total_chunks": 0}
    start = time.time()

    for i, xml_path in enumerate(xml_files, 1):
        # Store relative to repo root for clean paths
        try:
            rel_path = str(xml_path.relative_to(godot_repo))
        except ValueError:
            rel_path = xml_path.name

        prefix = f"[{i:>4}/{len(xml_files)}]"

        try:
            status, chunk_count = process_file(
                xml_path=xml_path,
                rel_path=rel_path,
                conn=conn,
                corpus_id=corpus_id,
                generate_embeddings=generate_embeddings,
                force=args.force,
            )
        except Exception as e:
            print(f"{prefix} ERROR   {rel_path}: {e}")
            stats["error"] += 1
            continue

        stats[status] = stats.get(status, 0) + 1
        stats["total_chunks"] += chunk_count

        if status == "parsed":
            print(f"{prefix} Parsed  {xml_path.stem:<40} {chunk_count:>4} chunks")
        elif status == "skipped":
            print(f"{prefix} Skipped {xml_path.stem:<40} (unchanged)")
        elif status == "empty":
            print(f"{prefix} Empty   {xml_path.stem:<40} (no chunks)")

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
          f"--corpus-name {args.corpus_name} --corpus-version {corpus_version}")


if __name__ == "__main__":
    main()

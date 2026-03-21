#!/usr/bin/env python3
"""
db.py — SQLite schema and helpers for the docs-reading skill.

Supports multiple documentation corpora (e.g. "godot", "react") and
multiple versions of each, all in a single database file.

Schema overview:
  corpuses  — one row per (name, version) pair
  files     — one row per parsed source file, linked to a corpus
  chunks    — one row per document chunk, linked to file + corpus
  chunks_fts — FTS5 virtual table over chunks (content_fts style)
"""

import hashlib
import sqlite3
import struct
from pathlib import Path
from typing import Optional


# ── Connection helpers ────────────────────────────────────────────────────────

def get_connection(db_path: str, readonly: bool = False) -> sqlite3.Connection:
    """Open a connection with Row factory.

    Pass readonly=True to open in immutable read-only mode (no WAL files
    created, works on read-only filesystems).
    """
    if readonly:
        uri = f"file:{db_path}?mode=ro&immutable=1"
        conn = sqlite3.connect(uri, uri=True)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys=ON")
    else:
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute("PRAGMA synchronous=NORMAL")
    return conn


def init_db(db_path: str) -> sqlite3.Connection:
    """Create the schema (if not exists) and return an open connection."""
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    conn = get_connection(db_path)

    conn.executescript("""
        -- ── Corpus registry ──────────────────────────────────────────────────
        CREATE TABLE IF NOT EXISTS corpuses (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            name       TEXT    NOT NULL,
            version    TEXT    NOT NULL DEFAULT '',
            created_at TEXT    NOT NULL DEFAULT (datetime('now'))
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_corpus_name_version
            ON corpuses (name, version);

        -- ── Parsed source files ───────────────────────────────────────────────
        CREATE TABLE IF NOT EXISTS files (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            corpus_id   INTEGER NOT NULL REFERENCES corpuses(id) ON DELETE CASCADE,
            rel_path    TEXT    NOT NULL,
            abs_path    TEXT    NOT NULL,
            file_hash   TEXT    NOT NULL,
            chunk_count INTEGER NOT NULL DEFAULT 0,
            parsed_at   TEXT    NOT NULL DEFAULT (datetime('now'))
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_file_corpus_rel
            ON files (corpus_id, rel_path);
        CREATE INDEX IF NOT EXISTS idx_file_corpus
            ON files (corpus_id);

        -- ── Document chunks ───────────────────────────────────────────────────
        CREATE TABLE IF NOT EXISTS chunks (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id         INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            corpus_id       INTEGER NOT NULL REFERENCES corpuses(id) ON DELETE CASCADE,
            heading_path    TEXT    NOT NULL DEFAULT '',
            heading_level   INTEGER NOT NULL DEFAULT 1,
            section_anchor  TEXT    NOT NULL DEFAULT '',
            content         TEXT    NOT NULL DEFAULT '',
            content_plain   TEXT    NOT NULL DEFAULT '',
            token_count     INTEGER NOT NULL DEFAULT 0,
            embedding       BLOB
        );
        CREATE INDEX IF NOT EXISTS idx_chunk_file
            ON chunks (file_id);
        CREATE INDEX IF NOT EXISTS idx_chunk_corpus
            ON chunks (corpus_id);

        -- ── FTS5 virtual table (content-based, pointing at chunks) ────────────
        -- content='' means it's an "external content" FTS table; we manage sync
        -- ourselves with a full rebuild after bulk inserts.
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
            content_plain,
            heading_path,
            content='chunks',
            content_rowid='id',
            tokenize='unicode61'
        );
    """)
    conn.commit()
    return conn


# ── File hashing ──────────────────────────────────────────────────────────────

def hash_file(path: str) -> str:
    """Return the SHA-256 hex digest of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(65536), b""):
            h.update(block)
    return h.hexdigest()


# ── Corpus helpers ────────────────────────────────────────────────────────────

def get_or_create_corpus(conn: sqlite3.Connection, name: str, version: str) -> int:
    """Return the corpus_id for (name, version), creating it if needed."""
    row = conn.execute(
        "SELECT id FROM corpuses WHERE name = ? AND version = ?", (name, version)
    ).fetchone()
    if row:
        return row["id"]
    cur = conn.execute(
        "INSERT INTO corpuses (name, version) VALUES (?, ?)", (name, version)
    )
    conn.commit()
    return cur.lastrowid


def list_corpuses(conn: sqlite3.Connection) -> list:
    """Return all corpus rows."""
    return conn.execute("SELECT * FROM corpuses ORDER BY name, version").fetchall()


# ── File record helpers ───────────────────────────────────────────────────────

def get_file_record(conn: sqlite3.Connection, corpus_id: int, rel_path: str) -> Optional[sqlite3.Row]:
    """Return the file row for (corpus_id, rel_path), or None."""
    return conn.execute(
        "SELECT * FROM files WHERE corpus_id = ? AND rel_path = ?",
        (corpus_id, rel_path),
    ).fetchone()


def upsert_file(
    conn: sqlite3.Connection,
    corpus_id: int,
    rel_path: str,
    abs_path: str,
    file_hash: str,
) -> int:
    """Insert or update a file record, returning its id."""
    existing = get_file_record(conn, corpus_id, rel_path)
    if existing:
        conn.execute(
            """UPDATE files
               SET abs_path = ?, file_hash = ?, parsed_at = datetime('now')
               WHERE id = ?""",
            (abs_path, file_hash, existing["id"]),
        )
        conn.commit()
        return existing["id"]
    cur = conn.execute(
        "INSERT INTO files (corpus_id, rel_path, abs_path, file_hash) VALUES (?, ?, ?, ?)",
        (corpus_id, rel_path, abs_path, file_hash),
    )
    conn.commit()
    return cur.lastrowid


def delete_file_chunks(conn: sqlite3.Connection, file_id: int) -> None:
    """Delete all chunks belonging to a file (before re-parsing)."""
    conn.execute("DELETE FROM chunks WHERE file_id = ?", (file_id,))
    conn.commit()


def update_file_chunk_count(conn: sqlite3.Connection, file_id: int) -> None:
    """Recompute and store the chunk_count for a file."""
    count = conn.execute(
        "SELECT COUNT(*) FROM chunks WHERE file_id = ?", (file_id,)
    ).fetchone()[0]
    conn.execute(
        "UPDATE files SET chunk_count = ? WHERE id = ?", (count, file_id)
    )
    conn.commit()


def list_all_files(conn: sqlite3.Connection, corpus_id: int = None) -> list:
    """Return all file rows, optionally filtered by corpus_id."""
    if corpus_id is not None:
        return conn.execute(
            "SELECT f.*, c.name AS corpus_name, c.version AS corpus_version "
            "FROM files f JOIN corpuses c ON c.id = f.corpus_id "
            "WHERE f.corpus_id = ? ORDER BY f.rel_path",
            (corpus_id,),
        ).fetchall()
    return conn.execute(
        "SELECT f.*, c.name AS corpus_name, c.version AS corpus_version "
        "FROM files f JOIN corpuses c ON c.id = f.corpus_id "
        "ORDER BY c.name, c.version, f.rel_path"
    ).fetchall()


# ── Embedding encode/decode ───────────────────────────────────────────────────

def encode_embedding(vec: list) -> bytes:
    """Pack a list of floats into a compact binary blob (little-endian float32)."""
    return struct.pack(f"<{len(vec)}f", *vec)


def decode_embedding(blob: bytes) -> list:
    """Unpack a binary blob into a list of Python floats."""
    n = len(blob) // 4
    return list(struct.unpack(f"<{n}f", blob))


# ── Chunk insertion ───────────────────────────────────────────────────────────

def insert_chunks(
    conn: sqlite3.Connection,
    file_id: int,
    corpus_id: int,
    chunks: list,
) -> None:
    """
    Insert a list of chunk dicts for a file.

    Each dict must contain:
        source_file, heading_path, heading_level, section_anchor,
        content, content_plain, token_count, embedding (None or list[float])

    After all chunks are inserted the FTS index is rebuilt in full so that
    the new rows become searchable immediately.
    """
    rows = []
    for c in chunks:
        emb_blob = None
        if c.get("embedding") is not None:
            emb_blob = encode_embedding(c["embedding"])
        rows.append((
            file_id,
            corpus_id,
            c.get("heading_path", ""),
            c.get("heading_level", 1),
            c.get("section_anchor", ""),
            c.get("content", ""),
            c.get("content_plain", ""),
            c.get("token_count", 0),
            emb_blob,
        ))

    conn.executemany(
        """INSERT INTO chunks
               (file_id, corpus_id, heading_path, heading_level, section_anchor,
                content, content_plain, token_count, embedding)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        rows,
    )

    # Rebuild the FTS index to include newly inserted rows.
    # This is a full rebuild of the external-content FTS table; it reads the
    # current state of the `chunks` table.  For incremental parsing workloads
    # this is called once per file which is acceptable; callers that batch many
    # files can call _rebuild_fts() manually after all files are done and skip
    # per-file rebuilds by passing rebuild_fts=False (not exposed in the public
    # API to keep the interface simple — a full rebuild at the end of parse_*
    # scripts is sufficient).
    conn.execute("INSERT INTO chunks_fts(chunks_fts) VALUES('rebuild')")
    conn.commit()


def rebuild_fts(conn: sqlite3.Connection) -> None:
    """Force a full rebuild of the FTS index. Call after bulk operations."""
    conn.execute("INSERT INTO chunks_fts(chunks_fts) VALUES('rebuild')")
    conn.commit()

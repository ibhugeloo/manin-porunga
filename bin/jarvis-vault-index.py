#!/usr/bin/env python3
"""
jarvis-vault-index — Indexe le vault Obsidian + sessions Jarvis dans une DB sqlite-vec.

Sources scannées :
- ~/Documents/Obsidian/vault/                 (vault Obsidian complet, hors .obsidian)
- ~/Documents/Obsidian/vault/Claude/Sessions/ (récaps de sessions Jarvis)
- ~/Documents/GIT PROD/manin-porunga/   (lessons.md, notes synthèse)

Output : ~/.local/share/jarvis/vault.db (sqlite-vec, ~10-50 MB selon volume)

Usage :
    jarvis-vault-index.py                 # incrémental (basé sur mtime)
    jarvis-vault-index.py --full          # full reindex (purge + recréation)
    jarvis-vault-index.py --stats         # affiche le contenu de la DB
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
import time
from datetime import datetime
from pathlib import Path

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

HOME = Path.home()
VAULT = HOME / "Documents" / "Obsidian" / "vault"
JARVIS_REPO = HOME / "Documents" / "GIT PROD" / "manin-porunga"
DB_PATH = HOME / ".local" / "share" / "jarvis" / "vault.db"
LOG_PATH = HOME / ".local" / "var" / "log" / "jarvis-vault-index.log"

# Telegram history → converti en .md indexable avant le scan
TELEGRAM_HISTORY = HOME / ".local" / "share" / "jarvis" / "telegram-history.jsonl"
TELEGRAM_DIR = HOME / ".local" / "share" / "jarvis" / "telegram-export"
TELEGRAM_INDEXABLE = TELEGRAM_DIR / "telegram-conversations.md"

# Sources à indexer (chemin, source_label)
# On indexe le vault complet (qui contient déjà Memory/, Sessions/, Projects/) +
# le repo Jarvis pour lessons.md / README / prompts (sans dédoublonner les mirrors) +
# l'historique Telegram converti en .md (cf. sync_telegram_md).
SOURCES = [
    (VAULT, "vault"),
    (JARVIS_REPO, "jarvis-repo-docs"),
    (TELEGRAM_DIR, "telegram"),
]

# Patterns à exclure (segments de path)
EXCLUDE_PATTERNS = [
    ".obsidian", ".trash", ".git", "node_modules", ".venv", "venv",
    ".DS_Store", ".playwright-mcp",
    "Brief",                # briefs s'auto-régénèrent quotidiennement, bruit
    # Dans le repo Jarvis, ces dossiers sont des mirrors du vault → doublons
    "memory", "sessions", "obsidian-projects",
]

# Cap de taille des chunks (caractères)
CHUNK_TARGET_CHARS = 600
CHUNK_MAX_CHARS = 1500

# Modèle d'embedding : multilingual-e5-small (384 dims, FR/EN/etc., 470MB)
MODEL_NAME = "intfloat/multilingual-e5-small"
EMBEDDING_DIM = 384


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------


def log(msg: str) -> None:
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    line = f"[{datetime.now().isoformat(timespec='seconds')}] {msg}"
    print(line)
    with open(LOG_PATH, "a") as f:
        f.write(line + "\n")


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------


def open_db() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(str(DB_PATH))
    db.enable_load_extension(True)
    import sqlite_vec
    sqlite_vec.load(db)
    db.enable_load_extension(False)
    return db


def init_schema(db: sqlite3.Connection) -> None:
    db.executescript(f"""
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT UNIQUE NOT NULL,
            source TEXT NOT NULL,
            modified_at INTEGER NOT NULL,
            hash TEXT NOT NULL,
            indexed_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            chunk_index INTEGER NOT NULL,
            text TEXT NOT NULL,
            UNIQUE(file_id, chunk_index)
        );

        CREATE INDEX IF NOT EXISTS idx_chunks_file ON chunks(file_id);

        CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(
            chunk_id INTEGER PRIMARY KEY,
            embedding FLOAT[{EMBEDDING_DIM}]
        );
    """)
    db.commit()


def db_stats(db: sqlite3.Connection) -> dict:
    files_count = db.execute("SELECT COUNT(*) FROM files").fetchone()[0]
    chunks_count = db.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
    by_source = dict(db.execute("SELECT source, COUNT(*) FROM files GROUP BY source").fetchall())
    db_size_mb = DB_PATH.stat().st_size / (1024 * 1024) if DB_PATH.exists() else 0
    return {
        "files": files_count,
        "chunks": chunks_count,
        "by_source": by_source,
        "db_size_mb": round(db_size_mb, 2),
    }


# ---------------------------------------------------------------------------
# Chunking
# ---------------------------------------------------------------------------


def chunk_markdown(text: str) -> list[str]:
    """Split par paragraphe (\n\n), avec cap dur sur la longueur."""
    # Strip frontmatter YAML
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end > 0:
            text = text[end + 4:]

    paragraphs = re.split(r"\n\s*\n", text)
    chunks: list[str] = []
    current = ""

    for p in paragraphs:
        p = p.strip()
        if not p or len(p) < 20:  # skip lignes trop courtes (bullets isolés)
            continue
        # Si le paragraphe seul dépasse le max → split par phrase
        if len(p) > CHUNK_MAX_CHARS:
            for sentence in re.split(r"(?<=[.!?])\s+", p):
                if len(current) + len(sentence) > CHUNK_TARGET_CHARS:
                    if current:
                        chunks.append(current.strip())
                    current = sentence
                else:
                    current = current + " " + sentence if current else sentence
            continue
        # Sinon, agrège jusqu'à approcher la cible
        if len(current) + len(p) + 2 > CHUNK_TARGET_CHARS and current:
            chunks.append(current.strip())
            current = p
        else:
            current = current + "\n\n" + p if current else p

    if current.strip():
        chunks.append(current.strip())

    return [c for c in chunks if len(c) >= 20]


# ---------------------------------------------------------------------------
# Walking files
# ---------------------------------------------------------------------------


def is_excluded(path: Path) -> bool:
    parts = path.parts
    for ex in EXCLUDE_PATTERNS:
        if ex in parts:
            return True
    return False


def walk_markdown_files(root: Path):
    if not root.exists():
        return
    for p in root.rglob("*.md"):
        if is_excluded(p):
            continue
        if p.is_file():
            yield p


def file_hash(path: Path) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Embedding
# ---------------------------------------------------------------------------


def load_model():
    """Charge le modèle (lazy car ~470MB et 5-10s de chargement)."""
    log(f"Loading embedding model: {MODEL_NAME}")
    from sentence_transformers import SentenceTransformer
    model = SentenceTransformer(MODEL_NAME)
    log(f"Model loaded ({EMBEDDING_DIM} dims)")
    return model


def embed_chunks(model, chunks: list[str]) -> list[list[float]]:
    """e5 attend le préfixe 'passage:' pour les documents."""
    prefixed = [f"passage: {c}" for c in chunks]
    vectors = model.encode(prefixed, batch_size=32, show_progress_bar=False, normalize_embeddings=True)
    return vectors.tolist()


# ---------------------------------------------------------------------------
# Indexing
# ---------------------------------------------------------------------------


def reindex_file(db: sqlite3.Connection, model, source: str, path: Path) -> tuple[int, int]:
    """Réindexe un fichier (delete + insert). Retourne (chunks_count, success_int)."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        log(f"  SKIP {path}: {e}")
        return (0, 0)

    chunks = chunk_markdown(text)
    if not chunks:
        return (0, 1)  # Fichier valide mais aucun chunk pertinent

    # Embedding (synchrone)
    vectors = embed_chunks(model, chunks)

    # Update DB en transaction
    h = file_hash(path)
    mtime = int(path.stat().st_mtime)

    cur = db.cursor()

    # Delete previous file + chunks (CASCADE)
    cur.execute("DELETE FROM files WHERE path = ?", (str(path),))

    # Insert file
    cur.execute(
        "INSERT INTO files (path, source, modified_at, hash, indexed_at) VALUES (?, ?, ?, ?, ?)",
        (str(path), source, mtime, h, int(time.time())),
    )
    file_id = cur.lastrowid

    # Insert chunks + embeddings
    for idx, (chunk, vec) in enumerate(zip(chunks, vectors)):
        cur.execute(
            "INSERT INTO chunks (file_id, chunk_index, text) VALUES (?, ?, ?)",
            (file_id, idx, chunk),
        )
        chunk_id = cur.lastrowid
        # Sérialiser le vecteur pour vec0 (sqlite-vec accepte bytes ou JSON array)
        cur.execute(
            "INSERT INTO vec_chunks (chunk_id, embedding) VALUES (?, ?)",
            (chunk_id, json.dumps(vec)),
        )

    db.commit()
    return (len(chunks), 1)


def needs_reindex(db: sqlite3.Connection, path: Path) -> bool:
    """Décide s'il faut réindexer ce fichier (mtime ou hash a changé)."""
    row = db.execute("SELECT modified_at, hash FROM files WHERE path = ?", (str(path),)).fetchone()
    if not row:
        return True
    db_mtime, db_hash = row
    fs_mtime = int(path.stat().st_mtime)
    if fs_mtime > db_mtime:
        # mtime plus récent → vérifier le hash pour éviter de réindexer un touch
        if file_hash(path) != db_hash:
            return True
    return False


def cleanup_deleted(db: sqlite3.Connection, current_paths: set[str]) -> int:
    """Supprime les fichiers indexés qui n'existent plus dans le filesystem."""
    rows = db.execute("SELECT id, path FROM files").fetchall()
    deleted = 0
    for fid, fpath in rows:
        if fpath not in current_paths:
            db.execute("DELETE FROM files WHERE id = ?", (fid,))
            deleted += 1
    if deleted:
        db.commit()
    return deleted


def sync_telegram_md() -> int:
    """Convertit telegram-history.jsonl en .md indexable. Retourne le nombre de turns convertis."""
    if not TELEGRAM_HISTORY.exists():
        return 0

    TELEGRAM_DIR.mkdir(parents=True, exist_ok=True)

    try:
        lines = [l for l in TELEGRAM_HISTORY.read_text(encoding="utf-8").splitlines() if l.strip()]
    except Exception as e:
        log(f"Failed to read telegram-history: {e}")
        return 0

    if not lines:
        return 0

    # Parser les turns
    turns = []
    for line in lines:
        try:
            t = json.loads(line)
            turns.append(t)
        except Exception:
            continue

    # Grouper par échange (user message + assistant response consécutifs)
    out = ["# Telegram conversations\n"]
    out.append(f"_Source : {TELEGRAM_HISTORY}, sync : {datetime.now().isoformat(timespec='seconds')}_\n\n")

    current_exchange: list[dict] = []
    last_date: str | None = None

    def flush_exchange():
        nonlocal current_exchange
        if not current_exchange:
            return
        # Heading par exchange : datetime du premier message
        first_ts = current_exchange[0].get("ts", "")
        try:
            dt_label = datetime.fromisoformat(first_ts).strftime("%Y-%m-%d %H:%M")
        except Exception:
            dt_label = first_ts
        out.append(f"## Échange {dt_label}\n\n")
        for t in current_exchange:
            role = "**Vous**" if t.get("role") == "user" else "**Jarvis**"
            content = (t.get("content") or "").strip()
            out.append(f"{role} : {content}\n\n")
        out.append("---\n\n")
        current_exchange = []

    for t in turns:
        # Nouvelle exchange si: rôle "user" ET il y a déjà un assistant dans le current
        if t.get("role") == "user" and any(x.get("role") == "assistant" for x in current_exchange):
            flush_exchange()
        current_exchange.append(t)

    flush_exchange()

    TELEGRAM_INDEXABLE.write_text("".join(out), encoding="utf-8")
    log(f"Telegram → .md : {len(turns)} turns dans {TELEGRAM_INDEXABLE}")
    return len(turns)


def run_index(full: bool = False) -> None:
    db = open_db()
    init_schema(db)

    # Préprocess : sync telegram-history → .md indexable
    try:
        sync_telegram_md()
    except Exception as e:
        log(f"sync_telegram_md failed (non-bloquant): {e}")

    if full:
        log("FULL reindex requested — purge")
        db.executescript("DELETE FROM vec_chunks; DELETE FROM chunks; DELETE FROM files;")
        db.commit()

    # Étape 1 : collecter tous les fichiers à considérer
    log("Scanning sources...")
    candidates: list[tuple[str, Path]] = []
    for root, source_label in SOURCES:
        for path in walk_markdown_files(root):
            candidates.append((source_label, path))

    log(f"Found {len(candidates)} markdown files across {len(SOURCES)} sources")

    # Étape 2 : ne charger le modèle que s'il y a du travail
    todo = []
    for source, path in candidates:
        if full or needs_reindex(db, path):
            todo.append((source, path))

    if not todo:
        # Rien à faire — juste cleanup
        deleted = cleanup_deleted(db, {str(p) for _, p in candidates})
        log(f"Up to date. {deleted} stale entries cleaned.")
        log(f"Stats: {json.dumps(db_stats(db), ensure_ascii=False)}")
        return

    log(f"To (re)index: {len(todo)} files")
    model = load_model()

    total_chunks = 0
    total_files = 0
    for i, (source, path) in enumerate(todo, 1):
        chunks_count, ok = reindex_file(db, model, source, path)
        total_chunks += chunks_count
        total_files += ok
        if i % 25 == 0 or i == len(todo):
            log(f"  [{i}/{len(todo)}] {path.relative_to(HOME)} → {chunks_count} chunks")

    # Cleanup fichiers supprimés
    deleted = cleanup_deleted(db, {str(p) for _, p in candidates})

    log(f"Done. {total_files} files indexed, {total_chunks} chunks added, {deleted} stale entries removed.")
    log(f"Stats: {json.dumps(db_stats(db), ensure_ascii=False)}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> int:
    p = argparse.ArgumentParser(description="Indexe le vault dans sqlite-vec")
    p.add_argument("--full", action="store_true", help="Full reindex (purge + recréation)")
    p.add_argument("--stats", action="store_true", help="Affiche les stats de la DB et sort")
    args = p.parse_args()

    if args.stats:
        if not DB_PATH.exists():
            print("DB n'existe pas encore — lancez sans --stats pour indexer.")
            return 1
        db = open_db()
        init_schema(db)
        print(json.dumps(db_stats(db), ensure_ascii=False, indent=2))
        return 0

    started = time.time()
    try:
        run_index(full=args.full)
    except KeyboardInterrupt:
        log("Interrupted by user")
        return 130
    elapsed = time.time() - started
    log(f"Total: {elapsed:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())

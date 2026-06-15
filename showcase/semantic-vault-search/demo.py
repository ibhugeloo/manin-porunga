#!/usr/bin/env python3
"""
demo.py — Standalone, runnable demo of the semantic vault search pipeline.

This is a portfolio showcase. It demonstrates the *same* retrieval pipeline that
powers the production CLI (`bin/vault-search-v2.py` + `bin/jarvis-vault-index.py`)
on a tiny, public sample corpus shipped alongside this file — so a reader can run
it WITHOUT access to the owner's private Obsidian vault.

It does NOT fork the production code. It imports the real chunking and embedding
logic from the production files by path (see `_load_production_module`), then runs
the same flow end to end:

    markdown files
        -> chunk_markdown()            (production chunker)
        -> embed "passage: <chunk>"    (production e5 prefix convention)
        -> sqlite-vec vec0 table       (same vector store as production)
        -> embed "query: <question>"   (production query prefix)
        -> cosine top-K                (same MATCH ... k = ? query shape)

What this demo adds on top of the raw retrieval, to answer the questions a
senior reviewer actually asks:

  1. GROUNDING / CITATIONS — every answer says WHICH file, WHICH chunk index,
     and the similarity score it came from. That is the audit trail a RAG layer
     needs so an LLM (and a human) can verify the answer against its source.
  2. REFUSE-TO-ANSWER — a similarity threshold. If the best match is below it,
     the demo returns "not found in corpus / I won't answer" instead of serving
     a weak, confidently-wrong passage. This is the anti-hallucination guard.
  3. NAIVE vs SEMANTIC — a keyword/substring baseline runs alongside the
     semantic search on queries whose words do NOT appear in the source text.
     The side-by-side makes the value of embeddings concrete and measurable.

Graceful degradation:
- If `sentence-transformers` / `sqlite-vec` are missing, the script prints clear
  install instructions and exits 0 (so CI / a curious reader is never left with a
  cryptic stack trace).

Usage:
    python demo.py                       # run the built-in query suite (grounded)
    python demo.py "your question here"  # ad-hoc query (grounded, with refusal)
    python demo.py --bench               # built-in suite + timings actually measured
    python demo.py --compare             # naive keyword vs semantic, side by side
    python demo.py --refuse-demo         # show the refuse-to-answer path
    python demo.py -k 5                  # top-5 instead of top-3
    python demo.py --threshold 45        # override the refusal threshold (percent)

Requirements (production venv has these; see README "How to run"):
    pip install "sentence-transformers>=2.7" sqlite-vec numpy
First run downloads the embedding model (~470 MB) into the HuggingFace cache.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sqlite3
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent  # showcase/semantic-vault-search -> repo root
PROD_INDEXER = REPO_ROOT / "bin" / "jarvis-vault-index.py"
PROD_SEARCH = REPO_ROOT / "bin" / "vault-search-v2.py"
SAMPLE_CORPUS = HERE / "sample_corpus"

MODEL_NAME = "intfloat/multilingual-e5-small"
EMBEDDING_DIM = 384

# Refusal threshold (similarity percent). If the TOP hit scores below this, the
# demo refuses to answer rather than serve a weak match. Chosen from measured
# data on this corpus (see README "The refuse-to-answer path"): relevant queries
# top out at ~40-50%, while off-topic queries (e.g. "capital of France") land
# below ~36%. 40.0 cleanly separates the demo's relevant set from the off-topic
# probes. It is a tunable knob, NOT a universal constant — see README.
DEFAULT_THRESHOLD = 40.0


def _load_production_module(path: Path, name: str):
    """Import a hyphenated production script as a module, by file path."""
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _check_deps() -> bool:
    """Return True if heavy deps are importable; print guidance and return False otherwise."""
    missing = []
    for mod in ("sentence_transformers", "sqlite_vec", "numpy"):
        if importlib.util.find_spec(mod) is None:
            missing.append(mod)
    if missing:
        print("=" * 70)
        print("Demo cannot run: missing optional dependencies:", ", ".join(missing))
        print("=" * 70)
        print()
        print("This demo runs the REAL embedding + vector-search pipeline, so it")
        print("needs the same libraries as production. Install them with:")
        print()
        print('    pip install "sentence-transformers>=2.7" sqlite-vec numpy')
        print()
        print("The first run also downloads the embedding model (~470 MB):")
        print(f"    {MODEL_NAME}")
        print()
        print("Then re-run:  python demo.py")
        print()
        print("(Exiting 0 — this is expected graceful degradation, not a failure.)")
        return False
    return True


def build_index(db: sqlite3.Connection, model, chunk_fn) -> tuple[int, int]:
    """Index the sample corpus into an in-memory sqlite-vec DB. Returns (files, chunks)."""
    db.executescript(
        f"""
        CREATE TABLE files  (id INTEGER PRIMARY KEY, path TEXT, source TEXT);
        CREATE TABLE chunks (id INTEGER PRIMARY KEY, file_id INTEGER, chunk_index INTEGER, text TEXT);
        CREATE VIRTUAL TABLE vec_chunks USING vec0(
            chunk_id INTEGER PRIMARY KEY,
            embedding FLOAT[{EMBEDDING_DIM}]
        );
        """
    )

    md_files = sorted(SAMPLE_CORPUS.glob("*.md"))
    if not md_files:
        sys.exit(f"No sample corpus found in {SAMPLE_CORPUS}")

    n_files = 0
    n_chunks = 0
    cur = db.cursor()
    for fpath in md_files:
        text = fpath.read_text(encoding="utf-8")
        chunks = chunk_fn(text)  # production chunker
        if not chunks:
            continue
        cur.execute(
            "INSERT INTO files (path, source) VALUES (?, ?)",
            (str(fpath), "sample"),
        )
        file_id = cur.lastrowid
        # Production convention: documents are embedded with the "passage:" prefix.
        prefixed = [f"passage: {c}" for c in chunks]
        vectors = model.encode(prefixed, normalize_embeddings=True, show_progress_bar=False)
        for idx, (chunk, vec) in enumerate(zip(chunks, vectors)):
            cur.execute(
                "INSERT INTO chunks (file_id, chunk_index, text) VALUES (?, ?, ?)",
                (file_id, idx, chunk),
            )
            chunk_id = cur.lastrowid
            cur.execute(
                "INSERT INTO vec_chunks (chunk_id, embedding) VALUES (?, ?)",
                (chunk_id, json.dumps(vec.tolist())),
            )
            n_chunks += 1
        n_files += 1
    db.commit()
    return n_files, n_chunks


def search(db: sqlite3.Connection, model, question: str, k: int = 3) -> list[dict]:
    """Same query shape as production: e5 'query:' prefix + sqlite-vec MATCH ... k = ?.

    Returns one dict per hit with full GROUNDING metadata:
        distance      cosine distance (lower = closer)
        score         (1 - distance) * 100, the displayed similarity percent
        chunk         the source passage text
        path          source file path
        chunk_index   which chunk WITHIN that file the passage is (0-based)
    """
    vec = model.encode([f"query: {question}"], normalize_embeddings=True, show_progress_bar=False)[0]
    sql = """
        SELECT v.distance, c.text, f.path, c.chunk_index
        FROM vec_chunks v
        JOIN chunks c ON c.id = v.chunk_id
        JOIN files  f ON f.id = c.file_id
        WHERE v.embedding MATCH ? AND k = ?
        ORDER BY v.distance
    """
    rows = db.execute(sql, (json.dumps(vec.tolist()), k)).fetchall()
    return [
        {
            "distance": r[0],
            "score": round((1 - r[0]) * 100, 1),
            "chunk": r[1],
            "path": r[2],
            "chunk_index": r[3],
        }
        for r in rows
    ]


def answer(db: sqlite3.Connection, model, question: str, k: int, threshold: float) -> dict:
    """Retrieval + refuse-to-answer gate.

    Returns {"refused": bool, "threshold": float, "results": [...], "top": dict|None}.
    If the top hit's score is below `threshold`, the answer is REFUSED: results
    are still attached for transparency, but `refused=True` signals that a RAG
    layer should NOT feed them to an LLM as grounding.
    """
    results = search(db, model, question, k=k)
    top = results[0] if results else None
    refused = (top is None) or (top["score"] < threshold)
    return {"refused": refused, "threshold": threshold, "results": results, "top": top}


# ---------------------------------------------------------------------------
# Naive keyword baseline (the "before" picture)
# ---------------------------------------------------------------------------

_WORD_RE = re.compile(r"[a-zà-ÿ0-9]+", re.IGNORECASE)


def _tokens(text: str) -> list[str]:
    return [t.lower() for t in _WORD_RE.findall(text)]


def naive_search(corpus_chunks: list[dict], question: str, k: int = 3) -> list[dict]:
    """A keyword/substring baseline — the v1-style approach embeddings replace.

    Scores each chunk by how many DISTINCT query words appear in it (case-
    insensitive token overlap). No stemming, no synonyms, no concepts: this is
    exactly the lexical matching that fails when the question and the source use
    different vocabulary for the same idea. Returns top-k by overlap, ties broken
    by chunk order. Chunks with zero overlap are dropped (a keyword engine has
    literally nothing to return).
    """
    q_tokens = set(_tokens(question))
    scored = []
    for c in corpus_chunks:
        c_tokens = set(_tokens(c["chunk"]))
        overlap = q_tokens & c_tokens
        if overlap:
            scored.append({**c, "overlap": len(overlap), "matched": sorted(overlap)})
    scored.sort(key=lambda x: (-x["overlap"], x["path"], x["chunk_index"]))
    return scored[:k]


def load_corpus_chunks(db: sqlite3.Connection) -> list[dict]:
    """Pull every indexed chunk back out (for the naive baseline to scan)."""
    rows = db.execute(
        """
        SELECT c.text, f.path, c.chunk_index
        FROM chunks c JOIN files f ON f.id = c.file_id
        ORDER BY f.path, c.chunk_index
        """
    ).fetchall()
    return [{"chunk": r[0], "path": r[1], "chunk_index": r[2]} for r in rows]


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------


def _snippet(text: str, n: int = 120) -> str:
    s = " ".join(text.split())
    return s if len(s) <= n else s[:n].rsplit(" ", 1)[0] + "…"


def fmt_result(r: dict) -> str:
    """One grounded result line: score + file + chunk index (the citation) + snippet."""
    name = Path(r["path"]).name
    cite = f"{name}#chunk{r['chunk_index']}"
    return f"  {r['score']:5.1f}%  {cite:22}  {_snippet(r['chunk'])}"


def fmt_naive(r: dict) -> str:
    name = Path(r["path"]).name
    cite = f"{name}#chunk{r['chunk_index']}"
    matched = ",".join(r["matched"])
    return f"  hits={r['overlap']:<2} {cite:22}  [matched: {matched}]"


# ---------------------------------------------------------------------------
# Query suites
# ---------------------------------------------------------------------------

# Queries chosen so a keyword grep would MISS the right file (no shared word),
# but semantic retrieval finds it by concept. Each has an expected target file
# so the demo can self-check that the right note is the top hit.
DEMO_QUERIES = [
    ("what's my strategy for splitting up my savings", "investing.md"),
    ("keeping my home network secure", "homelab.md"),
    ("I get queasy on long bus rides", "travel.md"),
    ("vegetarian comfort meal for a cold evening", "cooking.md"),
    ("how do I bulk up without losing endurance", "fitness.md"),
]

# Three queries where the words DELIBERATELY do not appear in the source text,
# so the naive keyword baseline returns nothing (or the wrong thing) while the
# semantic engine still finds the right note by meaning. Used by --compare.
COMPARE_QUERIES = [
    # query, expected target file, the concept link the words don't carry
    ("I get queasy on long bus rides", "travel.md", "queasy/bus -> 'motion sickness' / 'road transfers'"),
    ("vegetarian comfort meal for a cold evening", "cooking.md", "vegetarian/comfort -> 'slow-braised lentils over rice'"),
    ("how do I bulk up without losing endurance", "fitness.md", "bulk up/endurance -> 'add lean mass' / 'cardio base'"),
]

# Off-topic queries with NO answer in this corpus. The refusal gate must reject
# these. Scores are measured at runtime, not hardcoded.
REFUSE_QUERIES = [
    "what is the capital of France",
    "how do I file my taxes in Germany",
    "how to change a car tyre on the motorway",
]


def open_vec_db() -> sqlite3.Connection:
    import sqlite_vec
    db = sqlite3.connect(":memory:")
    db.enable_load_extension(True)
    sqlite_vec.load(db)
    db.enable_load_extension(False)
    return db


# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------


def run_suite(db, model, queries, k, threshold) -> list[float]:
    """Run the grounded query suite with the refusal gate. Returns per-query times."""
    times = []
    for q, expected in queries:
        t0 = time.perf_counter()
        out = answer(db, model, q, k=k, threshold=threshold)
        dt = time.perf_counter() - t0
        times.append(dt)
        print(f'Q: "{q}"   ({dt * 1000:.0f} ms)')
        if out["refused"]:
            best = out["top"]["score"] if out["top"] else 0.0
            print(f"  ⛔ REFUSED — best match {best:.1f}% < threshold {threshold:.0f}%. "
                  "Not in corpus; won't answer.")
        else:
            for r in out["results"]:
                print(fmt_result(r))
            top_name = Path(out["top"]["path"]).name
            ok = "✓" if (expected is None or top_name == expected) else "✗ (expected " + expected + ")"
            print(f"  grounding: top hit = {top_name}#chunk{out['top']['chunk_index']} "
                  f"@ {out['top']['score']:.1f}%   {ok}")
        print()
    return times


def run_compare(db, model, k) -> None:
    """Side-by-side: naive keyword baseline vs semantic, on no-word-overlap queries."""
    corpus_chunks = load_corpus_chunks(db)
    print("NAIVE keyword/substring baseline  vs  SEMANTIC embedding retrieval")
    print("(queries deliberately share NO meaningful words with the target note)")
    print("=" * 70)
    semantic_wins = 0
    for q, expected, link in COMPARE_QUERIES:
        print(f'\nQ: "{q}"')
        print(f"   concept the words don't carry: {link}")

        naive = naive_search(corpus_chunks, q, k=k)
        print("  NAIVE keyword:")
        if not naive:
            print("    (no chunk shares any query word — keyword search returns NOTHING)")
            naive_top = None
        else:
            for r in naive:
                print("  " + fmt_naive(r))
            naive_top = Path(naive[0]["path"]).name

        sem = search(db, model, q, k=k)
        print("  SEMANTIC:")
        for r in sem:
            print("  " + fmt_result(r))
        sem_top = Path(sem[0]["path"]).name if sem else None

        naive_ok = (naive_top == expected)
        sem_ok = (sem_top == expected)
        if sem_ok and not naive_ok:
            semantic_wins += 1
        verdict = (f"  -> naive top: {naive_top or 'NONE'} ({'hit' if naive_ok else 'miss'})"
                   f"  |  semantic top: {sem_top} ({'hit' if sem_ok else 'miss'})")
        print(verdict)
    print("\n" + "=" * 70)
    print(f"Result: semantic found the right note on {semantic_wins}/{len(COMPARE_QUERIES)} "
          "queries where the naive keyword baseline did not.")


def run_refuse(db, model, k, threshold) -> None:
    """Show the refuse-to-answer path on queries with no answer in the corpus."""
    print(f"Refuse-to-answer gate — threshold = {threshold:.0f}% similarity")
    print("These questions have NO answer in the 5-note corpus. A naive RAG layer")
    print("would still hand its top (weak) match to the LLM and risk a confident")
    print("hallucination. The gate refuses instead.")
    print("=" * 70)
    for q in REFUSE_QUERIES:
        out = answer(db, model, q, k=k, threshold=threshold)
        best = out["top"]["score"] if out["top"] else 0.0
        best_file = Path(out["top"]["path"]).name if out["top"] else "—"
        if out["refused"]:
            print(f'\nQ: "{q}"')
            print(f"  ⛔ REFUSED — best match was {best_file} @ {best:.1f}% "
                  f"(< {threshold:.0f}%). Returned: \"not found in corpus / I won't answer\".")
        else:
            print(f'\nQ: "{q}"')
            print(f"  ⚠ NOT refused — best match {best_file} @ {best:.1f}% (>= {threshold:.0f}%). "
                  "Threshold may need raising for this corpus.")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("question", nargs="*", help="Ad-hoc query (default: run the built-in suite)")
    ap.add_argument("-k", type=int, default=3, help="Top-K results (default 3)")
    ap.add_argument("--bench", action="store_true", help="Print timings actually measured this run")
    ap.add_argument("--compare", action="store_true", help="Naive keyword vs semantic, side by side")
    ap.add_argument("--refuse-demo", action="store_true", help="Show the refuse-to-answer path")
    ap.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD,
                    help=f"Refusal threshold in similarity %% (default {DEFAULT_THRESHOLD:.0f})")
    args = ap.parse_args()

    if not _check_deps():
        return 0

    # Pull the REAL chunker from the production indexer (no fork).
    indexer = _load_production_module(PROD_INDEXER, "prod_indexer")
    chunk_fn = indexer.chunk_markdown

    from sentence_transformers import SentenceTransformer

    t0 = time.perf_counter()
    model = SentenceTransformer(MODEL_NAME)
    t_model = time.perf_counter() - t0

    db = open_vec_db()
    t0 = time.perf_counter()
    n_files, n_chunks = build_index(db, model, chunk_fn)
    t_index = time.perf_counter() - t0

    print(f"\nIndexed {n_files} files / {n_chunks} chunks from {SAMPLE_CORPUS.name}/")
    print(f"Model load: {t_model:.2f}s   Index build: {t_index:.2f}s\n")

    # --- routing ---
    if args.compare:
        run_compare(db, model, k=args.k)
        return 0

    if args.refuse_demo:
        run_refuse(db, model, k=args.k, threshold=args.threshold)
        return 0

    if args.question:
        # Ad-hoc query: grounded + refusal gate.
        q = " ".join(args.question)
        out = answer(db, model, q, k=args.k, threshold=args.threshold)
        print(f'Q: "{q}"')
        if out["refused"]:
            best = out["top"]["score"] if out["top"] else 0.0
            print(f"  ⛔ REFUSED — best match {best:.1f}% < threshold {args.threshold:.0f}%. "
                  "Not in corpus; won't answer.")
        else:
            for r in out["results"]:
                print(fmt_result(r))
            print(f"  grounding: top hit = {Path(out['top']['path']).name}"
                  f"#chunk{out['top']['chunk_index']} @ {out['top']['score']:.1f}%")
        return 0

    # Default: grounded built-in suite (+ optional bench).
    query_times = run_suite(db, model, DEMO_QUERIES, k=args.k, threshold=args.threshold)

    if args.bench and query_times:
        avg_ms = sum(query_times) / len(query_times) * 1000
        print("-" * 70)
        print("Measured on this machine (your numbers will differ):")
        print(f"  model load (cold)   : {t_model:.2f} s")
        print(f"  index {n_chunks} chunks   : {t_index:.2f} s")
        print(f"  query (avg of {len(query_times):>2})    : {avg_ms:.0f} ms")
        print("-" * 70)

    return 0


if __name__ == "__main__":
    sys.exit(main())

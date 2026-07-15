#!/usr/bin/env python3
"""
vault-search-v2 — Recherche sémantique sur le vault.

Charge le modèle d'embedding local, embed la question, fait un cosine similarity
search dans la DB sqlite-vec, ressort les top K passages avec leur fichier source.
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
from pathlib import Path

HOME = Path.home()
DB_PATH = HOME / ".local" / "share" / "jarvis" / "vault.db"
MODEL_NAME = "intfloat/multilingual-e5-small"

# Couleurs ANSI
def supports_color() -> bool:
    return sys.stdout.isatty()

R = "\033[31m" if supports_color() else ""
G = "\033[32m" if supports_color() else ""
Y = "\033[33m" if supports_color() else ""
B = "\033[34m" if supports_color() else ""
D = "\033[2m" if supports_color() else ""
N = "\033[0m" if supports_color() else ""


def open_db() -> sqlite3.Connection:
    if not DB_PATH.exists():
        sys.exit(f"❌ DB introuvable : {DB_PATH}\n   Lancez `jarvis-vault-index` pour la créer.")
    db = sqlite3.connect(str(DB_PATH))
    db.enable_load_extension(True)
    import sqlite_vec
    sqlite_vec.load(db)
    db.enable_load_extension(False)
    return db


# --- Retrieval hybride (pattern MemX) : vecteur + mots-clés FTS5, fusion RRF, porte de confiance ---
RRF_K = 60            # constante standard de Reciprocal Rank Fusion
CONF_TAU = 0.50       # porte de confiance : sim cosinus mini pour accepter un résultat vecteur seul
CANDIDATES = 50       # nb de candidats récupérés par voie avant fusion

_FR_STOP = {
    "de", "la", "le", "les", "des", "et", "en", "un", "une", "du", "au", "aux",
    "pour", "par", "sur", "avec", "dans", "ce", "ces", "que", "qui", "quoi",
    "ma", "mon", "mes", "ses", "son", "sa", "est", "ne", "pas", "the", "and",
    "of", "to", "a", "is", "comment", "quel", "quelle", "face",
}


def _build_fts_query(question: str) -> str | None:
    """Transforme une question NL en requête FTS5 : tokens significatifs joints par OR."""
    toks = re.findall(r"\w+", question.lower(), flags=re.UNICODE)
    toks = [t for t in toks if len(t) >= 3 and t not in _FR_STOP]
    if not toks:
        return None
    # dédupe en gardant l'ordre, quote chaque token (évite les erreurs de syntaxe FTS5)
    seen, uniq = set(), []
    for t in toks:
        if t not in seen:
            seen.add(t); uniq.append(t)
    return " OR ".join(f'"{t}"' for t in uniq)


def search(question: str, k: int = 10, source: str | None = None, gate: bool = True) -> list[dict]:
    db = open_db()

    # Charger le modèle (5-10s au premier appel à cause de PyTorch init)
    from sentence_transformers import SentenceTransformer
    model = SentenceTransformer(MODEL_NAME)
    vec = model.encode(
        [f"query: {question}"], normalize_embeddings=True, show_progress_bar=False
    )[0]

    # 1) Rappel vecteur (KNN pur, sans jointure — évite le bug join×vec0)
    vec_rows = db.execute(
        "SELECT chunk_id, distance FROM vec_chunks WHERE embedding MATCH ? AND k = ? ORDER BY distance",
        (json.dumps(vec.tolist()), CANDIDATES),
    ).fetchall()
    vec_ids = [r[0] for r in vec_rows]
    dist = {r[0]: r[1] for r in vec_rows}
    max_sim = (1 - vec_rows[0][1]) if vec_rows else 0.0  # meilleure similarité cosinus

    # 2) Rappel mots-clés (FTS5)
    fts_ids: list[int] = []
    ftsq = _build_fts_query(question)
    if ftsq:
        try:
            fts_ids = [r[0] for r in db.execute(
                "SELECT chunk_id, rank FROM fts_chunks WHERE fts_chunks MATCH ? ORDER BY rank LIMIT ?",
                (ftsq, CANDIDATES),
            ).fetchall()]
        except sqlite3.OperationalError:
            fts_ids = []

    # 3) Porte de confiance (MemX) : si AUCUN mot-clé ne matche ET la meilleure
    #    similarité vecteur est sous le seuil → rien de fiable, on retourne vide
    #    (supprime les faux positifs/recalls fabriqués).
    if gate and not fts_ids and max_sim < CONF_TAU:
        return []

    # 4) Fusion RRF : score = somme des 1/(RRF_K + rang) sur chaque liste
    rrf: dict[int, float] = {}
    for rank, cid in enumerate(vec_ids, 1):
        rrf[cid] = rrf.get(cid, 0.0) + 1.0 / (RRF_K + rank)
    for rank, cid in enumerate(fts_ids, 1):
        rrf[cid] = rrf.get(cid, 0.0) + 1.0 / (RRF_K + rank)

    vec_set, fts_set = set(vec_ids), set(fts_ids)
    ranked = sorted(rrf, key=lambda c: rrf[c], reverse=True)
    if not ranked:
        return []

    # 5) Récupère les détails (texte/chemin/source) pour les candidats fusionnés
    ph = ",".join("?" * len(ranked))
    detail = {
        row[0]: (row[1], row[2], row[3])
        for row in db.execute(
            f"SELECT c.id, c.text, f.path, f.source FROM chunks c "
            f"JOIN files f ON f.id = c.file_id WHERE c.id IN ({ph})",
            ranked,
        ).fetchall()
    }

    out: list[dict] = []
    for cid in ranked:
        if cid not in detail:
            continue
        text, path, src = detail[cid]
        if source and src != source:
            continue
        match = "both" if (cid in vec_set and cid in fts_set) else ("vec" if cid in vec_set else "kw")
        out.append({
            "distance": dist.get(cid),  # None si trouvé uniquement par mots-clés
            "chunk": text, "path": path, "source": src,
            "rrf": round(rrf[cid], 5), "match": match,
        })
        if len(out) >= k:
            break
    return out


def format_path(path: str) -> str:
    """Raccourcit ~/Documents/Obsidian/vault/... en relatif."""
    p = Path(path)
    home = str(HOME)
    if str(p).startswith(home):
        return "~" + str(p)[len(home):]
    return str(p)


def truncate_chunk(text: str, max_chars: int = 350) -> str:
    text = text.strip()
    if len(text) <= max_chars:
        return text
    return text[:max_chars].rsplit(" ", 1)[0] + "…"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("question", nargs="+", help="Question en langage naturel")
    p.add_argument("-k", type=int, default=10, help="Nombre de résultats (défaut: 10)")
    p.add_argument("-s", "--source", help="Filtrer par source (vault, sessions, memory-mirror, jarvis-repo-docs)")
    p.add_argument("--full", action="store_true", help="Afficher les chunks complets (sans tronquer)")
    p.add_argument("--json", action="store_true", help="Sortie JSON pour pipe")
    p.add_argument("--no-gate", action="store_true", help="Désactiver la porte de confiance (forcer un résultat même peu fiable)")
    args = p.parse_args()

    question = " ".join(args.question)

    results = search(question, k=args.k, source=args.source, gate=not args.no_gate)

    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2, default=str))
        return 0

    if not results:
        print(f"{Y}Aucun résultat.{N}")
        return 1

    print()
    print(f"{B}═══════════════════════════════════════════════════════════════{N}")
    print(f"{B}  Recherche : {question}{N}")
    if args.source:
        print(f"{D}  Filtre source : {args.source}{N}")
    print(f"{B}═══════════════════════════════════════════════════════════════{N}")
    print()

    tag = {"both": "🔵 vec+kw", "vec": "  vec", "kw": "   kw"}
    for i, r in enumerate(results, 1):
        # distance: 0 = identique, plus c'est bas mieux c'est ; None = trouvé par mots-clés seuls
        score = f"{round((1 - r['distance']) * 100, 1)}%" if r.get("distance") is not None else "  —  "
        path_short = format_path(r["path"])
        chunk = r["chunk"] if args.full else truncate_chunk(r["chunk"])
        m = tag.get(r.get("match", "vec"), "")

        print(f"{G}{i:2}.{N} {Y}{score:>6}{N} {D}{m}{N}  {B}{path_short}{N}  {D}({r['source']}){N}")
        # Indenter le chunk
        for line in chunk.splitlines():
            print(f"      {line}")
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())

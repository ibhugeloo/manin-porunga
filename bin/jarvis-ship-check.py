#!/usr/bin/env python3
"""
jarvis-ship-check — Garde-fou MÉCANIQUE de complétude pour le pipeline jarvis-ship.

Transforme « c'est prêt » (déclaration cognitive, donc faillible — SOUL §5, gap
harness-engineering n°2) en verdict PASS/FAIL vérifiable sur un artefact feature_list.

Principe (harness-engineering leçon 8 + 9) : un livraison n'est « prête » que si
CHAQUE feature de la liste est `done` ET porte une `evidence` (preuve de vérification).
Sinon : FAIL, exit code 1 → la gate SHIP de jarvis-ship ne peut pas être franchie.

Usage :
    jarvis-ship-check <feature_list.json>
    jarvis-ship-check <feature_list.json> --json

Schéma feature_list.json attendu :
{
  "task": "<description courte de la tâche>",
  "project": "<nom projet>",
  "created": "YYYY-MM-DD",
  "features": [
    {
      "id": "F1",
      "desc": "<livrable concret>",
      "acceptance": "<critère vérifiable, en mots>",
      "status": "todo" | "done",
      "evidence": "<comment ça a été vérifié — test, screenshot, commande>"
    }
  ]
}
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

VALID_STATUS = {"todo", "done"}


def validate(data: dict) -> tuple[bool, list[str], dict]:
    """Retourne (passed, problèmes, stats)."""
    problems: list[str] = []
    features = data.get("features")
    if not isinstance(features, list) or not features:
        return False, ["feature_list vide ou absente : aucune feature à livrer définie."], {"total": 0, "done": 0}

    done = 0
    for i, f in enumerate(features, 1):
        fid = f.get("id") or f"#{i}"
        desc = (f.get("desc") or "").strip()
        status = (f.get("status") or "").strip().lower()
        evidence = (f.get("evidence") or "").strip()
        acceptance = (f.get("acceptance") or "").strip()

        if not desc:
            problems.append(f"{fid}: pas de description.")
        if not acceptance:
            problems.append(f"{fid}: pas de critère d'acceptation (acceptance vide).")
        if status not in VALID_STATUS:
            problems.append(f"{fid}: status invalide '{status}' (attendu: todo|done).")
        if status == "done":
            if not evidence:
                problems.append(f"{fid} marquée 'done' SANS evidence → victoire prématurée (leçon 9). Preuve requise.")
            else:
                done += 1
        else:
            problems.append(f"{fid}: NON terminée (status={status or 'absent'}) — '{desc[:60]}'.")

    stats = {"total": len(features), "done": done}
    passed = (len(problems) == 0) and (done == len(features))
    return passed, problems, stats


def main() -> int:
    p = argparse.ArgumentParser(description="Garde-fou de complétude jarvis-ship")
    p.add_argument("feature_list", help="Chemin du feature_list.json")
    p.add_argument("--json", action="store_true", help="Sortie JSON")
    args = p.parse_args()

    path = Path(args.feature_list).expanduser()
    if not path.exists():
        msg = f"feature_list introuvable : {path}"
        print(json.dumps({"passed": False, "error": msg}) if args.json else f"❌ FAIL — {msg}")
        return 2
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        msg = f"JSON invalide : {e}"
        print(json.dumps({"passed": False, "error": msg}) if args.json else f"❌ FAIL — {msg}")
        return 2

    passed, problems, stats = validate(data)

    if args.json:
        print(json.dumps({"passed": passed, "problems": problems, "stats": stats}, ensure_ascii=False, indent=2))
        return 0 if passed else 1

    task = data.get("task", "(tâche sans nom)")
    if passed:
        print(f"✅ PASS — « {task} » : {stats['done']}/{stats['total']} features livrées et prouvées.")
        return 0
    print(f"❌ FAIL — « {task} » : {stats['done']}/{stats['total']} features prouvées. NON prêt à shipper.")
    for pb in problems:
        print(f"   • {pb}")
    return 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
jarvis-ship-template — Génère un feature_list.json de référence pour jarvis-ship,
adapté à la TAILLE du projet (landing / sprint / app), à partir de la
« Golmon Proof Checklist ».

Principe : le bloc GOLMON-PROOF est présent dans TOUTES les tailles (c'est le point —
un produit incompréhensible reste mauvais). Le reste (E2E, functional, perf, security)
est scalé : une landing n'a pas besoin de tests de concurrence ni de gestion de session.

Chaque feature porte un `block` (mappé à l'outil Porunga qui la prouve), une `desc`,
un critère `acceptance` en mots, `status: todo`, `evidence: ""`. Le validateur
`jarvis-ship-check` exige ensuite status=done + evidence pour chacune avant SHIP.

Usage :
    jarvis-ship-template <landing|sprint|app> "<tâche>" <projet> [--out <path>]
    jarvis-ship-template app "Refonte espace locataire" adil-diagnostic
    (défaut --out : ~/.local/var/jarvis-ship/<projet>-<slug>.json)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Outils Porunga qui PROUVENT chaque bloc (evidence attendue) :
#   E2E        → qa-playwright-operator (parcours réels, mobile 375x667)
#   FUNCTIONAL → tests + design-lead/nextjs-frontend-dev
#   UX/UI      → design-lead review
#   GOLMON     → passage HUMAIN à froid (non-mécanisable — le cœur du test)
#   PERF       → watchtower + Lighthouse
#   SECURITY   → skill stack-security-audit

def feat(fid, block, desc, acceptance):
    return {"id": fid, "block": block, "desc": desc, "acceptance": acceptance,
            "status": "todo", "evidence": ""}

# --- Bloc GOLMON-PROOF : identique pour toutes les tailles ---
def golmon(prefix="G"):
    return [
        feat(f"{prefix}1", "golmon", "Parcours à froid par un non-initié",
             "Un total débutant atteint l'objectif principal SANS aide (run qa-playwright-operator + observation humaine)."),
        feat(f"{prefix}2", "golmon", "Wording sans jargon",
             "Labels/messages compréhensibles par quelqu'un hors de l'industrie. Zéro jargon technique visible."),
        feat(f"{prefix}3", "golmon", "Pas d'écrasement cognitif",
             "L'écran principal ne submerge pas : hiérarchie claire, une action évidente à faire."),
        feat(f"{prefix}4", "golmon", "Feedback après chaque action",
             "Toute action utilisateur produit un retour visible (succès/erreur/chargement)."),
    ]

# --- Briques par bloc, réutilisées selon la taille ---
def e2e(items):      return [feat(f"E{i+1}", "e2e", d, a) for i, (d, a) in enumerate(items)]
def func(items):     return [feat(f"F{i+1}", "functional", d, a) for i, (d, a) in enumerate(items)]
def uxui(items):     return [feat(f"U{i+1}", "ux-ui", d, a) for i, (d, a) in enumerate(items)]
def perf(items):     return [feat(f"P{i+1}", "perf", d, a) for i, (d, a) in enumerate(items)]
def sec(items):      return [feat(f"S{i+1}", "security", d, a) for i, (d, a) in enumerate(items)]

TEMPLATES = {
    # ---------- LANDING (Route 1) ----------
    "landing": lambda: (
        uxui([("Le CTA principal est évident", "Au 1er coup d'œil on sait quoi faire et où cliquer."),
              ("Responsive mobile", "Rendu propre en 375x667, rien ne déborde.")])
        + e2e([("Le CTA mène à la bonne destination", "Clic CTA → page/action attendue (Playwright)."),
               ("Le formulaire de contact soumet", "Saisie valide → confirmation visible, lead reçu.")])
        + func([("Validation + erreurs du formulaire", "Champs requis/format vérifiés, message d'erreur clair.")])
        + golmon()
        + perf([("Vitesse de chargement", "LCP < 2,5 s sur mobile (Lighthouse).")])
        + sec([("Validation des entrées du formulaire", "Pas d'injection via les champs ; pas de secret exposé côté client.")])
    ),
    # ---------- SPRINT MÉTIER (Route 2) ----------
    "sprint": lambda: (
        uxui([("Flow principal intuitif", "Le parcours métier clé s'enchaîne sans hésitation."),
              ("UI cohérente", "Composants/espacements/couleurs homogènes."),
              ("Responsive mobile", "Parcours clé utilisable en 375x667.")])
        + e2e([("Inscription / onboarding", "Nouvel utilisateur arrive jusqu'à l'écran utile (Playwright)."),
               ("Parcours métier principal de bout en bout", "L'objectif central est atteignable sans bug."),
               ("Connexion / déconnexion", "Login, logout, re-login OK.")])
        + func([("Tous les boutons fonctionnent", "Aucune action morte."),
                ("CRUD du cœur métier", "Créer/lire/modifier l'entité principale."),
                ("Recherche / filtre / tri", "Résultats corrects et cohérents."),
                ("Gestion des erreurs", "Échec API → message clair, pas d'écran cassé.")])
        + golmon()
        + perf([("Vitesse de chargement", "LCP < 2,5 s mobile."),
                ("Temps de réponse API", "Endpoints critiques < 500 ms en charge normale.")])
        + sec([("Authentification / autorisation", "Accès aux données restreint au bon utilisateur (RLS si Supabase)."),
                ("Validation des entrées", "Inputs assainis, pas d'injection."),
                ("Protection XSS", "Aucun rendu non échappé de contenu utilisateur.")])
    ),
    # ---------- APP MÉTIER COMPLÈTE (Route 3) ----------
    "app": lambda: (
        uxui([("Flow principal intuitif", "Parcours métier clé fluide pour un utilisateur réel."),
              ("UI cohérente + dark/light si applicable", "Homogène, thèmes OK."),
              ("Responsive mobile complet", "Toutes les vues clés utilisables en 375x667.")])
        + e2e([("Inscription → onboarding", "Nouvel utilisateur jusqu'au 1er succès (Playwright)."),
               ("Créer un nouveau projet/dossier", "Création complète sans bug."),
               ("Ajouter données / contenu", "Saisie + persistance vérifiées."),
               ("Inviter un membre / partage", "Le flux collaboratif fonctionne (si pertinent)."),
               ("Modifier les réglages", "Changements persistés."),
               ("Objectif principal de bout en bout", "Le but central de l'app est atteint."),
               ("Déconnexion / reconnexion", "Session restaurée correctement.")])
        + func([("Tous les boutons fonctionnent", "Aucune action morte."),
                ("Validation des formulaires", "Tous formulaires : requis/format/erreurs."),
                ("Gestion des erreurs", "Tout échec géré gracieusement (pas de null silencieux — SOUL §5)."),
                ("Recherche / filtre / tri", "Corrects sur gros volume."),
                ("Upload / download de fichiers", "Entrée/sortie fichiers fiables."),
                ("Notifications / alertes", "Déclenchées au bon moment.")])
        + golmon()
        + perf([("Vitesse de chargement", "LCP < 2,5 s mobile."),
                ("Temps de réponse API", "Endpoints critiques < 500 ms."),
                ("Stress / charge", "Tient le pic d'usage attendu."),
                ("Gros volumes de données", "Pas de dégradation sur grandes listes (pagination/virtualisation)."),
                ("Mémoire / fuites", "Pas de fuite sur usage prolongé."),
                ("Concurrence", "Accès simultanés sans corruption d'état.")])
        + sec([("Authentification / autorisation", "RLS/policies vérifiées, cloisonnement par utilisateur."),
                ("Validation des entrées", "Toutes entrées assainies."),
                ("Injection SQL", "Requêtes paramétrées, aucune concat brute."),
                ("Protection XSS", "Contenu utilisateur échappé partout."),
                ("Chiffrement des données", "Données sensibles chiffrées au repos/en transit."),
                ("Gestion de session", "Expiration, invalidation, pas de fixation.")])
    ),
}


def slugify(s: str) -> str:
    s = re.sub(r"[^\w\s-]", "", s.lower())
    s = re.sub(r"[\s_]+", "-", s).strip("-")
    return s[:40] or "tache"


def main() -> int:
    p = argparse.ArgumentParser(description="Génère un feature_list jarvis-ship par taille de projet")
    p.add_argument("size", choices=["landing", "sprint", "app"], help="Taille (route Manin)")
    p.add_argument("task", help="Description courte de la tâche")
    p.add_argument("project", help="Nom du projet (ex: adil-diagnostic)")
    p.add_argument("--created", default="", help="Date YYYY-MM-DD (sinon laissée vide à remplir)")
    p.add_argument("--out", default="", help="Chemin de sortie (défaut: ~/.local/var/jarvis-ship/<projet>-<slug>.json)")
    p.add_argument("--stdout", action="store_true", help="Écrire sur stdout au lieu d'un fichier")
    args = p.parse_args()

    features = TEMPLATES[args.size]()
    doc = {
        "task": args.task,
        "project": args.project,
        "size": args.size,
        "created": args.created,
        "features": features,
    }
    payload = json.dumps(doc, ensure_ascii=False, indent=2)

    if args.stdout:
        print(payload)
        return 0

    out = Path(args.out).expanduser() if args.out else \
        Path.home() / ".local" / "var" / "jarvis-ship" / f"{args.project}-{slugify(args.task)}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(payload, encoding="utf-8")
    print(f"feature_list ({args.size}, {len(features)} features) → {out}")
    print(f"Vérifier la complétude : jarvis-ship-check {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

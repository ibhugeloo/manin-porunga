#!/bin/bash
# jarvis-bash-guard.sh — PreToolUse hook pour Bash
#
# Mission : casser le pattern de bluff git récidivant (lessons #13, #14, #15).
# Avant toute commande git destructrice / irréversible, force Jarvis à avoir
# lu l'état réel du repo (git status / git log) dans le tour de tool calls
# courant. Sinon le hook bloque avec un message explicite.
#
# Stratégie :
#   - Lire le payload JSON envoyé par Claude Code sur stdin
#   - Extraire la commande Bash
#   - Si la commande matche le pattern destructif → vérifier qu'un git status
#     ou git log a été appelé dans la même session récente (transcript)
#   - Sinon : exit 2 (bloque l'outil) avec stderr lisible
#
# Bypass d'urgence (utilisateur uniquement) : variable d'env JARVIS_GIT_GUARD_BYPASS=1
#
# Référence : decisions.md "anti-bluff git", lessons.md §13/14/15
# Note : ce script est volontairement défensif. Si quoi que ce soit foire,
# il LAISSE PASSER (exit 0) plutôt que de bloquer le workflow d'Idriss.

set +e  # ne PAS sortir sur erreur — on veut être tolérant aux pannes du guard

# --- Bypass explicite ---
if [[ "$JARVIS_GIT_GUARD_BYPASS" == "1" ]]; then
  exit 0
fi

# --- Lire le payload JSON ---
PAYLOAD=$(cat 2>/dev/null)
if [[ -z "$PAYLOAD" ]]; then
  exit 0  # pas de payload, laisser passer
fi

# --- Extraire la commande Bash ---
# Format Claude Code : { "tool_input": { "command": "..." } }
if command -v jq >/dev/null 2>&1; then
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)
else
  CMD=$(printf '%s' "$PAYLOAD" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('tool_input', {}).get('command', ''))
except Exception:
    pass
" 2>/dev/null)
fi

if [[ -z "$CMD" ]]; then
  exit 0  # pas de commande extractible, laisser passer
fi

# --- GARDE-FOU 1 : batch de commandes git/gh MUTANTES interdites ---
# Cause : session 2026-05-30 — rafale de commandes git/gh dépendantes (créer PR
# + merger + commit + push) dans un même flux → résultats désordonnés, états
# hallucinés, commit sous message mensonger. Voir lessons.md #24.
# Règle : opérations d'état = UNE commande, puis vérification isolée. Jamais
# deux verbes mutants chaînés dans la même commande Bash.
# Verbes mutants d'état (liste validée par Idriss) : commit, push, merge,
# rebase, reset, gh pr create, gh pr merge. `gh pr create` compte car le
# danger réel = chaîner create+merge sans vérifier la base (incident 2026-05-30).
MUTATING_COUNT=$(printf '%s' "$CMD" | grep -oE '(git[[:space:]]+(commit|push|merge|rebase|reset)|gh[[:space:]]+pr[[:space:]]+(create|merge))' 2>/dev/null | wc -l | tr -d '[:space:]')

if [[ -n "$MUTATING_COUNT" && "$MUTATING_COUNT" -ge 2 ]]; then
  cat >&2 <<EOF
🛑 jarvis-bash-guard — GARDE-FOU 1 : batch de commandes git/gh mutantes bloqué.

Commande interceptée : $CMD

Cette commande chaîne $MUTATING_COUNT opérations d'état (commit/push/merge/rebase/
reset/gh pr merge). C'est INTERDIT : chaque opération change l'état que la
suivante lit. Les enchaîner produit des états hallucinés (incident 2026-05-30).

RÈGLE : opérations git/prod = UNE commande à la fois, puis une vérification
isolée (git status / git log) avant la suivante. Jamais en batch.

Découpe en commandes séparées et vérifie entre chacune.

Bypass (cas légitime, après vérification manuelle) :
  export JARVIS_GIT_GUARD_BYPASS=1

Référence : ~/.claude/CLAUDE.md → jarvis_soul.md (git séquentiel), lessons.md #24
EOF
  exit 2
fi

# --- Patterns destructifs / irréversibles à intercepter ---
# Inspiré du § "Executing actions with care" du system prompt Claude Code
DANGEROUS_PATTERN='git[[:space:]]+(push[[:space:]]+--force|push[[:space:]]+-f|reset[[:space:]]+--hard|checkout[[:space:]]+--[[:space:]]|restore[[:space:]]+--[[:space:]]|clean[[:space:]]+-f|branch[[:space:]]+-D|rebase[[:space:]]+-i|commit[[:space:]]+--amend)'

if ! printf '%s' "$CMD" | grep -qE "$DANGEROUS_PATTERN"; then
  exit 0  # commande non-destructive, laisser passer
fi

# --- Pour les commandes destructives : vérifier qu'un état a été lu ---
# On lit le transcript Claude Code de la session courante pour voir si un
# git status / git log / git diff a été exécuté dans les 50 derniers tool calls.
if command -v jq >/dev/null 2>&1; then
  TRANSCRIPT_PATH=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null)
else
  TRANSCRIPT_PATH=$(printf '%s' "$PAYLOAD" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('transcript_path', ''))
except Exception:
    pass
" 2>/dev/null)
fi

# Si pas de transcript accessible → on bloque par sécurité (mode strict)
if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
  echo "🛑 jarvis-bash-guard: commande git destructive détectée mais transcript indisponible." >&2
  echo "   Commande : $CMD" >&2
  echo "   Bypass : export JARVIS_GIT_GUARD_BYPASS=1 puis re-tenter." >&2
  exit 2
fi

# Chercher dans le transcript récent un git status/log/diff/branch
RECENT_STATE_READ=$(tail -n 500 "$TRANSCRIPT_PATH" 2>/dev/null | grep -cE 'git[[:space:]]+(status|log|diff|branch|show|stash[[:space:]]+list)' 2>/dev/null)

if [[ -z "$RECENT_STATE_READ" || "$RECENT_STATE_READ" -lt 1 ]]; then
  cat >&2 <<EOF
🛑 jarvis-bash-guard — pattern anti-bluff git activé.

Commande interceptée : $CMD

Cette commande est destructive ou irréversible (push --force, reset --hard,
checkout --, restore --, clean -f, branch -D, commit --amend, rebase -i).

Avant de l'exécuter, tu DOIS avoir lu l'état réel du repo dans ce tour :
  - git status
  - git log --oneline -10
  - git diff (selon contexte)

Pourquoi : leçons cumulatives #13, #14, #15 — pattern récurrent de bluff git.
Lire l'état force la confrontation à la réalité avant action irréversible.

Pour bypasser (cas légitime, après avoir vérifié manuellement) :
  export JARVIS_GIT_GUARD_BYPASS=1

Référence : ~/.claude/CLAUDE.md → agents.md, lessons.md §13/14/15
EOF
  exit 2
fi

# OK : un git status/log/diff a été lu récemment, on laisse passer
exit 0

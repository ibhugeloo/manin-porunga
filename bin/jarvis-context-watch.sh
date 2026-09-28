#!/bin/zsh
# jarvis-context-watch.sh — Hook UserPromptSubmit. Garde-fou de discipline de contexte.
# Mesure la taille du transcript et avertit UNE FOIS par palier franchi quand la
# session devient marathon (risque de degradation). Heuristique volontairement
# grossiere : le JSONL inclut l historique brut, donc taille != contexte effectif.
# Ne bloque JAMAIS un prompt : toute erreur -> exit 0 silencieux. Cf. docs/garde-fous.md.
set +e
command -v jq >/dev/null 2>&1 || exit 0

IN=$(cat 2>/dev/null)
T=$(print -r -- "$IN" | jq -r '.transcript_path // empty' 2>/dev/null)
SID=$(print -r -- "$IN" | jq -r '.session_id // "unknown"' 2>/dev/null)
[ -f "$T" ] || exit 0
MB=$(( $(stat -f%z "$T" 2>/dev/null || echo 0) / 1048576 ))

# Paliers (Mo de transcript) -> niveau. Ajustables ici, nulle part ailleurs.
LEVEL=0
[ "$MB" -ge 6 ]  && LEVEL=1
[ "$MB" -ge 11 ] && LEVEL=2
[ "$MB" -ge 16 ] && LEVEL=3
[ "$LEVEL" -eq 0 ] && exit 0

# Anti-spam : un seul avertissement par palier et par session.
STATE="$HOME/.local/var/jarvis-context-watch/${SID}.level"
mkdir -p "${STATE:h}" 2>/dev/null
[ "$LEVEL" -le "$(cat "$STATE" 2>/dev/null || echo 0)" ] 2>/dev/null && exit 0
echo "$LEVEL" > "$STATE" 2>/dev/null

MSGS=(
  "🟡 Discipline de contexte — session substantielle (~${MB} Mo). Avant une nouvelle phase lourde, envisager un /compact cible (\"garde X, drop Y\")."
  "🟠 Discipline de contexte — session longue (~${MB} Mo). Zone de degradation possible. Recommande : /compact cible maintenant, ou un recap-handoff si une tache independante commence."
  "🔴 Discipline de contexte — session tres longue (~${MB} Mo). Risque reel de degradation. Fortement recommande : /compact, ou nouvelle session avec handoff AVANT toute action prod/risquee."
)
jq -nc --arg c "${MSGS[$LEVEL]} (Heuristique grossiere : taille transcript != contexte exact.)" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}' 2>/dev/null || true
exit 0

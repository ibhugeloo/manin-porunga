#!/bin/zsh
# jarvis-memory-guard — Hook PreToolUse anti-bloat sur Memory/.
# Inspiré du PreToolUse de seanchiuai/openclaude (le 50-line cap sur MEMORY.md).
# Bloque les Write/Edit qui feraient déborder Memory/ au-delà des seuils.
#
# Lit l'input JSON Claude Code sur stdin. Sort :
#   - exit 0 (silent) si OK
#   - JSON {"decision":"block","reason":"…"} sur stdout sinon (Claude Code surface le message)
#
# Bypass : env JARVIS_MEMORY_GUARD_BYPASS=1

set -uo pipefail

LOG="$HOME/.local/var/log/jarvis-memory-guard.log"
mkdir -p "$(dirname "$LOG")"

# Bypass explicite
if [[ "${JARVIS_MEMORY_GUARD_BYPASS:-0}" == "1" ]]; then
  exit 0
fi

INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')

# Filtre : on ne s'occupe que de Write/Edit/MultiEdit
case "$TOOL_NAME" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

# Filtre : doit cibler Memory/ top-level (pas _archives, pas auto, pas observations.md sous-dirs)
MEMORY_DIR="$HOME/Documents/Obsidian/vault/Claude/Memory"
case "$FILE_PATH" in
  "$MEMORY_DIR"/*.md) ;;  # OK, top-level
  *) exit 0 ;;
esac

# Si dans un sous-dossier (_archives/, auto/, proposed/, etc.) → laisser passer
case "$FILE_PATH" in
  "$MEMORY_DIR"/*/*) exit 0 ;;
esac

BASENAME=$(basename "$FILE_PATH")

# Whitelist : fichiers qui peuvent croître par design
case "$BASENAME" in
  decisions.md|decisions-detail.md|decisions-archive.md|lessons.md|MEMORY.md|observations.md)
    # On laisse passer mais on log la croissance pour audit
    if [[ -f "$FILE_PATH" ]]; then
      SIZE=$(wc -c < "$FILE_PATH" | tr -d ' ')
      echo "[$(date)] WHITELIST: $BASENAME (size=${SIZE}B)" >> "$LOG"
    fi
    exit 0
    ;;
esac

# Compter les fichiers .md top-level actuels
CURRENT_COUNT=$(find "$MEMORY_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')

# Pour Write : si le fichier n'existe pas, ça ajoute 1 au count
NEW_FILE=0
if [[ "$TOOL_NAME" == "Write" && ! -f "$FILE_PATH" ]]; then
  NEW_FILE=1
fi

FUTURE_COUNT=$((CURRENT_COUNT + NEW_FILE))

# Seuil : 16 fichiers max top-level (on est à 12 + observations.md = 13, marge raisonnable)
MAX_FILES=14
if [[ $FUTURE_COUNT -gt $MAX_FILES ]]; then
  REASON="Memory/ atteindrait $FUTURE_COUNT fichiers top-level (seuil: $MAX_FILES, durci 2026-05-09). Anti-drift actif (cf. lessons.md §18). Choisir : (a) consolider dans un fichier existant, (b) déplacer vers _archives/, (c) déplacer la doc technique vers manin-control-room/docs/, (d) override avec env JARVIS_MEMORY_GUARD_BYPASS=1."
  echo "[$(date)] BLOCK: count=$FUTURE_COUNT > $MAX_FILES — $FILE_PATH" >> "$LOG"
  jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
  exit 0
fi

# Estimer la taille future du fichier
CURRENT_SIZE=0
[[ -f "$FILE_PATH" ]] && CURRENT_SIZE=$(wc -c < "$FILE_PATH" | tr -d ' ')

CONTENT=""
case "$TOOL_NAME" in
  Write)
    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty')
    NEW_SIZE=$(printf '%s' "$CONTENT" | wc -c | tr -d ' ')
    ;;
  Edit)
    OLD=$(printf '%s' "$INPUT" | jq -r '.tool_input.old_string // empty')
    NEW=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty')
    OLD_LEN=$(printf '%s' "$OLD" | wc -c | tr -d ' ')
    NEW_LEN=$(printf '%s' "$NEW" | wc -c | tr -d ' ')
    NEW_SIZE=$((CURRENT_SIZE + NEW_LEN - OLD_LEN))
    ;;
  MultiEdit)
    DELTA=$(printf '%s' "$INPUT" | jq -r '
      [.tool_input.edits[] |
       (.new_string | length) - (.old_string | length)]
      | add // 0
    ')
    NEW_SIZE=$((CURRENT_SIZE + DELTA))
    ;;
esac

# Seuil par fichier : 20 KB hors whitelist (les feedback_* / reference_* opérationnels font 1-7 KB)
# agents.md : doctrine vivante → plafond doux relevé à 30 KB (Leo 2026-06-04). Au-delà = audit/scission obligatoire, pas de croissance libre.
MAX_FILE_SIZE=20480
[[ "$BASENAME" == "agents.md" ]] && MAX_FILE_SIZE=30720
if [[ $NEW_SIZE -gt $MAX_FILE_SIZE ]]; then
  KB=$((NEW_SIZE / 1024))
  CAP_KB=$((MAX_FILE_SIZE / 1024))
  REASON="$BASENAME atteindrait ~${KB} KB (seuil: ${CAP_KB} KB). Probable drift de doc technique dans la mémoire cognitive (cf. lessons.md §18). Choisir : (a) scinder en plusieurs concepts, (b) déplacer vers manin-control-room/docs/ si c'est de la doc système, (c) relever le plafond du hook si croissance par design assumée, (d) override avec env JARVIS_MEMORY_GUARD_BYPASS=1."
  echo "[$(date)] BLOCK: size=${NEW_SIZE}B > ${MAX_FILE_SIZE}B — $FILE_PATH" >> "$LOG"
  jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
  exit 0
fi

echo "[$(date)] OK: $TOOL_NAME $BASENAME (count=$FUTURE_COUNT, size=${NEW_SIZE}B)" >> "$LOG"
exit 0

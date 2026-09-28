#!/bin/zsh
# jarvis-memory-guard — Hook PreToolUse anti-bloat sur Memory/ (Write|Edit|MultiEdit).
# Inspire du PreToolUse de seanchiuai/openclaude (cap 50 lignes sur MEMORY.md).
# Sort exit 0 silencieux si OK, sinon {"decision":"block","reason":…} sur stdout.
# Seuils, doctrine anti-drift (lessons.md §18) et perimetre : docs/garde-fous.md.
# Bypass anti-bloat : JARVIS_MEMORY_GUARD_BYPASS=1 (ne leve PAS la frontiere headless).
set -uo pipefail
JARVIS_VAULT="${JARVIS_VAULT:-$HOME/Documents/Obsidian/vault}"
JARVIS_REPO="${JARVIS_REPO:-$HOME/Documents/GIT PROD/manin-porunga}"
LOG="$HOME/.local/var/log/jarvis-memory-guard.log"
mkdir -p "${LOG:h}"
INPUT=$(cat)

TOOL_NAME=$(print -r -- "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(print -r -- "$INPUT" | jq -r '.tool_input.file_path // empty')
[[ "$TOOL_NAME" == (Write|Edit|MultiEdit) ]] || exit 0

block() { # block <tag-log> <raison-agent>
  print -r -- "[$(date)] BLOCK $1 — $FILE_PATH" >> "$LOG"
  jq -n --arg r "$2" '{decision:"block",reason:$r}'
  exit 0
}

# Frontiere headless — AVANT le bypass : un sous-processus non interactif ne doit
# jamais pouvoir elargir lui-meme son perimetre d ecriture.
if [[ -n "${JARVIS_HEADLESS_WRITE_ROOTS:-}" ]]; then
  if ! python3 - "$FILE_PATH" "$JARVIS_HEADLESS_WRITE_ROOTS" <<'PY'
import os, pathlib, sys
target = pathlib.Path(sys.argv[1]).expanduser().resolve(strict=False)
roots = [pathlib.Path(r).expanduser().resolve(strict=False) for r in sys.argv[2].split(os.pathsep) if r]
raise SystemExit(0 if any(target == r or r in target.parents for r in roots) else 1)
PY
  then
    block "HEADLESS" "Écriture headless hors périmètre bloquée : $FILE_PATH. Racines autorisées : $JARVIS_HEADLESS_WRITE_ROOTS"
  fi
fi

[[ "${JARVIS_MEMORY_GUARD_BYPASS:-0}" == "1" ]] && exit 0

# Cible : uniquement les .md a la RACINE de Memory/ (sous-dossiers _archives/,
# auto/, proposed/… laisses libres).
MEMORY_DIR="$JARVIS_VAULT/Claude/Memory"
[[ "$FILE_PATH" == "$MEMORY_DIR"/*.md && "$FILE_PATH" != "$MEMORY_DIR"/*/* ]] || exit 0
BASENAME="${FILE_PATH:t}"

# Whitelist : fichiers qui croissent par design. Passage libre, mais trace.
if [[ "$BASENAME" == (decisions.md|decisions-detail.md|decisions-archive.md|lessons.md|MEMORY.md|observations.md) ]]; then
  [[ -f "$FILE_PATH" ]] && print -r -- "[$(date)] WHITELIST: $BASENAME (size=$(wc -c < "$FILE_PATH" | tr -d ' ')B)" >> "$LOG"
  exit 0
fi

# Seuil 1 — nombre de fichiers .md a la racine (durci 2026-05-09).
MAX_FILES=14
COUNT=$(find "$MEMORY_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
[[ "$TOOL_NAME" == "Write" && ! -f "$FILE_PATH" ]] && COUNT=$((COUNT + 1))
(( COUNT > MAX_FILES )) && block "count=$COUNT > $MAX_FILES" \
  "Memory/ atteindrait $COUNT fichiers top-level (seuil: $MAX_FILES, durci 2026-05-09). Anti-drift actif (cf. lessons.md §18). Choisir : (a) consolider dans un fichier existant, (b) déplacer vers _archives/, (c) déplacer la doc technique vers docs/, (d) override avec env JARVIS_MEMORY_GUARD_BYPASS=1."

# Seuil 2 — taille projetee du fichier apres l ecriture.
CUR=0; [[ -f "$FILE_PATH" ]] && CUR=$(wc -c < "$FILE_PATH" | tr -d ' ')
case "$TOOL_NAME" in
  Write) NEW_SIZE=$(print -rn -- "$(print -r -- "$INPUT" | jq -r '.tool_input.content // empty')" | wc -c | tr -d ' ') ;;
  Edit)  NEW_SIZE=$(( CUR + $(print -rn -- "$(print -r -- "$INPUT" | jq -r '.tool_input.new_string // empty')" | wc -c | tr -d ' ')
                          - $(print -rn -- "$(print -r -- "$INPUT" | jq -r '.tool_input.old_string // empty')" | wc -c | tr -d ' ') )) ;;
  MultiEdit) NEW_SIZE=$(( CUR + $(print -r -- "$INPUT" | jq -r '[.tool_input.edits[] | (.new_string|length) - (.old_string|length)] | add // 0') )) ;;
esac

# 20 KB hors whitelist ; agents.md = doctrine vivante, plafond doux 30 KB (Leo
# 2026-06-04). Au-dela : audit/scission obligatoire, pas de croissance libre.
MAX_SIZE=20480
[[ "$BASENAME" == "agents.md" ]] && MAX_SIZE=30720
(( NEW_SIZE > MAX_SIZE )) && block "size=${NEW_SIZE}B > ${MAX_SIZE}B" \
  "$BASENAME atteindrait ~$((NEW_SIZE / 1024)) KB (seuil: $((MAX_SIZE / 1024)) KB). Probable drift de doc technique dans la mémoire cognitive (cf. lessons.md §18). Choisir : (a) scinder en plusieurs concepts, (b) déplacer vers docs/ si c'est de la doc système, (c) relever le plafond du hook si croissance par design assumée, (d) override avec env JARVIS_MEMORY_GUARD_BYPASS=1."

print -r -- "[$(date)] OK: $TOOL_NAME $BASENAME (count=$COUNT, size=${NEW_SIZE}B)" >> "$LOG"
exit 0

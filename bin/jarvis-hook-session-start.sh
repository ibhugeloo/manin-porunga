#!/bin/zsh
# jarvis-hook-session-start — Hook SessionStart Claude Code.
#
# 1. Filtre les sessions non-interactives (claude --print, scripts Jarvis)
# 2. Log détaillé pour debug
# 3. Register la session courante dans ~/.jarvis/active-sessions.json
# 4. Émet additionalContext listant les autres sessions actives

set -uo pipefail

if [[ "${JARVIS_TRACKER_RUNNING:-0}" == "1" ]]; then
  exit 0
fi
export JARVIS_TRACKER_RUNNING=1

ENGINE="$HOME/.local/bin/jarvis-active-sessions"
LOG="$HOME/.local/var/log/jarvis-active-sessions.log"
mkdir -p "$(dirname "$LOG")"

INPUT=$(cat)

# --- Filtre phantom sessions ----------------------------------------------
# Une session est "phantom" si elle est lancée par un script Jarvis (recap,
# brief, etc.) ou en mode --print/-p (non-interactif). On remonte la chaîne
# de processus pour détecter ce cas.
is_phantom() {
  local p=$PPID
  for i in 1 2 3 4 5 6; do
    [[ "$p" -le 1 ]] && return 1
    local cmd
    cmd=$(ps -p "$p" -o command= 2>/dev/null | head -1)
    [[ -z "$cmd" ]] && return 1
    case "$cmd" in
      *" --print"*|*" -p "*|*"jarvis-"*|*"claude-p-robust"*)
        return 0 ;;
    esac
    p=$(ps -p "$p" -o ppid= 2>/dev/null | tr -d ' ')
  done
  return 1
}

if is_phantom; then
  {
    echo "===================="
    echo "[$(date)] SessionStart SKIPPED (phantom: lancée par script Jarvis ou claude --print)"
    SID=$(printf '%s' "$INPUT" | jq -r '.session_id // "?"' 2>/dev/null)
    echo "  session_id=$SID  PPID=$PPID"
  } >> "$LOG"
  exit 0
fi

# --- Logging détaillé pour debug -------------------------------------------
{
  echo "===================="
  echo "[$(date)] SessionStart"
  echo "  hook PID=$$  PPID=$PPID"
  P=$PPID
  for i in 1 2 3 4 5; do
    [[ "$P" -le 1 ]] && break
    INFO=$(ps -p "$P" -o pid=,ppid=,tty=,command= 2>/dev/null | head -1)
    [[ -z "$INFO" ]] && break
    echo "  ancestor[$i]: $INFO"
    P=$(echo "$INFO" | awk '{print $2}')
  done
  echo "  payload:"
  printf '%s\n' "$INPUT" | jq -r '
    "    session_id="     + (.session_id // "?"),
    "    transcript="    + (.transcript_path // "?"),
    "    cwd="           + (.cwd // "?"),
    "    source="        + (.source // "?"),
    "    hook_event="    + (.hook_event_name // "?")
  ' 2>/dev/null || echo "    (jq parse failed: $INPUT)"
} >> "$LOG"

if [[ ! -x "$ENGINE" ]]; then
  echo "  engine missing: $ENGINE" >> "$LOG"
  exit 0
fi

# --- Action standard --------------------------------------------------------
printf '%s' "$INPUT" | "$ENGINE" register >> "$LOG" 2>&1 || true

CONTEXT=$(printf '%s' "$INPUT" | "$ENGINE" format-context 2>>"$LOG" || true)

# --- Dernier récap Leo (pont mémoire Leo -> Jarvis, cf. jarvis leo-sync) -----
# Injecte la dernière entrée de Brief/leo-feed.md SI elle date de <= 3 jours,
# pour que Jarvis sache ce qu'le boss a discuté avec Leo (Telegram). Garde de
# fraîcheur : pas de pollution si le feed est vieux.
LEO_FEED="$HOME/Documents/Obsidian/vault/Brief/leo-feed.md"
LEO_BLOCK=""
if [[ -f "$LEO_FEED" ]]; then
  EDATE=$(head -1 "$LEO_FEED" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
  EPOCH=0
  [[ -n "$EDATE" ]] && EPOCH=$(date -j -f "%Y-%m-%d" "$EDATE" +%s 2>/dev/null || echo 0)
  if (( EPOCH > 0 )); then
    AGE=$(( ( $(date +%s) - EPOCH ) / 86400 ))
    if (( AGE <= 3 )); then
      LATEST=$(awk '/^---$/{exit} {print}' "$LEO_FEED")
      [[ -n "$LATEST" ]] && LEO_BLOCK=$(printf '## Dernier récap Leo (échanges Telegram le boss <-> Leo)\n\n%s\n\nSource : Brief/leo-feed.md (jarvis leo-sync). Utilise-le pour rester synchro avec ce que le boss discute avec Leo.' "$LATEST")
    fi
  fi
fi

# --- additionalContext : sessions actives + dernier récap Leo ---------------
FULL="$CONTEXT"
if [[ -n "$LEO_BLOCK" ]]; then
  if [[ -n "$FULL" ]]; then FULL="$FULL"$'\n\n'"$LEO_BLOCK"; else FULL="$LEO_BLOCK"; fi
fi

if [[ -n "$FULL" ]]; then
  jq -n --arg ctx "$FULL" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
fi

exit 0

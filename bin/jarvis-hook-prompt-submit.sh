#!/bin/zsh
# jarvis-hook-prompt-submit — Hook UserPromptSubmit Claude Code.
# Filtre les phantom sessions, log détaillé, touch silencieux.

set -uo pipefail

if [[ "${JARVIS_TRACKER_RUNNING:-0}" == "1" ]]; then
  exit 0
fi
export JARVIS_TRACKER_RUNNING=1

ENGINE="$HOME/.local/bin/jarvis-active-sessions"
LOG="$HOME/.local/var/log/jarvis-active-sessions.log"
mkdir -p "$(dirname "$LOG")"

INPUT=$(cat)

# --- Filtre phantom sessions (cf. jarvis-hook-session-start.sh) ------------
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
  exit 0
fi

# --- Logging détaillé -----------------------------------------------------
{
  echo "===================="
  echo "[$(date)] UserPromptSubmit"
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
    "    session_id=" + (.session_id // "?"),
    "    cwd="        + (.cwd // "?"),
    "    prompt_len=" + ((.prompt // "") | length | tostring)
  ' 2>/dev/null || echo "    (jq parse failed)"
} >> "$LOG"

[[ -x "$ENGINE" ]] || exit 0

printf '%s' "$INPUT" | "$ENGINE" touch >> "$LOG" 2>&1 || true

# --- Boîte aux lettres : injecter les messages reçus ----------------------
MSG_BIN="$HOME/.local/bin/jarvis-msg"
if [[ -x "$MSG_BIN" ]]; then
  CTX=$(printf '%s' "$INPUT" | "$MSG_BIN" format-context 2>>"$LOG" || true)
  if [[ -n "$CTX" ]]; then
    jq -n --arg ctx "$CTX" \
      '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
  fi
fi

exit 0

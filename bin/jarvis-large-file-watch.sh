#!/usr/bin/env bash
# jarvis-large-file-watch.sh — wrapper bash pour le hook PostToolUse.
# Délègue toute la logique à jarvis-large-file-watch.py (parse JSON, cooldown,
# détection seuil, output additionalContext). Le hook ne bloque jamais.

set -uo pipefail

# Résoudre les symlinks (macOS BSD readlink n'a pas -f)
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
    target="$(readlink "$src")"
    case "$target" in
        /*) src="$target" ;;
        *)  src="$(dirname -- "$src")/$target" ;;
    esac
done
SCRIPT_DIR="$(cd -- "$(dirname -- "$src")" >/dev/null 2>&1 && pwd)"
PY_SCRIPT="$SCRIPT_DIR/jarvis-large-file-watch.py"

# Si le .py est manquant (cas exotique), on sort silencieusement
if [ ! -f "$PY_SCRIPT" ]; then
    exit 0
fi

# Lire stdin une fois pour la passer au script Python.
INPUT=$(cat)

printf '%s' "$INPUT" | /usr/bin/env python3 "$PY_SCRIPT"
exit $?

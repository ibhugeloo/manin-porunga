#!/usr/bin/env bash
# jarvis-bash-guard.sh — PreToolUse:Bash. Garde-fou comportemental heuristique.
#
# Bloque : les batchs d operations d etat git/gh chainees, et les commandes git
# destructives (push --force, reset --hard, clean -f, branch -D…). Fail-CLOSED :
# tout payload vide, malforme ou non verifiable est refuse. Une consultation
# prealable (git status/log) ne vaut PAS autorisation de detruire.
#
# Ce n est PAS une sandbox OS et cela ne neutralise pas du code obfusque.
# Contrat complet, couches et limites connues : docs/garde-fous.md.
#
# BYPASS EXPLICITE (UTILISATEUR UNIQUEMENT) : export JARVIS_GIT_GUARD_BYPASS=1

set -uo pipefail

# --- 1. Bypass explicite utilisateur ---
# Neutralise sous JARVIS_TELEGRAM_WRITE=1 : depuis Telegram, le boss n a pas de
# terminal pour poser ce bypass, donc un bypass present dans ce contexte ne peut
# venir que du sous-processus lui-meme. Un agent ne s auto-accorde pas un mandat.
if [[ "${JARVIS_GIT_GUARD_BYPASS:-0}" == "1" && "${JARVIS_TELEGRAM_WRITE:-0}" != "1" ]]; then
  exit 0
fi

# --- 2. Lecture du payload JSON (Fail-Closed) ---
PAYLOAD=$(cat 2>/dev/null || true)
if [[ -z "$PAYLOAD" ]]; then
  echo "🛑 jarvis-bash-guard: payload JSON manquant sur stdin (fail-closed)" >&2
  exit 2
fi

# --- 3. Analyse de la commande via Python (stdlib) ---
ANALYSIS=$(GUARD_PAYLOAD="$PAYLOAD" python3 - <<'PYEOF'
import sys, json, os, shlex

payload_raw = os.environ.get("GUARD_PAYLOAD", "")
try:
    data = json.loads(payload_raw)
except Exception as e:
    print(json.dumps({"error": f"JSON invalide: {e}"}))
    sys.exit(0)

tool_input = data.get("tool_input") or {}
cmd = tool_input.get("command")
if not cmd:
    print(json.dumps({"error": "tool_input.command manquant"}))
    sys.exit(0)

def strip_shell_comments(raw):
    result = []
    in_single = False
    in_double = False
    in_comment = False
    escape = False

    for i, ch in enumerate(raw):
        if in_comment:
            if ch == "\n":
                in_comment = False
                result.append("\n")
            continue

        if escape:
            result.append(ch)
            escape = False
            continue

        if ch == "\\" and not in_single:
            escape = True
            result.append(ch)
            continue

        if ch == "'" and not in_double:
            in_single = not in_single
            result.append(ch)
            continue

        if ch == '"' and not in_single:
            in_double = not in_double
            result.append(ch)
            continue

        if not in_single and not in_double and ch == "#":
            if i == 0 or raw[i - 1] in " \t\r\n;&|(":
                in_comment = True
                continue

        result.append(ch)

    return "".join(result)

# Parsing shell avec préservation stricte des séparateurs après commentaires
clean_cmd = strip_shell_comments(cmd)
try:
    lexer = shlex.shlex(clean_cmd, posix=True, punctuation_chars=True)
    lexer.whitespace = ' \t\r'  # Conserver \n comme token de séparation
    lexer.commenters = ''       # Commentaires préalablement nettoyés sans perte de \n
    raw_tokens = list(lexer)
except Exception as e:
    print(json.dumps({"error": f"Syntaxe shell non vérifiable: {e}"}))
    sys.exit(0)

# Séparateurs de commandes et délimiteurs de blocs conditionnels
BLOCK_DELIMITERS = {";", "\n", "&&", "||", "|", "&", "(", ")", "then", "else", "elif", "do", "done", "fi", "esac", "{", "}"}
PREFIXES = {"if", "while", "until", "for", "select", "time", "!", "then", "else", "elif", "do"}
WRAPPERS = {"env", "time", "sudo", "noglob", "builtin", "command", "exec"}

# Découper en instructions / commandes individuelles
commands = []
curr = []
for tok in raw_tokens:
    if tok in BLOCK_DELIMITERS:
        if curr:
            commands.append(curr)
            curr = []
    else:
        curr.append(tok)
if curr:
    commands.append(curr)

mutating_calls = []
destructive_calls = []

for c in commands:
    k = 0
    # Sauter les variables d'environnement en préfixe, mots-clés de contrôle et wrappers
    while k < len(c):
        tok = c[k]
        if "=" in tok and not tok.startswith("-"):
            k += 1
        elif tok in PREFIXES or tok in WRAPPERS:
            k += 1
        else:
            break

    if k >= len(c):
        continue

    tool = c[k]
    k += 1

    if tool == "git":
        subcmd = None
        args = []
        # Sauter les options globales git
        while k < len(c):
            arg = c[k]
            if arg in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix"):
                k += 2
            elif arg.startswith("-"):
                k += 1
            else:
                subcmd = arg
                k += 1
                break
        args = c[k:]

        if subcmd:
            # Opération mutante
            if subcmd in ("commit", "push", "merge", "rebase", "reset"):
                mutating_calls.append(f"git {subcmd}")

            # Opération destructive
            is_destr = False
            # push : force explicite, refspec forcee (+src:dst — le lexer isole
            # le "+" en token propre), ou suppression/ecrasement de refs distantes.
            if subcmd == "push" and any(
                a in ("--force", "-f", "--mirror", "--delete", "-d")
                or a.startswith("--force-with-lease")
                or a.startswith("--force-if-includes")
                or a.startswith("+")
                for a in args
            ):
                is_destr = True
            elif subcmd == "reset" and "--hard" in args:
                is_destr = True
            elif subcmd == "clean" and any(a in ("-f", "--force") or (a.startswith("-") and "f" in a) for a in args):
                is_destr = True
            elif subcmd == "branch" and any(a in ("-D",) or ("--delete" in args and "--force" in args) for a in args):
                is_destr = True
            elif subcmd in ("checkout", "restore") and ("--" in args or "." in args):
                is_destr = True
            elif subcmd == "rebase" and any(a in ("-i", "--interactive") for a in args):
                is_destr = True
            elif subcmd == "commit" and "--amend" in args:
                is_destr = True

            if is_destr:
                destructive_calls.append(f"git {subcmd} " + " ".join(args))

    elif tool == "gh":
        gh_args = c[k:]
        if len(gh_args) >= 2 and gh_args[0] == "pr" and gh_args[1] in ("create", "merge"):
            mutating_calls.append(f"gh pr {gh_args[1]}")

print(json.dumps({
    "cmd": cmd,
    "mutating_count": len(mutating_calls),
    "mutating_calls": mutating_calls,
    "destructive_calls": destructive_calls
}))
PYEOF
)

# --- 4. Interprétation du résultat d'analyse (jq : 1 process, pas 5) ---
# L ancienne version relançait python3 cinq fois sur le meme JSON — l essentiel
# du cout du hook. jq est deja un prerequis du socle. Fail-closed preserve :
# un JSON illisible n est pas traite comme "rien a signaler".
if [[ -z "$ANALYSIS" ]] || ! jq -e . >/dev/null 2>&1 <<< "$ANALYSIS"; then
  echo "🛑 jarvis-bash-guard: échec de l'analyseur interne (fail-closed)" >&2
  exit 2
fi

ERROR_MSG=$(jq -r '.error // ""' <<< "$ANALYSIS")
if [[ -n "$ERROR_MSG" ]]; then
  echo "🛑 jarvis-bash-guard: $ERROR_MSG (fail-closed)" >&2
  exit 2
fi

MUTATING_COUNT=$(jq -r '.mutating_count // 0' <<< "$ANALYSIS")
DESTRUCTIVE_COUNT=$(jq -r '(.destructive_calls // []) | length' <<< "$ANALYSIS")
CMD=$(jq -r '.cmd // ""' <<< "$ANALYSIS")

# --- 4.bis GARDE-FOU 0 : publication depuis Telegram (mode ecriture distant) ---
# Sur le canal Telegram, le boss ne voit ni diff ni sortie de commande : il ne peut
# pas valider un push a l ecran. La publication ne doit donc pas dependre du
# jugement du modele — elle passe par la commande /push, tapee par le boss.
if [[ "${JARVIS_TELEGRAM_WRITE:-0}" == "1" ]]; then
  # On reutilise l analyseur (tokenise, gere `git -C <dir> push`) plutot qu une
  # regex de surface : les options globales git ne doivent pas servir d evasion.
  PUBLISH_CALLS=$(jq -r '[(.mutating_calls // [])[] | select(. == "git push" or . == "gh pr create" or . == "gh pr merge")] | join(", ")' <<< "$ANALYSIS")
  if [[ -n "$PUBLISH_CALLS" ]]; then
    cat >&2 <<EOF
🛑 jarvis-bash-guard — GARDE-FOU 0 : publication interdite depuis Telegram.

Commande interceptée : $CMD
Opération de publication détectée : $PUBLISH_CALLS

Ce canal est mobile : le boss ne peut ni relire un diff ni valider une sortie à
l'écran. Conformément à jarvis_soul.md §Action et autorité, push, merge et
release exigent une validation humaine explicite couvrant l'action.

Le commit local reste autorisé (pathspec explicite). Pour publier, demandez au
boss de taper la commande **/push** dans le fil Telegram — c'est son acte,
pas le vôtre.
EOF
    exit 2
  fi
fi

# --- 5. GARDE-FOU 1 : Batch d'opérations d'état mutantes interdit ---
if [[ "$MUTATING_COUNT" -ge 2 ]]; then
  cat >&2 <<EOF
🛑 jarvis-bash-guard — GARDE-FOU 1 : batch de commandes git/gh mutantes bloqué.

Commande interceptée : $CMD

Cette commande chaîne $MUTATING_COUNT opérations d'état mutantes. C'est INTERDIT :
chaque opération change l'état que la suivante lit. Les enchaîner produit des
résultats désordonnés et des états hallucinés (incident 2026-05-30, lessons.md #24).

RÈGLE : opérations git/prod = UNE commande à la fois, puis une vérification
isolée (git status / git log) avant la suivante. Jamais en batch.

Découpe en commandes séparées et vérifie entre chacune.

Bypass (cas légitime validé manuellement) :
  export JARVIS_GIT_GUARD_BYPASS=1
EOF
  exit 2
fi

# --- 6. GARDE-FOU 2 : Commandes destructives / irréversibles ---
if [[ "$DESTRUCTIVE_COUNT" -ge 1 ]]; then
  DESTR_DETAILS=$(jq -r '(.destructive_calls // []) | join(", ")' <<< "$ANALYSIS")
  cat >&2 <<EOF
🛑 jarvis-bash-guard — GARDE-FOU 2 : commande git destructive bloquée.

Commande interceptée : $CMD
Opération destructive détectée : $DESTR_DETAILS

Cette opération est destructive ou irréversible (push --force, reset --hard, clean -f, branch -D, etc.).
Conformément à jarvis_soul.md §Action et autorité, une opération destructive exige une
validation humaine explicite couvrant l'action. Une simple lecture préalable de l'état
(git status ou git log) ne constitue EN AUCUN CAS un consentement pour détruire.

Pour exécuter cette commande sous mandat explicite du boss :
  export JARVIS_GIT_GUARD_BYPASS=1
EOF
  exit 2
fi

# Commande légitime autorisée
exit 0

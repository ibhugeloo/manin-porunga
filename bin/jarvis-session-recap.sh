#!/bin/zsh
# jarvis-session-recap — Hook SessionEnd qui génère un récap structuré de la session.
# Lit l'input JSON Claude Code sur stdin, demande à Haiku de synthétiser le transcript,
# écrit dans ~/Documents/Obsidian/vault/Claude/Sessions/

set -uo pipefail

# Garde anti-récursion : quand ce script appelle `claude -p` pour générer le récap,
# cette sous-session déclenche elle-même un SessionEnd → re-rentrée. Stop.
if [[ "${JARVIS_RECAP_RUNNING:-0}" == "1" ]]; then
  exit 0
fi
export JARVIS_RECAP_RUNNING=1

CLAUDE_BIN="$HOME/.local/bin/claude"
SESSIONS_DIR="$HOME/Documents/Obsidian/vault/Claude/Sessions"
LOG="$HOME/.local/var/log/jarvis-session-recap.log"

mkdir -p "$SESSIONS_DIR"
mkdir -p "$(dirname "$LOG")"

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# Lire l'input JSON du hook depuis stdin
INPUT=$(cat)

TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
REASON=$(printf '%s' "$INPUT" | jq -r '.reason // empty')

DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%H%M)
SHORT_ID=$(printf '%s' "$SESSION_ID" | head -c 8)

# ---------------------------------------------------------------------------
# Désenregistrer la session du registre des sessions actives — DÈS LE DÉBUT,
# avant toute commande qui pourrait planter (claude --print, jq, etc.) et
# laisser une session orpheline dans le registre.
# (cf. bin/jarvis-active-sessions et feedback_sessions_paralleles.md)
#
# Exception : reason="manual_save" → la session est encore vivante (sauvegarde
# à la volée déclenchée par /save), on ne la désinscrit pas.
# ---------------------------------------------------------------------------
if [[ -x "$HOME/.local/bin/jarvis-active-sessions" ]] && [[ -n "$SESSION_ID" ]] && [[ "$REASON" != "manual_save" ]]; then
  printf '%s' "$INPUT" | "$HOME/.local/bin/jarvis-active-sessions" unregister >> "$LOG" 2>&1 || true
fi

{
  echo ""
  echo "===================="
  echo "[$(date)] SessionEnd — session=$SESSION_ID reason=$REASON cwd=$CWD"
} >> "$LOG"

# Garde-fou : opt-out par session — si un flag ~/.jarvis/recap-skip/<id> existe,
# on ne génère NI n'écrit NI ne push cette session (ex : session contenant un
# secret collé en clair qu'on ne veut pas voir partir dans Sessions/ + Notion +
# GitHub). Le flag est consommé (supprimé) après usage.
SKIP_FLAG="$HOME/.jarvis/recap-skip/$SESSION_ID"
if [[ -n "$SESSION_ID" && -f "$SKIP_FLAG" ]]; then
  echo "[$(date)] Opt-out flag présent pour $SESSION_ID — pas de récap/push" >> "$LOG"
  rm -f "$SKIP_FLAG"
  exit 0
fi

# Garde-fou : transcript existant
if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
  echo "[$(date)] No transcript at '$TRANSCRIPT_PATH', skipping" >> "$LOG"
  exit 0
fi

# Garde-fou : skip les sessions triviales (< 8 lignes JSONL ≈ < 4 échanges)
LINES=$(wc -l < "$TRANSCRIPT_PATH")
if [[ $LINES -lt 8 ]]; then
  echo "[$(date)] Transcript trivial ($LINES lignes), skipping" >> "$LOG"
  exit 0
fi

# =============================================================================
# Détachement en arrière-plan : tout le travail lourd (Haiku, écriture fichier,
# push Notion, skill, observation) part dans un sous-shell `{ ... } &` que l'on
# `disown`. Conséquence : le `/exit` côté terminal est INSTANTANÉ, plus aucun
# risque de timeout côté hook Claude Code (60s par défaut), même sur des
# transcripts massifs où Haiku peut prendre une minute.
#
# Le `trap EXIT` interne loggue toujours un `DONE — status=... duration=...s`
# final, quel que soit le chemin de sortie (succès, skip, erreur). Permet
# d'auditer chaque session a posteriori dans le log.
# =============================================================================
{
  WORKER_START_EPOCH=$(date +%s)
  WORKER_STATUS="UNKNOWN"
  WORKER_OUTPUT_FILE=""
  trap 'echo "[$(date)] DONE — session=$SHORT_ID status=$WORKER_STATUS duration=$(($(date +%s)-WORKER_START_EPOCH))s file=${WORKER_OUTPUT_FILE:-none}" >> "$LOG"' EXIT

# Limiter le transcript pour ne pas exploser le contexte Haiku.
# Borner en OCTETS, pas en lignes : une ligne JSONL peut peser plusieurs Mo
# (tool_result avec screenshots base64, dumps de fichiers, etc.). Compter les
# lignes ne protège donc pas contre "Prompt is too long".
# Stratégie : extraction jq des champs utiles (role + texte), avec écrasement
# des contenus volumineux (>4 KB par bloc) par un placeholder. Filet de
# sécurité octets en cas de jq absent ou de transcript exotique.
BYTES=$(wc -c < "$TRANSCRIPT_PATH" | tr -d ' ')
MAX_BYTES=60000

if command -v jq >/dev/null 2>&1; then
  # Extrait par ligne JSONL : le rôle + le contenu textuel (les tool_use et
  # tool_result longs sont tronqués à 800 caractères pour garder l'intention
  # sans saturer le contexte avec des dumps).
  TRANSCRIPT_CONTENT=$(jq -r '
    def trunc(n): if (.|length) > n then (.[:n] + "… [tronqué]") else . end;
    . as $msg
    | (.message.role // .role // .type // "?") as $role
    | (.message.content // .content) as $c
    | if ($c | type) == "string" then
        "[\($role)] " + ($c | trunc(2000))
      elif ($c | type) == "array" then
        "[\($role)] " + (
          $c | map(
            if .type == "text" then (.text // "" | trunc(2000))
            elif .type == "tool_use" then "<tool_use:\(.name // "?")> " + ((.input // {} | tostring) | trunc(400))
            elif .type == "tool_result" then "<tool_result> " + (
              if (.content | type) == "array" then
                (.content | map(.text // "") | join(" ") | trunc(800))
              else
                ((.content // "") | tostring | trunc(800))
              end
            )
            elif .type == "image" then "<image omis>"
            else "<\(.type // "?")>"
            end
          ) | join(" | ")
        )
      else
        "[\($role)] " + (($c // "" | tostring) | trunc(2000))
      end
  ' "$TRANSCRIPT_PATH" 2>/dev/null)
fi

# Fallback / sécurité octets : si jq a échoué ou si la sortie reste trop grosse.
if [[ -z "${TRANSCRIPT_CONTENT:-}" ]]; then
  if [[ "$BYTES" -le "$MAX_BYTES" ]]; then
    TRANSCRIPT_CONTENT=$(cat "$TRANSCRIPT_PATH")
  else
    TRANSCRIPT_HEAD=$(head -c 20000 "$TRANSCRIPT_PATH")
    TRANSCRIPT_TAIL=$(tail -c 40000 "$TRANSCRIPT_PATH")
    TRANSCRIPT_CONTENT="$TRANSCRIPT_HEAD

[... ${BYTES} octets au total (${LINES} lignes), milieu omis ...]

$TRANSCRIPT_TAIL"
  fi
fi

# Cap final octets — quoi qu'il arrive, on coupe à MAX_BYTES.
EXTRACT_BYTES=$(printf '%s' "$TRANSCRIPT_CONTENT" | wc -c | tr -d ' ')
if [[ "$EXTRACT_BYTES" -gt "$MAX_BYTES" ]]; then
  TRANSCRIPT_HEAD=$(printf '%s' "$TRANSCRIPT_CONTENT" | head -c 20000)
  TRANSCRIPT_TAIL=$(printf '%s' "$TRANSCRIPT_CONTENT" | tail -c 40000)
  TRANSCRIPT_CONTENT="$TRANSCRIPT_HEAD

[... extraction de ${EXTRACT_BYTES} octets, tronquée à ${MAX_BYTES} pour Haiku ...]

$TRANSCRIPT_TAIL"
fi

# Garde-fou : si claude binary absent
if [[ ! -x "$CLAUDE_BIN" ]]; then
  echo "[$(date)] ERROR: claude binary not at $CLAUDE_BIN" >> "$LOG"
  WORKER_STATUS="ERROR_NO_CLAUDE_BIN"
  exit 0
fi

# --- Contexte cross-session pour permettre l'évaluation "3+ occurrences" ---
# Sans ce contexte, le LLM ne voit que la session courante et ne peut pas
# justifier la condition de seuil → auto/ reste sous-utilisé.
OBSERVATIONS_FILE="$HOME/Documents/Obsidian/vault/Claude/Memory/observations.md"
SESSIONS_DIR="$HOME/Documents/Obsidian/vault/Claude/Sessions"

CROSS_SESSION_CONTEXT=""
if [[ -f "$OBSERVATIONS_FILE" ]]; then
  # 5 dernières observations (chacune ~150-300 mots)
  RECENT_OBS=$(tail -c 8000 "$OBSERVATIONS_FILE" 2>/dev/null)
  CROSS_SESSION_CONTEXT="## Observations user-model récentes (pour évaluer si un pattern est récurrent)
$RECENT_OBS

"
fi

if [[ -d "$SESSIONS_DIR" ]]; then
  # Titres + 'À retenir' des 5 derniers récaps de session
  RECENT_SESSIONS=$(ls -t "$SESSIONS_DIR"/*.md 2>/dev/null | head -5 | while read -r f; do
    echo "### $(basename "$f")"
    grep -A2 -E '^# Session|^## À retenir' "$f" 2>/dev/null | head -20
    echo ""
  done)
  CROSS_SESSION_CONTEXT="$CROSS_SESSION_CONTEXT## Récaps de session récents (5 derniers)
$RECENT_SESSIONS

"
fi

PROMPT="Tu es Jarvis, le majordome du boss. Tu dois résumer une session Claude Code qui vient de se terminer, pour qu'une session future puisse reprendre le fil.

# Contexte cross-session (à utiliser pour évaluer la récurrence des patterns avant d'écrire un skill ou une observation)

$CROSS_SESSION_CONTEXT
---


Lis le transcript JSONL ci-dessous (chaque ligne = un événement de conversation) et produis un récap au format Markdown ci-dessous. Ton concis, factuel, vouvoiement absent (c'est un mémo interne, pas un message au boss). Pas d'emoji.

# Format strict de sortie

\`\`\`markdown
---
date: $DATE
heure_fin: $(date +%H:%M)
projet: $CWD
session_id: $SESSION_ID
---

# Session $DATE — <sujet principal en 5-8 mots>

## Contexte
1-2 lignes sur le pourquoi de la session.

## Ce qui a été fait
- bullet (action concrète, mentionner le fichier touché si pertinent)
- bullet
- bullet

## Décisions clés
- bullet (uniquement si décisions structurantes ; sinon _RAS_)

## Fichiers touchés (création / édition significative)
- \`chemin/fichier.ext\`
- \`chemin/fichier.ext\`

## Reste à faire (si applicable)
- [ ] action ouverte
- [ ] action ouverte

## À retenir pour les prochaines sessions
2-3 lignes max — patterns, conventions, gotchas découverts. Sinon _RAS_.
\`\`\`

# Bloc OPTIONNEL 1 : skill auto-écrit (style Hermes — sans demande de validation)

Si la session a abouti à une **résolution non triviale** (5+ tool calls réussis, ou correction d'une erreur, ou pattern qui mérite réutilisation), ajoute APRÈS le récap principal un second bloc Markdown séparé par \`<<<SKILL>>>\` :

\`\`\`
<<<SKILL>>>
---
name: <nom-court-kebab-case>
auto: true
trigger: <quand cette règle/skill s'applique — 1 ligne>
---

# <Titre du skill>

## Pourquoi
1-3 lignes : la situation qui a fait émerger ce pattern.

## Procédure / règle
- Étape ou règle concrète
- Étape ou règle concrète

## Code / commande type (si applicable)
\\\`\\\`\\\`
<exemple minimal>
\\\`\\\`\\\`

## Anti-patterns à éviter
- Ce qui ne marche pas et pourquoi
\`\`\`

**Quand écrire un skill** :
- le boss a résolu un problème nouveau réutilisable
- Une convention a émergé (nommage, workflow, choix d'outil)
- Un pattern shell/Python est apparu 3+ fois

**Quand NE PAS écrire** :
- Session courte (< 5 tool calls)
- Déjà couvert par jarvis_soul.md / decisions.md / un fichier feedback_*.md
- Trop spécifique au contexte du jour, non généralisable

Si aucun skill ne mérite : pas de bloc \`<<<SKILL>>>\`.

# Bloc OPTIONNEL 2 : observation user-model (style Hermes evolving user model)

Si la session révèle une **préférence ou un pattern du boss** non encore documenté dans \`profil.md\` / \`jarvis_soul.md\` / \`feedback_*.md\`, ajoute un 3e bloc séparé par \`<<<OBSERVATION>>>\` :

\`\`\`
<<<OBSERVATION>>>
---
date: $DATE
session_id: $SESSION_ID
confidence: low | medium | high
---

**Pattern observé** : <description en 1-2 lignes>

**Indices** : <2-3 signaux concrets relevés dans le transcript>

**Si validé, à promouvoir vers** : profil.md / feedback_<sujet>.md / jarvis_soul.md
\`\`\`

**Quand observer** :
- Préférence d'outil exprimée 2+ fois (ex: \"toujours Coolify pour le déploiement\")
- Convention de nommage apparue 3+ fois
- Refus / agacement explicite vis-à-vis d'une approche (à éviter à l'avenir)
- Contrainte personnelle révélée (santé, planning, sensibilité)

**Quand NE PAS observer** :
- Pattern déjà documenté
- Choix unique non répété (peut être ponctuel)
- Confidence < low (devine)

\`confidence\` : \`high\` = explicite et répété, \`medium\` = implicite mais cohérent, \`low\` = inférence prudente.

Si rien à observer : pas de bloc \`<<<OBSERVATION>>>\`.

Règles strictes :
- Pas de blabla, pas de phrases d'introduction. Démarre directement par le frontmatter \`---\`.
- Si une section n'a rien à dire, écrire \`_RAS_\`.
- Le titre doit refléter le **vrai objectif** de la session, pas la première chose dite.
- N'invente rien. Si tu n'es pas sûr d'un détail, omets.
- Renvoie uniquement le Markdown du récap (et optionnellement le bloc skill séparé par <<<SKILL>>>), rien avant ni après.

Transcript :

$TRANSCRIPT_CONTENT"

# Génération du récap via Haiku
RECAP=$(printf '%s' "$PROMPT" | "$CLAUDE_BIN" --print --model haiku --output-format text 2>>"$LOG")

if [[ -z "$RECAP" ]]; then
  echo "[$(date)] Empty recap, skipping" >> "$LOG"
  WORKER_STATUS="ERROR_EMPTY_RECAP"
  exit 0
fi

# Détection des erreurs Haiku qui sortent en stdout (texte court non-Markdown).
# Ex : "Prompt is too long" → le script écrivait ce message comme s'il s'agissait
# d'un récap valide, polluant le widget. Si la sortie est trop courte ou ne
# contient pas le frontmatter attendu, on log et on skip proprement.
RECAP_LEN=$(printf '%s' "$RECAP" | wc -c | tr -d ' ')
if [[ "$RECAP_LEN" -lt 80 ]] || ! printf '%s' "$RECAP" | grep -q '^---$'; then
  echo "[$(date)] ERROR: récap invalide (${RECAP_LEN} octets, frontmatter absent) — sortie Haiku : $(printf '%s' "$RECAP" | head -c 200)" >> "$LOG"
  WORKER_STATUS="ERROR_INVALID_RECAP"
  exit 0
fi

# Séparer le récap principal du skill auto et de l'observation user-model
SKILL_AUTO=""
OBSERVATION=""

if printf '%s' "$RECAP" | grep -q '<<<OBSERVATION>>>'; then
  OBSERVATION=$(printf '%s' "$RECAP" | awk '/<<<OBSERVATION>>>/{flag=1; next} flag')
  RECAP=$(printf '%s' "$RECAP" | awk '/<<<OBSERVATION>>>/{exit} {print}')
fi

if printf '%s' "$RECAP" | grep -q '<<<SKILL>>>'; then
  SKILL_AUTO=$(printf '%s' "$RECAP" | awk '/<<<SKILL>>>/{flag=1; next} flag')
  RECAP=$(printf '%s' "$RECAP" | awk '/<<<SKILL>>>/{exit} {print}')
fi

# Nettoyer un éventuel ```markdown wrapper sur le récap
RECAP=$(printf '%s' "$RECAP" | sed -e 's/^```markdown$//' -e 's/^```$//' | awk 'NF || prev{print; prev=NF}' )

# Extraire le titre H1 et le slugifier en ASCII (python3 pour la dé-accentuation, dispo sur macOS)
TOPIC=$(printf '%s' "$RECAP" \
  | grep -m 1 '^# Session' \
  | sed 's/^# Session [0-9-]* — //' \
  | /usr/bin/python3 -c "import sys, unicodedata, re
t = sys.stdin.read().strip().lower()
t = unicodedata.normalize('NFD', t)
t = ''.join(c for c in t if unicodedata.category(c) != 'Mn')
t = re.sub(r'[^a-z0-9 -]', '', t)
t = re.sub(r'\s+', '-', t).strip('-')
print(t[:50])" 2>/dev/null)
[[ -z "$TOPIC" ]] && TOPIC="session"

OUTPUT_FILE="$SESSIONS_DIR/${DATE}-${TIMESTAMP}-${SHORT_ID}-${TOPIC}.md"

printf '%s\n' "$RECAP" > "$OUTPUT_FILE"

WORKER_STATUS="OK"
WORKER_OUTPUT_FILE="$OUTPUT_FILE"

echo "[$(date)] Recap written: $OUTPUT_FILE ($(wc -l < "$OUTPUT_FILE") lignes)" >> "$LOG"

# ---------------------------------------------------------------------------
# Auto-critique §5 — auto-critique sur les sessions touchant un projet client.
# Corrections 2026-05-28 (suite eval 2026-05-26 — 80 % de bruit) :
#  - Nom de projet extrait du CWD (plus de hardcode example-app).
#  - Whitelist explicite des projets clients facturables.
#  - Dédup par session_id : une session compte au plus 1 fois, peu importe
#    le nombre de reprises de thread (avant : 22 entrées pour 8 sessions).
#  - Filtre code-only : exige ≥ 1 tool call Edit/Write/MultiEdit. Les sessions
#    de discussion (tarification, README, comparaison pricing) ne sont plus
#    flaguées (avant : faux positifs systématiques).
#  - Sortie dans log dédié (~/.local/var/log/autocritique.log), PLUS dans
#    observations.md (la règle vit déjà en HOT dans SOUL §5, l'observation
#    n'est jamais promouvable et noie les vrais patterns).
# ---------------------------------------------------------------------------
AUTOCRIT_LOG="$HOME/.local/var/log/autocritique.log"
AUTOCRIT_SEEN="$HOME/.local/var/jarvis-autocritique-seen.txt"
STREAK_FILE="$HOME/.local/var/jarvis-autocritique-streak.txt"
mkdir -p "$(dirname "$AUTOCRIT_LOG")"
mkdir -p "$(dirname "$STREAK_FILE")"
touch "$AUTOCRIT_SEEN"

# Extraction du nom de projet à partir du CWD uniquement (jamais via transcript
# grep qui produit des faux positifs). Gère la réorg sous-workspaces du
# 2026-05-24 où les projets clients vivent dans `GIT PROD/<workspace>/<projet>/`
# (ex: `GIT PROD/client/example-app/`, `GIT PROD/agency/agency-app/`). On scanne
# les 2 premiers segments après `GIT PROD/` et on match contre la whitelist.
SCOPE_CLIENT=""
if [[ "$CWD" == *"/GIT PROD/"* ]]; then
  # Extraire le path après "GIT PROD/" puis tester les 2 premiers segments.
  tail_path=$(printf '%s' "$CWD" | sed -nE 's|.*/GIT PROD/(.*)|\1|p')
  seg1=$(printf '%s' "$tail_path" | cut -d/ -f1)
  seg2=$(printf '%s' "$tail_path" | cut -d/ -f2)
  for candidate in "$seg1" "$seg2"; do
    case "$candidate" in
      example-app|example-intake|example-fleet|example-intranet|agency-app|agency-site|shop-app|portfolio-site)
        SCOPE_CLIENT="$candidate"
        break
        ;;
    esac
  done
fi

if [[ -n "$SCOPE_CLIENT" ]]; then
  # Dédup : skip si cette session_id a déjà été évaluée par Auto-critique §5.
  if [[ -n "$SESSION_ID" ]] && grep -qF "$SESSION_ID" "$AUTOCRIT_SEEN" 2>/dev/null; then
    echo "[$(date)] Auto-critique Â§5 skip — session $SHORT_ID déjà évaluée sur $SCOPE_CLIENT" >> "$LOG"
  # Filtre code-only : la session doit avoir produit ≥ 1 tool call de modif.
  elif ! grep -qE '"name":"(Edit|Write|MultiEdit|NotebookEdit)"' "$TRANSCRIPT_PATH" 2>/dev/null; then
    echo "[$(date)] Auto-critique Â§5 skip — session $SHORT_ID sans modif code sur $SCOPE_CLIENT (discussion/lecture)" >> "$LOG"
    [[ -n "$SESSION_ID" ]] && echo "$SESSION_ID" >> "$AUTOCRIT_SEEN"
  else
    AUTOCRIT_RESULT="miss"
    if grep -qiE 'auto[- ]critique|qu.?est.?ce qui peut casser' "$OUTPUT_FILE"; then
      AUTOCRIT_RESULT="ok"
      PREV=$(cat "$STREAK_FILE" 2>/dev/null || echo 0)
      NEW=$((PREV + 1))
      echo "$NEW" > "$STREAK_FILE"
      echo "[$(date)] Auto-critique Â§5 OK — $SCOPE_CLIENT session=$SHORT_ID streak=$NEW" >> "$AUTOCRIT_LOG"
      if [[ "$NEW" -ge 3 ]] && [[ "$PREV" -lt 3 ]]; then
        echo "[$(date)] Auto-critique — 3 sessions client d'affilée avec auto-critique" >> "$AUTOCRIT_LOG"
        [[ -x "$HOME/.local/bin/jarvis-notify" ]] && \
          "$HOME/.local/bin/jarvis-notify" "✅ Auto-critique — 3 sessions client d'affilée OK" 2>/dev/null || true
      fi
    else
      echo "0" > "$STREAK_FILE"
      echo "[$(date)] Auto-critique Â§5 MISS — $SCOPE_CLIENT session=$SHORT_ID cwd=$CWD (streak reset)" >> "$AUTOCRIT_LOG"

      # Nudge en queue du récap (repris par le push Notion). Plus d'écriture
      # dans observations.md — la règle vit dans SOUL §5, l'observation y
      # polluait sans jamais devenir promouvable (cf. eval 2026-05-26).
      {
        echo ""
        echo "---"
        echo ""
        echo "## ⚠️ Auto-critique manquante (SOUL §5)"
        echo ""
        echo "Cette session a touché le projet client **$SCOPE_CLIENT** mais le récap n'inclut pas de section auto-critique (SOUL §5)."
        echo ""
        echo "Avant tout claim *\"prêt à tester\"*, produire :"
        echo "- Liste des risques 🔴 critique / 🟡 à surveiller / 🟢 mineur"
        echo "- Ce qui est fixé maintenant avant que vous testiez"
        echo "- Ce qui demande de la vigilance opérationnelle au déploiement"
        echo ""
        echo "_Streak Auto-critique §5 reseté à 0._"
      } >> "$OUTPUT_FILE"

      # Push Telegram pour visibilité immédiate.
      [[ -x "$HOME/.local/bin/jarvis-msg" ]] && \
        "$HOME/.local/bin/jarvis-msg" "🟡 Auto-critique §5 — session $SCOPE_CLIENT sans auto-critique (streak reset)" 2>/dev/null || true
    fi

    [[ -n "$SESSION_ID" ]] && echo "$SESSION_ID" >> "$AUTOCRIT_SEEN"
  fi
fi

# Push Notion en arrière-plan (fire-and-forget) — toutes les sessions sont
# sauvegardées dans Inbox Jarvis. Le tri se fait à l'audit mensuel.
# nohup + & → détaché du parent, ne bloque pas la fin de session.
PUSH_BIN="$HOME/.local/bin/jarvis-notion-session-push.sh"
if [[ -x "$PUSH_BIN" ]]; then
  nohup "$PUSH_BIN" "$OUTPUT_FILE" >/dev/null 2>&1 &
  disown 2>/dev/null || true
  echo "[$(date)] Notion push lancé en background (pid=$!)" >> "$LOG"
else
  echo "[$(date)] WARN : $PUSH_BIN absent — pas de push Notion" >> "$LOG"
fi

# Skill auto-écrit (sans validation le boss) → Memory/auto/
if [[ -n "$SKILL_AUTO" ]]; then
  AUTO_DIR="$HOME/Documents/Obsidian/vault/Claude/Memory/auto"
  mkdir -p "$AUTO_DIR"

  SKILL_NAME=$(printf '%s' "$SKILL_AUTO" | grep -m 1 '^name:' | sed 's/^name:[[:space:]]*//' | tr -d '"' | tr -d "'" | head -c 60)
  SKILL_NAME=$(printf '%s' "$SKILL_NAME" | /usr/bin/python3 -c "import sys, unicodedata, re
t = sys.stdin.read().strip().lower()
t = unicodedata.normalize('NFD', t)
t = ''.join(c for c in t if unicodedata.category(c) != 'Mn')
t = re.sub(r'[^a-z0-9 -]', '', t)
t = re.sub(r'\s+', '-', t).strip('-')
print(t[:50])" 2>/dev/null)
  [[ -z "$SKILL_NAME" ]] && SKILL_NAME="auto-skill-${SHORT_ID}"

  SKILL_FILE="$AUTO_DIR/${DATE}-${SKILL_NAME}.md"
  printf '%s\n' "$SKILL_AUTO" > "$SKILL_FILE"

  echo "[$(date)] Skill auto-écrit : $SKILL_FILE" >> "$LOG"

  if [[ -x "$HOME/.local/bin/jarvis-notify" ]]; then
    "$HOME/.local/bin/jarvis-notify" "🤖 Skill auto-créé : $(basename "$SKILL_FILE" .md)
Memory/auto/ — review au prochain audit mensuel" --silent 2>/dev/null || true
  fi
fi

# Observation user-model → Memory/observations.md (append-only)
if [[ -n "$OBSERVATION" ]]; then
  OBS_FILE="$HOME/Documents/Obsidian/vault/Claude/Memory/observations.md"

  if [[ ! -f "$OBS_FILE" ]]; then
    cat > "$OBS_FILE" <<'HEADER'
# Observations user-model — auto-détectées

Patterns/préférences détectés automatiquement par le hook session-recap.
Append-only : ne pas réécrire l'historique. À reviewer mensuellement (routine eval) pour promotion vers `profil.md` / `feedback_*.md` / `jarvis_soul.md`.

---

HEADER
  fi

  {
    echo ""
    printf '%s\n' "$OBSERVATION"
    echo ""
    echo "---"
  } >> "$OBS_FILE"

  echo "[$(date)] Observation user-model ajoutée à $OBS_FILE" >> "$LOG"

  # Calculer le score 0-1 pour la nouvelle entrée (scoring quantitatif OpenClaw-aligned).
  # Score >= 0.6 = candidat promotion auto au prochain cycle dream/eval.
  if [[ -x "$HOME/.local/bin/jarvis-observations-score" ]]; then
    "$HOME/.local/bin/jarvis-observations-score" >> "$LOG" 2>&1 || \
      echo "[$(date)] WARN: jarvis-observations-score a échoué (non bloquant)" >> "$LOG"
  fi

  if [[ -x "$HOME/.local/bin/jarvis-notify" ]]; then
    CONFIDENCE=$(printf '%s' "$OBSERVATION" | grep -m 1 '^confidence:' | sed 's/^confidence:[[:space:]]*//' | tr -d ' ')
    "$HOME/.local/bin/jarvis-notify" "🔎 Observation user-model (confidence: ${CONFIDENCE:-?})
Voir Memory/observations.md" --silent 2>/dev/null || true
  fi
fi

# Fin du worker en arrière-plan : le `trap EXIT` interne déclenchera le log
# DONE final (status=OK/skip/error + duration). Le `} </dev/null & disown` qui
# suit détache complètement le sous-shell pour qu'il survive à la fermeture du
# parent (= le hook côté Claude Code, lui-même tué par /exit en quelques ms).
} </dev/null >>"$LOG" 2>&1 &
disown 2>/dev/null || true

exit 0

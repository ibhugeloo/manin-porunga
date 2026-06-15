#!/bin/zsh
# jarvis-memory-sync — Synchronise la mémoire Jarvis (Memory + Sessions + Projects + vault élargi) vers le repo Git.
# Lancé par launchd quotidiennement à 23h30. Push vers origin si changements.

set -uo pipefail

SRC_MEMORY="$HOME/Documents/Obsidian/vault/Claude/Memory"
SRC_SESSIONS="$HOME/Documents/Obsidian/vault/Claude/Sessions"
SRC_PROJECTS="$HOME/Documents/Obsidian/vault/Claude/Projects"
REPO="$HOME/Documents/GIT PROD/manin-control-room"
LOG="$HOME/.local/var/log/jarvis-memory-sync.log"

mkdir -p "$(dirname "$LOG")"

{
  echo ""
  echo "===================="
  echo "[$(date)] memory-sync start"
} >> "$LOG"

if [[ ! -d "$SRC_MEMORY" ]]; then
  echo "[$(date)] ERROR: $SRC_MEMORY introuvable" >> "$LOG"
  exit 1
fi

if [[ ! -d "$REPO/.git" ]]; then
  echo "[$(date)] ERROR: $REPO n'est pas un repo Git" >> "$LOG"
  exit 1
fi

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Sync via rsync : --delete pour mirror exact, --exclude pour bruit OS
mkdir -p "$REPO/memory" "$REPO/sessions" "$REPO/obsidian-projects" "$REPO/state"
rsync -a --delete --exclude '.DS_Store' --exclude '*.swp' "$SRC_MEMORY/" "$REPO/memory/" 2>>"$LOG"
rsync -a --delete --exclude '.DS_Store' --exclude '*.swp' "$SRC_SESSIONS/" "$REPO/sessions/" 2>>"$LOG"

# Le sous-dossier Projects/ d'Obsidian contient les notes de synthèse projet (manin-control-room.md, etc.)
# Utile pour l'index global, ne contient pas de secrets
if [[ -d "$SRC_PROJECTS" ]]; then
  rsync -a --delete --exclude '.DS_Store' --exclude '*.swp' "$SRC_PROJECTS/" "$REPO/obsidian-projects/" 2>>"$LOG"
fi

# --- Vault élargi (stratégie, projets, briefs, leo-feed) --------------------
# Couvre les dossiers de connaissance hors canonique pour que le backup git ne
# soit pas un SPOF partiel (gap relevé par Leo 2026-05-25).
# EXCLUS volontairement :
#   - Homelab/       -> contient des credentials (05_acces_credentials.md, IPs/tokens)
#   - Claude/        -> déjà couvert ci-dessus (memory/ sessions/ obsidian-projects/)
#   - Notion-Mirror/ -> miroir redondant de Notion
# Garde-fou secrets supplémentaire : --exclude sur patterns sensibles.
VAULT_BASE="$HOME/Documents/Obsidian/vault"
VAULT_DIRS=(Holding Brief ClientA Agency AgencyDev ShopApp Personnes Ressources Watchtower)
mkdir -p "$REPO/obsidian-vault"
for d in "${VAULT_DIRS[@]}"; do
  [[ -d "$VAULT_BASE/$d" ]] || continue
  mkdir -p "$REPO/obsidian-vault/$d"
  if [[ "$d" == "Brief" ]]; then
    # Brief = canon resserré aux LIVRABLES DURABLES (décision 2026-05-27, option 2).
    # WHITELIST : on ne pousse que évaluations, dream, hebdo, mensuel, leo-feed.
    # On SORT les quotidiens (matin/soir/veille/tech-watch) + le scratch (Inbox*).
    # --delete-excluded retire de la copie canonique le bruit déjà présent
    # (les fichiers restent dans le vault = atelier, et dans l'historique git).
    # Les exclusions secrets passent AVANT les --include (first-match-wins) → un
    # fichier au nom sensible reste exclu même s'il matche un pattern durable.
    rsync -a --delete --delete-excluded \
      --exclude '.DS_Store' --exclude '*.swp' \
      --exclude '*credential*' --exclude '*secret*' --exclude '*password*' \
      --exclude '*.key' --exclude '*.pem' --exclude '.env*' \
      --include '*evaluation.md' \
      --include '*-dream.md' \
      --include '*-hebdo.md' \
      --include '*-mensuel.md' \
      --include 'leo-feed.md' \
      --exclude '*' \
      "$VAULT_BASE/$d/" "$REPO/obsidian-vault/$d/" 2>>"$LOG"
  else
    rsync -a --delete \
      --exclude '.DS_Store' --exclude '*.swp' \
      --exclude '*credential*' --exclude '*secret*' --exclude '*password*' \
      --exclude '*.key' --exclude '*.pem' --exclude '.env*' \
      "$VAULT_BASE/$d/" "$REPO/obsidian-vault/$d/" 2>>"$LOG"
  fi
done

# Index racine du vault (carte HOT auto-régénérée) — fichier à la racine, hors VAULT_DIRS.
[[ -f "$VAULT_BASE/_vault-index.md" ]] && cp "$VAULT_BASE/_vault-index.md" "$REPO/obsidian-vault/_vault-index.md"

cd "$REPO" || { echo "[$(date)] cd failed" >> "$LOG"; exit 1; }

# Y a-t-il des changements ?
if [[ -z "$(git status --porcelain memory/ sessions/ obsidian-projects/ obsidian-vault/ state/ 2>/dev/null)" ]]; then
  echo "[$(date)] No changes" >> "$LOG"
  exit 0
fi

# Compter ce qui change pour le message de commit
CHANGED=$(git status --porcelain memory/ sessions/ obsidian-projects/ obsidian-vault/ state/ 2>/dev/null | wc -l | tr -d ' ')
DATE=$(date +%Y-%m-%d)

git add memory/ sessions/ obsidian-projects/ obsidian-vault/ state/ >> "$LOG" 2>&1
if git commit -m "memory: sync $DATE ($CHANGED fichier(s))" >> "$LOG" 2>&1; then
  echo "[$(date)] Commit OK ($CHANGED files)" >> "$LOG"
else
  echo "[$(date)] Commit failed (probably nothing to commit after add)" >> "$LOG"
  exit 0
fi

# Push (utilise les credentials keychain configurés sur la machine)
if git push origin main >> "$LOG" 2>&1; then
  echo "[$(date)] Push OK" >> "$LOG"
  [[ -x "$HOME/.local/bin/jarvis-notify" ]] && \
    "$HOME/.local/bin/jarvis-notify" "🔄 Mémoire Jarvis synchronisée ($CHANGED fichier(s))" --silent 2>/dev/null || true
else
  echo "[$(date)] Push FAILED" >> "$LOG"
  [[ -x "$HOME/.local/bin/jarvis-notify" ]] && \
    "$HOME/.local/bin/jarvis-notify" "❌ Échec sync mémoire — voir log" 2>/dev/null || true
  exit 1
fi

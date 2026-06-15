#!/bin/zsh
# Jarvis bootstrap — déploie la stack Jarvis sur cette machine.
#
# Idempotent : sûr à re-lancer. Lit les sources canoniques depuis ce dossier
# (~/Documents/Obsidian/vault/Claude/Jarvis/) et les installe localement
# (symlinks pour les scripts, copies pour les fichiers de config système).
#
# Usage :
#   ./bootstrap.sh             # installe ou met à jour
#   ./bootstrap.sh --doctor    # vérifie l'état sans rien modifier
#   ./bootstrap.sh --uninstall # retire les symlinks et hooks (préserve les données)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

JARVIS_SRC="${0:A:h}"  # dossier où vit ce script (source canonique)
HOME_DIR="$HOME"
LOCAL_BIN="$HOME_DIR/.local/bin"
LOCAL_SHARE="$HOME_DIR/.local/share/jarvis"
LOCAL_LOG="$HOME_DIR/.local/var/log"
LAUNCH_AGENTS="$HOME_DIR/Library/LaunchAgents"
CLAUDE_CONFIG="$HOME_DIR/.claude"
VAULT="$HOME_DIR/Documents/Obsidian/vault"
SESSIONS_DIR="$VAULT/Claude/Sessions"
BRIEF_DIR="$VAULT/Brief"
WATCHTOWER_DIR="$VAULT/Watchtower"

PLIST_LABEL="com.example.jarvis.brief"

# Couleurs
if [[ -t 1 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'; D=$'\033[2m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; D=""; N=""
fi

ok()    { echo "${G}✓${N} $1"; }
warn()  { echo "${Y}⚠${N} $1"; }
fail()  { echo "${R}✗${N} $1" >&2; }
info()  { echo "${B}→${N} $1"; }
step()  { echo ""; echo "${B}═══${N} $1 ${B}═══${N}"; }

MODE="install"
[[ "${1:-}" == "--doctor" ]] && MODE="doctor"
[[ "${1:-}" == "--uninstall" ]] && MODE="uninstall"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Commande requise absente : $1"
    [[ -n "${2:-}" ]] && info "Installation suggérée : $2"
    return 1
  fi
}

substitute_home() {
  # Remplace __HOME__ par $HOME dans un fichier
  sed "s|__HOME__|$HOME_DIR|g" "$1"
}

# Backup d'un fichier avant modification (avec timestamp)
backup_file() {
  local f="$1"
  if [[ -f "$f" && ! -L "$f" ]]; then
    cp "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)"
    info "Backup : $f.bak.*"
    # Rotation : ne garder que les 5 backups les plus récents (évite l'accumulation, cf. leçon #20)
    ls -t "$f".bak.* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
  fi
}

# Symlink idempotent : crée ou met à jour
link() {
  local src="$1" dst="$2"
  if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
    ok "Symlink déjà en place : $dst"
  elif [[ -e "$dst" ]]; then
    backup_file "$dst"
    rm -f "$dst"
    ln -s "$src" "$dst"
    ok "Symlink mis à jour : $dst → $src"
  else
    ln -s "$src" "$dst"
    ok "Symlink créé : $dst → $src"
  fi
}

# ---------------------------------------------------------------------------
# Vérifications préalables
# ---------------------------------------------------------------------------

step "Vérification des prérequis"

PREREQ_OK=1

if [[ ! -d "$VAULT" ]]; then
  fail "Vault Obsidian vault introuvable à $VAULT"
  fail "Synchronisez votre vault d'abord (Obsidian Sync, iCloud, etc.) puis re-lancez."
  exit 1
fi
ok "Vault Obsidian : $VAULT"

if [[ ! -d "$JARVIS_SRC" || ! -f "$JARVIS_SRC/bootstrap.sh" ]]; then
  fail "Source Jarvis introuvable à $JARVIS_SRC"
  exit 1
fi
ok "Source Jarvis : $JARVIS_SRC"

require_cmd claude "Claude Code n'est pas installé. Voir : https://claude.ai/code" || PREREQ_OK=0
require_cmd jq "brew install jq" || PREREQ_OK=0
require_cmd python3 "macOS l'inclut normalement" || PREREQ_OK=0

if ! command -v rg >/dev/null 2>&1; then
  if [[ "$MODE" == "install" ]]; then
    info "ripgrep absent — installation via brew..."
    if command -v brew >/dev/null 2>&1; then
      brew install ripgrep || { fail "Échec installation ripgrep"; PREREQ_OK=0; }
    else
      fail "brew absent. Installer Homebrew puis : brew install ripgrep"
      PREREQ_OK=0
    fi
  else
    warn "ripgrep absent (vault-search ne fonctionnera pas)"
  fi
fi

[[ "$PREREQ_OK" -eq 1 ]] && ok "Tous les prérequis sont satisfaits" || { fail "Prérequis manquants"; exit 1; }

# ---------------------------------------------------------------------------
# Mode UNINSTALL
# ---------------------------------------------------------------------------

if [[ "$MODE" == "uninstall" ]]; then
  step "Désinstallation Jarvis (les données du vault sont préservées)"

  # Décharger les LaunchAgents
  for tpl in "$JARVIS_SRC/LaunchAgents/"*.plist.template; do
    [[ -f "$tpl" ]] || continue
    plist_name=$(basename "$tpl" .template)
    label="${plist_name%.plist}"
    if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
      launchctl unload "$LAUNCH_AGENTS/$plist_name" 2>/dev/null || true
      ok "LaunchAgent déchargé : $label"
    fi
    [[ -f "$LAUNCH_AGENTS/$plist_name" ]] && rm -f "$LAUNCH_AGENTS/$plist_name" && ok "Plist retiré : $plist_name"
  done

  # Retirer symlinks et copies bin
  for src in "$JARVIS_SRC/bin/"*; do
    f=$(basename "$src")
    if [[ -L "$LOCAL_BIN/$f" ]]; then
      rm -f "$LOCAL_BIN/$f" && ok "Symlink retiré : $f"
    elif [[ -f "$LOCAL_BIN/$f" ]] && cmp -s "$src" "$LOCAL_BIN/$f"; then
      rm -f "$LOCAL_BIN/$f" && ok "Copie retirée : $f"
    fi
  done

  # Retirer symlinks share
  for src in "$JARVIS_SRC/share/"*; do
    f=$(basename "$src")
    [[ -L "$LOCAL_SHARE/$f" ]] && rm -f "$LOCAL_SHARE/$f" && ok "Symlink retiré : $f"
  done

  # Retirer hook SessionEnd de settings.json
  if [[ -f "$CLAUDE_CONFIG/settings.json" ]]; then
    backup_file "$CLAUDE_CONFIG/settings.json"
    tmp=$(mktemp)
    jq 'del(.hooks.SessionEnd)' "$CLAUDE_CONFIG/settings.json" > "$tmp" && mv "$tmp" "$CLAUDE_CONFIG/settings.json"
    ok "Hook SessionEnd retiré de settings.json"
  fi

  # Retirer bloc imports de CLAUDE.md
  if [[ -f "$CLAUDE_CONFIG/CLAUDE.md" ]]; then
    backup_file "$CLAUDE_CONFIG/CLAUDE.md"
    awk '/^# === BEGIN JARVIS IMPORTS/{skip=1} !skip{print} /^# === END JARVIS IMPORTS/{skip=0}' \
      "$CLAUDE_CONFIG/CLAUDE.md" > "$CLAUDE_CONFIG/CLAUDE.md.tmp" && \
      mv "$CLAUDE_CONFIG/CLAUDE.md.tmp" "$CLAUDE_CONFIG/CLAUDE.md"
    ok "Bloc d'imports retiré de CLAUDE.md"
  fi

  echo ""
  ok "Désinstallation terminée."
  warn "Les données suivantes sont conservées (à supprimer manuellement si besoin) :"
  echo "    - $VAULT/Claude/Memory/   (mémoire transverse)"
  echo "    - $VAULT/Claude/Sessions/ (récaps de sessions)"
  echo "    - $VAULT/Brief/           (briefs quotidiens)"
  echo "    - $VAULT/Watchtower/      (rapports clients quotidiens)"
  echo "    - $LOCAL_LOG/             (logs)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Mode DOCTOR (vérification sans modification)
# ---------------------------------------------------------------------------

if [[ "$MODE" == "doctor" ]]; then
  step "Diagnostic Jarvis"

  # Scripts : tous copiés (pas de symlink, cf. lessons #17)
  for src in "$JARVIS_SRC/bin/"*; do
    f=$(basename "$src")
    dst="$LOCAL_BIN/$f"
    if [[ -L "$dst" ]]; then
      warn "$dst est un SYMLINK (devrait être copie — re-bootstrapper)"
    elif [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
      ok "$dst (copie à jour)"
    elif [[ -f "$dst" ]]; then
      warn "$dst (copie obsolète, re-bootstrapper)"
    else
      fail "$dst manquant"
    fi
  done

  # Prompts
  for src in "$JARVIS_SRC/share/"*; do
    f=$(basename "$src")
    [[ -e "$LOCAL_SHARE/$f" ]] && ok "$LOCAL_SHARE/$f" || fail "$LOCAL_SHARE/$f manquant"
  done

  # LaunchAgents
  for tpl in "$JARVIS_SRC/LaunchAgents/"*.plist.template; do
    [[ -f "$tpl" ]] || continue
    plist_name=$(basename "$tpl" .template)
    label="${plist_name%.plist}"
    if [[ -f "$LAUNCH_AGENTS/$plist_name" ]]; then
      if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
        ok "LaunchAgent chargé : $label"
      else
        warn "LaunchAgent installé mais non chargé : $label"
      fi
    else
      fail "$plist_name manquant"
    fi
  done

  # settings.json hook
  if [[ -f "$CLAUDE_CONFIG/settings.json" ]]; then
    if jq -e '.hooks.SessionEnd' "$CLAUDE_CONFIG/settings.json" >/dev/null 2>&1; then
      ok "Hook SessionEnd présent dans settings.json"
    else
      fail "Hook SessionEnd absent de settings.json"
    fi
  else
    fail "$CLAUDE_CONFIG/settings.json absent"
  fi

  # CLAUDE.md imports
  if [[ -f "$CLAUDE_CONFIG/CLAUDE.md" ]]; then
    if grep -q "BEGIN JARVIS IMPORTS" "$CLAUDE_CONFIG/CLAUDE.md"; then
      ok "Bloc d'imports Jarvis présent dans CLAUDE.md"
    else
      fail "Bloc d'imports Jarvis absent de CLAUDE.md"
    fi
  else
    fail "$CLAUDE_CONFIG/CLAUDE.md absent"
  fi

  # Mémoire transverse
  for m in feedback_role_jarvis.md feedback_autonomie_jarvis.md feedback_precision_discretion.md \
           reference_jarvis_brief_quotidien.md reference_vault_search.md reference_session_memoire.md; do
    [[ -f "$VAULT/Claude/Memory/$m" ]] && ok "Memory: $m" || warn "Memory absente: $m"
  done

  # Test command claude
  if "$LOCAL_BIN/claude" --version 2>/dev/null | head -1 | grep -q "Claude Code"; then
    ok "Claude CLI fonctionnel : $("$LOCAL_BIN/claude" --version | head -1)"
  else
    warn "Claude CLI non détecté dans $LOCAL_BIN"
  fi

  echo ""
  echo "${B}Commandes utiles :${N}"
  echo "  Test brief           : ${LOCAL_BIN}/jarvis-brief.sh"
  echo "  Test vault-search    : ${LOCAL_BIN}/vault-search \"<question>\""
  echo "  Logs brief           : tail -f ${LOCAL_LOG}/jarvis-brief.log"
  echo "  Logs session-recap   : tail -f ${LOCAL_LOG}/jarvis-session-recap.log"
  echo ""
  exit 0
fi

# ---------------------------------------------------------------------------
# Mode INSTALL (par défaut)
# ---------------------------------------------------------------------------

step "Création des répertoires locaux"
mkdir -p "$LOCAL_BIN" "$LOCAL_SHARE" "$LOCAL_LOG" "$LAUNCH_AGENTS" "$CLAUDE_CONFIG" "$BRIEF_DIR" "$SESSIONS_DIR" "$WATCHTOWER_DIR"
ok "Répertoires prêts"

step "Scripts (source : $JARVIS_SRC)"
# Tous les fichiers de bin/ sont COPIÉS (pas symlinkés) pour éviter TCC :
# macOS bloque les launchd-spawned shells/binaires qui essaient d'ouvrir un fichier
# cible de symlink pointant dans ~/Documents/ (cf. lessons.md #12 et #17).
# Conséquence : éditer un script dans le vault ne se propage pas tant qu'on n'a pas
# re-bootstrappé. C'est le prix à payer pour des cron jobs fiables.
for src in "$JARVIS_SRC/bin/"*; do
  [[ -f "$src" || -L "$src" ]] || continue
  base=$(basename "$src")
  dst="$LOCAL_BIN/$base"
  if [[ -e "$dst" && ! -L "$dst" ]] && cmp -s "$src" "$dst"; then
    ok "Copie inchangée : $dst"
  else
    [[ -L "$dst" ]] && rm -f "$dst"
    cp "$src" "$dst" && chmod +x "$dst" && ok "Copie : $dst"
  fi
done

# UI static assets (pages HTML extraites de jarvis-ui-server.py)
# Le serveur les charge via Path(__file__).parent / "ui" / "static" — on miroir
# bin/ui/ vers ~/.local/bin/ui/ (TCC-safe).
if [[ -d "$JARVIS_SRC/bin/ui" ]]; then
  if [[ -d "$LOCAL_BIN/ui" ]]; then
    rm -rf "$LOCAL_BIN/ui"
  fi
  cp -R "$JARVIS_SRC/bin/ui" "$LOCAL_BIN/ui"
  ok "UI assets déployés : $LOCAL_BIN/ui ($(find "$LOCAL_BIN/ui" -type f | wc -l | tr -d ' ') fichiers)"
fi

step "Prompts (source : $JARVIS_SRC/share/)"
# Tous les prompts sont COPIÉS (pas symlinkés) — sed/cat/python lancés par launchd
# ne peuvent pas suivre les symlinks pointant vers ~/Documents/ (cf. lessons.md #17).
for src in "$JARVIS_SRC/share/"*; do
  [[ -f "$src" || -L "$src" ]] || continue
  base=$(basename "$src")
  dst="$LOCAL_SHARE/$base"
  if [[ -e "$dst" && ! -L "$dst" ]] && cmp -s "$src" "$dst"; then
    ok "Copie inchangée : $dst"
  else
    [[ -L "$dst" ]] && rm -f "$dst"
    cp "$src" "$dst" && ok "Copie : $dst"
  fi
done

step "LaunchAgents (cron jobs)"
for tpl in "$JARVIS_SRC/LaunchAgents/"*.plist.template; do
  [[ -f "$tpl" ]] || continue
  plist_name=$(basename "$tpl" .template)
  plist_dst="$LAUNCH_AGENTS/$plist_name"
  label="${plist_name%.plist}"

  # Comparer le contenu rendu au plist existant — ne rien faire si identique
  rendered=$(substitute_home "$tpl")
  is_loaded=0
  launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 && is_loaded=1

  if [[ -f "$plist_dst" ]] && [[ "$(cat "$plist_dst")" == "$rendered" ]] && [[ $is_loaded -eq 1 ]]; then
    ok "LaunchAgent inchangé : $label (skip reload)"
    continue
  fi

  # Soit nouveau, soit modifié, soit non chargé → écrire et (re)charger
  printf '%s' "$rendered" > "$plist_dst"
  if [[ $is_loaded -eq 1 ]]; then
    launchctl unload "$plist_dst" 2>/dev/null || true
    ok "Plist mis à jour : $plist_name (reload nécessaire)"
  else
    ok "Plist écrit : $plist_name"
  fi
  if launchctl load -w "$plist_dst" 2>/dev/null; then
    ok "LaunchAgent chargé : $label"
  else
    warn "Échec chargement : $label"
  fi
done

step "Hooks Claude Code (settings.json)"
SETTINGS="$CLAUDE_CONFIG/settings.json"
HOOKS_FRAG="$JARVIS_SRC/claude-config/settings.hooks.json"

if [[ ! -f "$SETTINGS" ]]; then
  echo "{}" > "$SETTINGS"
fi

backup_file "$SETTINGS"
tmp=$(mktemp)
substitute_home "$HOOKS_FRAG" \
  | jq -s '.[0] * .[1]' "$SETTINGS" - \
  > "$tmp" && mv "$tmp" "$SETTINGS"
ok "Hook SessionEnd fusionné dans settings.json"

step "Slash commands Claude Code"
COMMANDS_SRC="$JARVIS_SRC/claude-config/commands"
COMMANDS_DST="$CLAUDE_CONFIG/commands"

if [[ -d "$COMMANDS_SRC" ]]; then
  mkdir -p "$COMMANDS_DST"
  for cmd in "$COMMANDS_SRC"/*.md; do
    [[ -f "$cmd" ]] || continue
    name=$(basename "$cmd")
    cp "$cmd" "$COMMANDS_DST/$name"
    ok "Slash command : /$(basename "$cmd" .md)"
  done
else
  ok "Aucun slash command à déployer (claude-config/commands/ absent)"
fi

step "Rules path-scoped Claude Code (.claude/rules/)"
RULES_SRC="$JARVIS_SRC/claude-config/rules"
RULES_DST="$CLAUDE_CONFIG/rules"

if [[ -d "$RULES_SRC" ]]; then
  mkdir -p "$RULES_DST"
  for rule in "$RULES_SRC"/*.md; do
    [[ -f "$rule" ]] || continue
    name=$(basename "$rule")
    cp "$rule" "$RULES_DST/$name"
    ok "Rule path-scoped : $name"
  done
else
  ok "Aucune rule à déployer (claude-config/rules/ absent)"
fi

step "Skills Claude Code (.claude/skills/)"
SKILLS_SRC="$JARVIS_SRC/claude-config/skills"
SKILLS_DST="$CLAUDE_CONFIG/skills"

if [[ -d "$SKILLS_SRC" ]]; then
  mkdir -p "$SKILLS_DST"
  for skill_dir in "$SKILLS_SRC"/*/; do
    [[ -d "$skill_dir" ]] || continue
    name=$(basename "$skill_dir")
    mkdir -p "$SKILLS_DST/$name"
    cp -R "$skill_dir"* "$SKILLS_DST/$name/"
    ok "Skill : $name"
  done
else
  ok "Aucun skill à déployer (claude-config/skills/ absent)"
fi

step "Imports CLAUDE.md"
CLAUDE_MD="$CLAUDE_CONFIG/CLAUDE.md"
IMPORTS_FRAG="$JARVIS_SRC/claude-config/CLAUDE.md.imports.txt"

[[ ! -f "$CLAUDE_MD" ]] && touch "$CLAUDE_MD"
backup_file "$CLAUDE_MD"

# Retirer ancien bloc Jarvis si présent (idempotence)
if grep -q "BEGIN JARVIS IMPORTS" "$CLAUDE_MD"; then
  awk '/^# === BEGIN JARVIS IMPORTS/{skip=1} !skip{print} /^# === END JARVIS IMPORTS/{skip=0; next}' \
    "$CLAUDE_MD" > "$CLAUDE_MD.tmp" && mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"
fi

# Insérer le nouveau bloc en tête
new_imports=$(substitute_home "$IMPORTS_FRAG")
if [[ -s "$CLAUDE_MD" ]]; then
  printf '%s\n\n%s' "$new_imports" "$(cat "$CLAUDE_MD")" > "$CLAUDE_MD.tmp" && mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"
else
  printf '%s\n' "$new_imports" > "$CLAUDE_MD"
fi
ok "Bloc d'imports Jarvis injecté en tête de CLAUDE.md"

step "Smoke test"
for src in "$JARVIS_SRC/bin/"*; do
  f=$(basename "$src")
  if [[ -x "$LOCAL_BIN/$f" ]]; then
    ok "$f exécutable"
  else
    fail "$f non exécutable"
  fi
done

echo ""
echo "${G}════════════════════════════════════════════════════════════════${N}"
echo "${G}  Jarvis déployé.${N}"
echo "${G}════════════════════════════════════════════════════════════════${N}"
echo ""
echo "${B}Test rapide :${N}"
echo "    $LOCAL_BIN/jarvis-brief.sh        # génère un brief immédiatement"
echo "    $LOCAL_BIN/jarvis-watchtower.sh   # génère le rapport clients immédiatement"
echo "    $LOCAL_BIN/vault-search \"...\"    # recherche sémantique légère"
echo ""
echo "${B}Diagnostic :${N}"
echo "    $JARVIS_SRC/bootstrap.sh --doctor"
echo ""
echo "${B}Désinstallation :${N}"
echo "    $JARVIS_SRC/bootstrap.sh --uninstall"
echo ""

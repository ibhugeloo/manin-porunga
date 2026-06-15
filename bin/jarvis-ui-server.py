#!/usr/bin/env python3
"""
jarvis-ui-server — Dashboard local pour Jarvis.

Sert un dashboard HTML sur localhost avec API endpoints pour les données live :
- Brief du jour (jour + hebdo + mensuel + évaluation)
- Status des repos GIT PROD
- État des LaunchAgents (cron jobs Jarvis)
- Sessions Claude Code récentes
- Bot Telegram alive/dead
- Logs

Pure stdlib Python, pas de dépendances externes.
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import re
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

# ---------------------------------------------------------------------------
# Package path : add bin/ dir so `ui.*` imports resolve whether we run from
# the repo (bin/jarvis-ui-server.py) or from ~/.local/bin/ (after bootstrap).
# ---------------------------------------------------------------------------
_BIN_DIR = Path(__file__).resolve().parent
if str(_BIN_DIR) not in sys.path:
    sys.path.insert(0, str(_BIN_DIR))

from ui.config import (  # noqa: E402
    HOME, VAULT, BRIEF_DIR, SESSIONS_DIR, JARVIS_SRC, LOG_DIR, LOCAL_BIN,
    GIT_PROD_DIR, GIT_PROD_EXCLUDE,
    REPOS_CONFIG_PATH, DOMAINS_CONFIG_PATH,
    CLAUDE_AGENTS_DIR, CLAUDE_PROJECTS_DIR, CLAUDE_PLUGINS_DIR,
    CLAUDE_SETTINGS_FILE, ACTIVE_SESSIONS_FILE,
    BUILTIN_AGENTS,
    _SERVER_STARTED_TS, _SERVER_STARTED_AT,
    _CONFIG_DIAGNOSTICS, _record_diag,
)
from ui.collectors.repos import (  # noqa: E402
    load_repos_config, repo_category, category_label, repo_url,
    update_repo_url, update_repo_category,
    collect_repos,
    load_domains, save_domains, collect_domains, upsert_domain, delete_domain,
)
from ui.collectors.agents import (  # noqa: E402
    _read_md_meta, _truncate_agent_desc, _guess_role,
    _detect_active_subagents, _last_used_subagents,
    _enabled_plugin_paths,
    collect_subagents, collect_agent_topology,
)
from ui.collectors.briefs import (  # noqa: E402
    _preview, collect_briefs, collect_sessions,
)
from ui.collectors.watchtower import (  # noqa: E402
    WATCHTOWER_DIR, WATCHTOWER_CONFIG, _WT_STATUS_BY_EMOJI,
    _watchtower_load_projects, _watchtower_latest_report_dir,
    _watchtower_parse_summary, collect_watchtower,
)


# ----------------------------------------------------------------------------
# LaunchAgents (schedule + collect_agents)
# ----------------------------------------------------------------------------

LAUNCH_AGENTS_CONFIG = [
    ("com.example.jarvis.brief", "Brief du jour", "tous les jours 7h30"),
    ("com.example.jarvis.routine-hebdo", "Revue hebdo", "dimanche 18h00"),
    ("com.example.jarvis.routine-mensuel", "Bilan mensuel", "1er du mois 9h00"),
    ("com.example.jarvis.routine-evaluation", "Auto-evaluation", "1er du mois 8h00"),
    ("com.example.jarvis.notion-export", "Notion mirror", "tous les jours 6h30"),
    ("com.example.jarvis.vault-index", "Vault sémantique", "chaque heure 8h-22h + 3h30"),
    ("com.example.jarvis.memory-sync", "Memory backup", "tous les jours 23h30"),
    ("com.example.jarvis.telegram-bot", "Bot Telegram", "running 24/7"),
]


def _parse_schedule_next(schedule: str) -> int | None:
    """Calcule timestamp Unix du prochain run depuis une string humaine."""
    now = datetime.now()
    s = schedule.lower()

    if "24/7" in s or "running" in s:
        return None

    hour_match = re.search(r"(\d{1,2})h(\d{0,2})", s)
    if not hour_match:
        return None

    if "chaque heure" in s:
        h_min = int(re.search(r"(\d{1,2})h", s).group(1))
        m_range = re.search(r"(\d{1,2})h.*?(\d{1,2})h", s)
        if m_range:
            h_max = int(m_range.group(2))
        else:
            h_max = 22
        nxt = now.replace(minute=0, second=0, microsecond=0)
        if now.minute > 0 or now.second > 0:
            nxt = nxt.replace(hour=now.hour) + timedelta(hours=1)
        while nxt.hour < h_min or nxt.hour > h_max:
            if nxt.hour > h_max:
                nxt = (nxt + timedelta(days=1)).replace(hour=h_min)
            else:
                nxt = nxt.replace(hour=h_min)
        return int(nxt.timestamp())

    hour = int(hour_match.group(1))
    minute = int(hour_match.group(2)) if hour_match.group(2) else 0
    nxt = now.replace(hour=hour, minute=minute, second=0, microsecond=0)

    if "dimanche" in s:
        days_until = (6 - now.weekday()) % 7
        if days_until == 0 and now > nxt:
            days_until = 7
        nxt = nxt + timedelta(days=days_until)
        return int(nxt.timestamp())

    if "1er du mois" in s or "1er" in s:
        if now.day == 1 and now < nxt:
            return int(nxt.timestamp())
        if now.month == 12:
            nxt = nxt.replace(year=now.year + 1, month=1, day=1)
        else:
            nxt = nxt.replace(month=now.month + 1, day=1)
        return int(nxt.timestamp())

    if now > nxt:
        nxt = nxt + timedelta(days=1)
    return int(nxt.timestamp())


def collect_agents() -> list[dict]:
    uid = os.getuid()
    out = []
    for label, name, schedule in LAUNCH_AGENTS_CONFIG:
        try:
            r = subprocess.run(
                ["launchctl", "print", f"gui/{uid}/{label}"],
                capture_output=True,
                text=True,
                timeout=3,
            )
            loaded = r.returncode == 0
            running = False
            last_exit = None
            last_exited = None
            pid = None
            if loaded:
                output = r.stdout
                m = re.search(r"state\s*=\s*(\w+)", output)
                if m:
                    running = m.group(1) == "running"
                m = re.search(r"pid\s*=\s*(\d+)", output)
                if m:
                    pid = int(m.group(1))
                m = re.search(r"last exit code\s*=\s*(.+)", output)
                if m:
                    last_exit = m.group(1).strip()
                m = re.search(r"last exited\s*=\s*(.+)", output)
                if m:
                    last_exited = m.group(1).strip()
        except Exception:
            loaded = False
            running = False
            last_exit = None
            last_exited = None
            pid = None
        out.append({
            "label": label,
            "name": name,
            "schedule": schedule,
            "loaded": loaded,
            "running": running,
            "pid": pid,
            "last_exit": last_exit,
            "last_exited": last_exited,
            "next_run_ts": _parse_schedule_next(schedule),
        })
    return out


def toggle_agent(label: str) -> dict:
    """Active ou désactive un LaunchAgent."""
    uid = os.getuid()
    plist_path = HOME / "Library" / "LaunchAgents" / f"{label}.plist"
    if not plist_path.exists():
        return {"ok": False, "error": f"plist absent : {plist_path}"}

    r = subprocess.run(
        ["launchctl", "print", f"gui/{uid}/{label}"],
        capture_output=True, text=True, timeout=3,
    )
    is_loaded = r.returncode == 0

    if is_loaded:
        rr = subprocess.run(
            ["launchctl", "unload", str(plist_path)],
            capture_output=True, text=True, timeout=5,
        )
        if rr.returncode == 0:
            push_event("action", f"Agent désactivé : {label}", agent=label, state="off")
            return {"ok": True, "state": "off", "label": label}
        return {"ok": False, "error": rr.stderr or "unload failed"}
    else:
        rr = subprocess.run(
            ["launchctl", "load", "-w", str(plist_path)],
            capture_output=True, text=True, timeout=5,
        )
        if rr.returncode == 0:
            push_event("action", f"Agent activé : {label}", agent=label, state="on")
            return {"ok": True, "state": "on", "label": label}
        return {"ok": False, "error": rr.stderr or "load failed"}


def kickstart_agent(label: str) -> dict:
    """Force un run immédiat d'un LaunchAgent (kickstart -k)."""
    uid = os.getuid()
    rr = subprocess.run(
        ["launchctl", "kickstart", "-k", f"gui/{uid}/{label}"],
        capture_output=True, text=True, timeout=5,
    )
    if rr.returncode == 0:
        push_event("action", f"Agent lancé manuellement : {label}", agent=label)
        return {"ok": True, "label": label}
    return {"ok": False, "error": rr.stderr or "kickstart failed"}


# ----------------------------------------------------------------------------
# Telegram status
# ----------------------------------------------------------------------------

def collect_telegram_status() -> dict:
    env_file = HOME / ".config" / "jarvis" / "telegram.env"
    if not env_file.exists():
        return {"configured": False, "running": False, "history_count": 0, "history": []}

    running = False
    pid = None
    try:
        r = subprocess.run(["pgrep", "-f", "jarvis-telegram-bot.py"], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            pid = int(r.stdout.strip().split()[0])
            running = True
    except Exception:
        pass

    history_file = HOME / ".local" / "share" / "jarvis" / "telegram-history.jsonl"
    history_count = 0
    history: list[dict] = []
    if history_file.exists():
        try:
            lines = [l for l in history_file.read_text().splitlines() if l.strip()]
            history_count = len(lines)
            for line in lines[-10:]:
                turn = json.loads(line)
                history.append({
                    "role": turn.get("role"),
                    "content": turn.get("content", "")[:1500],
                    "ts": turn.get("ts"),
                })
        except Exception:
            pass

    bot_username = "?"
    try:
        for line in env_file.read_text().splitlines():
            if line.startswith("BOT_USERNAME="):
                bot_username = line.split("=", 1)[1].strip().strip('"').strip("'")
                break
    except Exception:
        pass

    return {
        "configured": True,
        "running": running,
        "pid": pid,
        "username": bot_username,
        "history_count": history_count,
        "history": history,
    }


# ----------------------------------------------------------------------------
# Event bus (in-memory) + filesystem watcher for live activity feed (SSE)
# ----------------------------------------------------------------------------

_events_lock = threading.Lock()
_events: "collections.deque[dict]" = collections.deque(maxlen=200)
_event_counter = [0]


def push_event(kind: str, title: str, **extra):
    """Ajoute un event au bus. kind: brief|session|skill|action|note|telegram|repo|info"""
    with _events_lock:
        _event_counter[0] += 1
        evt = {
            "id": _event_counter[0],
            "ts": int(time.time()),
            "kind": kind,
            "title": title,
        }
        evt.update(extra)
        _events.append(evt)


def recent_events_since(last_id: int) -> list[dict]:
    with _events_lock:
        return [e for e in _events if e["id"] > last_id]


# Watcher : polle quelques chemins clés pour détecter les nouveautés
_watcher_state: dict[str, set[str]] = {}
_watcher_started = [False]


def _scan_dir(path: Path, since_seconds: int = 0) -> set[str]:
    if not path.exists():
        return set()
    out = set()
    cutoff = time.time() - since_seconds if since_seconds else 0
    try:
        for f in path.iterdir():
            if f.is_file() and f.suffix == ".md":
                try:
                    if not since_seconds or f.stat().st_mtime >= cutoff:
                        out.add(str(f))
                except Exception:
                    pass
    except Exception:
        pass
    return out


def _watcher_loop():
    """Scanne 4-5 dossiers toutes les 3s. Quand un fichier .md apparaît / change → event."""
    BRIEF_PATH = HOME / "Documents" / "Obsidian" / "vault" / "Brief"
    SESSIONS_PATH = HOME / "Documents" / "Obsidian" / "vault" / "Claude" / "Sessions"
    PROPOSED_PATH = HOME / "Documents" / "Obsidian" / "vault" / "Claude" / "Memory" / "proposed"

    _watcher_state["brief"] = _scan_dir(BRIEF_PATH)
    _watcher_state["sessions"] = _scan_dir(SESSIONS_PATH)
    _watcher_state["proposed"] = _scan_dir(PROPOSED_PATH)
    _watcher_state["telegram_size"] = 0
    tg_history = HOME / ".local" / "share" / "jarvis" / "telegram-history.jsonl"
    if tg_history.exists():
        _watcher_state["telegram_size"] = tg_history.stat().st_size

    while True:
        try:
            current = _scan_dir(BRIEF_PATH)
            new_briefs = current - _watcher_state["brief"]
            for f in new_briefs:
                name = Path(f).name
                if "hebdo" in name: kind_label = "Hebdo"
                elif "mensuel" in name: kind_label = "Mensuel"
                elif "evaluation" in name: kind_label = "Évaluation"
                else: kind_label = "Brief du jour"
                push_event("brief", f"{kind_label} : {name}", path=f)
            _watcher_state["brief"] = current

            current = _scan_dir(SESSIONS_PATH)
            new_sessions = current - _watcher_state["sessions"]
            for f in new_sessions:
                push_event("session", f"Nouvelle session Claude : {Path(f).name}", path=f)
            _watcher_state["sessions"] = current

            current = _scan_dir(PROPOSED_PATH)
            new_skills = current - _watcher_state["proposed"]
            for f in new_skills:
                push_event("skill", f"Skill proposé : {Path(f).stem}", path=f)
            _watcher_state["proposed"] = current

            if tg_history.exists():
                size = tg_history.stat().st_size
                if size > _watcher_state["telegram_size"] and _watcher_state["telegram_size"] > 0:
                    push_event("telegram", "Nouveau message Telegram échangé")
                _watcher_state["telegram_size"] = size

        except Exception:
            pass

        time.sleep(3)


def ensure_watcher():
    if _watcher_started[0]:
        return
    _watcher_started[0] = True
    t = threading.Thread(target=_watcher_loop, daemon=True, name="jarvis-watcher")
    t.start()
    push_event("info", "Dashboard démarré")


# ----------------------------------------------------------------------------
# Action triggers (POST endpoints)
# ----------------------------------------------------------------------------

ACTIONS = {
    "brief": {
        "label": "Brief du jour",
        "cmd": [str(LOCAL_BIN / "jarvis-brief.sh")],
        "spawn": True,
    },
    "hebdo": {
        "label": "Revue hebdo",
        "cmd": [str(LOCAL_BIN / "jarvis-routine.sh"), "hebdo"],
        "spawn": True,
    },
    "mensuel": {
        "label": "Bilan mensuel",
        "cmd": [str(LOCAL_BIN / "jarvis-routine.sh"), "mensuel"],
        "spawn": True,
    },
    "evaluation": {
        "label": "Auto-évaluation",
        "cmd": [str(LOCAL_BIN / "jarvis-routine.sh"), "evaluation"],
        "spawn": True,
    },
    "notion-export": {
        "label": "Sync Notion mirror",
        "cmd": [str(LOCAL_BIN / "notion-export.sh")],
        "spawn": True,
    },
    "vault-reindex": {
        "label": "Reindex vault (sémantique)",
        "cmd": [str(LOCAL_BIN / "jarvis-vault-index")],
        "spawn": True,
    },
    "telegram-restart": {
        "label": "Redémarrer bot Telegram",
        "cmd": ["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/com.example.jarvis.telegram-bot"],
        "spawn": False,
    },
    "ui-restart": {
        "label": "Redémarrer le dashboard",
        "cmd": ["true"],
        "spawn": False,
    },
}


def trigger_action(action: str) -> dict:
    """Exécute une action. Retourne {ok, started, label, error?}."""
    if action not in ACTIONS:
        return {"ok": False, "error": f"action inconnue: {action}"}

    spec = ACTIONS[action]
    label = spec["label"]
    cmd = spec["cmd"]

    try:
        if spec["spawn"]:
            subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
            push_event("action", f"Action lancée : {label}", action=action)
            return {"ok": True, "started": label, "background": True}
        else:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            push_event("action", f"Action exécutée : {label}", action=action, exit=r.returncode)
            return {
                "ok": r.returncode == 0,
                "started": label,
                "background": False,
                "stdout": r.stdout[-500:] if r.stdout else "",
                "stderr": r.stderr[-500:] if r.stderr else "",
                "exit": r.returncode,
            }
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "timeout"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ----------------------------------------------------------------------------
# Memory
# ----------------------------------------------------------------------------

MEMORY_DIR = HOME / "Documents" / "Obsidian" / "vault" / "Claude" / "Memory"
PROPOSED_DIR = MEMORY_DIR / "proposed"


def collect_memory() -> dict:
    """Liste les fichiers Memory/ + Memory/proposed/ avec metadata."""
    active = []
    proposed = []

    if MEMORY_DIR.exists():
        for f in sorted(MEMORY_DIR.iterdir()):
            if not f.is_file() or f.suffix != ".md" or f.name == "MEMORY.md":
                continue
            meta = _read_md_meta(f)
            active.append({
                "filename": f.name,
                "name": meta["name"],
                "description": meta["description"],
                "title": meta["title"],
                "size": f.stat().st_size,
                "modified": int(f.stat().st_mtime),
            })

    if PROPOSED_DIR.exists():
        for f in sorted(PROPOSED_DIR.iterdir()):
            if not f.is_file() or f.suffix != ".md":
                continue
            meta = _read_md_meta(f)
            proposed.append({
                "filename": f.name,
                "name": meta["name"],
                "description": meta["description"],
                "title": meta["title"],
                "size": f.stat().st_size,
                "modified": int(f.stat().st_mtime),
            })

    return {"active": active, "proposed": proposed}


def read_memory_file(filename: str, in_proposed: bool = False) -> dict:
    """Lit le contenu complet d'un fichier mémoire."""
    base = PROPOSED_DIR if in_proposed else MEMORY_DIR
    f = base / filename
    if not f.exists() or f.suffix != ".md":
        return {"ok": False, "error": "fichier introuvable"}
    if "/" in filename or ".." in filename:
        return {"ok": False, "error": "path invalide"}
    try:
        content = f.read_text(encoding="utf-8")
        return {"ok": True, "content": content, "filename": filename}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# Seuils dumb-zone (Mo de transcript) — alignés sur bin/jarvis-context-watch.sh
_CTX_LEVELS = [(16, 3), (11, 2), (6, 1)]
# Caps memory-guard (cf. bin/jarvis-memory-guard.sh)
_MEM_MAX_FILES = 14
_MEM_SOFT_KB = 20
_MEM_SOFT_KB_OVERRIDE = {"agents.md": 30}


def collect_telemetry() -> dict:
    """Télémétrie système : contextes (sessions live) + mémoire (HOT/caps/WARM/skills).

    Agrège des signaux déjà collectés mais dispersés :
      - active-sessions.json + taille du transcript JSONL → palier dumb-zone
      - @imports de ~/.claude/CLAUDE.md → poids HOT réellement auto-loadé
      - Memory/ top-level → distance aux caps du memory-guard
      - jarvis-warm-hits.log → fréquence d'usage WARM/COLD
      - Memory/auto/ → nb de skills auto-promus
    """
    # ---- Contextes : sessions live + taille transcript ----
    contexts = []
    try:
        raw = json.loads(ACTIVE_SESSIONS_FILE.read_text()).get("sessions", [])
    except Exception:
        raw = []
    for s in raw:
        sid = s.get("session_id", "")
        size = 0
        if sid:
            for p in CLAUDE_PROJECTS_DIR.glob(f"*/{sid}.jsonl"):
                try:
                    size = p.stat().st_size
                except Exception:
                    size = 0
                break
        mb = size / 1048576
        level = next((lvl for thr, lvl in _CTX_LEVELS if mb >= thr), 0)
        cwd = s.get("cwd", "")
        contexts.append({
            "session_id": sid,
            "cwd": cwd,
            "cwd_name": Path(cwd).name or cwd,
            "started_at": s.get("started_at", ""),
            "last_activity": s.get("last_activity", ""),
            "transcript_mb": round(mb, 1),
            "level": level,
        })
    contexts.sort(key=lambda x: x["transcript_mb"], reverse=True)

    # ---- Mémoire HOT : poids réel via @imports de CLAUDE.md ----
    hot_files, hot_total = [], 0
    try:
        for line in (HOME / ".claude" / "CLAUDE.md").read_text().splitlines():
            line = line.strip()
            if line.startswith("@/"):
                fp = Path(line[1:])
                if fp.exists():
                    sz = fp.stat().st_size
                    hot_total += sz
                    hot_files.append({"name": fp.name, "kb": round(sz / 1024, 1)})
    except Exception:
        pass
    hot_files.sort(key=lambda x: x["kb"], reverse=True)

    # ---- Memory/ guard : nb fichiers vs cap + plus gros vs plafond ----
    guard_files = []
    if MEMORY_DIR.exists():
        for f in sorted(MEMORY_DIR.iterdir()):
            if f.is_file() and f.suffix == ".md" and f.name != "MEMORY.md":
                cap = _MEM_SOFT_KB_OVERRIDE.get(f.name, _MEM_SOFT_KB)
                kb = round(f.stat().st_size / 1024, 1)
                guard_files.append({"name": f.name, "kb": kb, "cap_kb": cap, "over": kb > cap})
    guard_count = len(guard_files)
    guard_files.sort(key=lambda x: x["kb"], reverse=True)

    # ---- WARM/COLD : fréquence d'usage observée ----
    warm_hits, warm_last = {}, None
    try:
        for line in (LOG_DIR / "jarvis-warm-hits.log").read_text().splitlines():
            parts = line.split(",")
            if len(parts) >= 4:
                warm_hits[parts[3]] = warm_hits.get(parts[3], 0) + 1
                warm_last = parts[0]
    except Exception:
        pass
    warm_top = [{"tier": t, "hits": n}
                for t, n in sorted(warm_hits.items(), key=lambda x: x[1], reverse=True)[:6]]

    # ---- Skills auto/ ----
    auto_dir = MEMORY_DIR / "auto"
    skills_auto = 0
    if auto_dir.exists():
        skills_auto = sum(1 for f in auto_dir.iterdir()
                          if f.is_file() and f.suffix == ".md" and not f.name.startswith("_"))

    return {
        "contexts": contexts,
        "memory": {
            "hot_total_kb": round(hot_total / 1024, 1),
            "hot_files": hot_files,
            "guard_count": guard_count,
            "guard_max": _MEM_MAX_FILES,
            "guard_files": guard_files[:5],
            "guard_over": sum(1 for f in guard_files if f["over"]),
            "warm_top": warm_top,
            "warm_last": warm_last,
            "skills_auto": skills_auto,
        },
    }


def promote_skill(filename: str) -> dict:
    """Déplace un skill de Memory/proposed/ vers Memory/."""
    if "/" in filename or ".." in filename or not filename.endswith(".md"):
        return {"ok": False, "error": "filename invalide"}
    src = PROPOSED_DIR / filename
    dst = MEMORY_DIR / filename
    if not src.exists():
        return {"ok": False, "error": "fichier proposé introuvable"}
    if dst.exists():
        return {"ok": False, "error": f"un fichier {filename} existe déjà dans Memory/"}
    src.rename(dst)
    push_event("skill", f"Skill promu : {filename}", filename=filename)
    return {"ok": True, "filename": filename, "path": str(dst)}


def reject_skill(filename: str) -> dict:
    """Supprime un skill proposé."""
    if "/" in filename or ".." in filename or not filename.endswith(".md"):
        return {"ok": False, "error": "filename invalide"}
    f = PROPOSED_DIR / filename
    if not f.exists():
        return {"ok": False, "error": "fichier introuvable"}
    f.unlink()
    return {"ok": True, "filename": filename}


# ----------------------------------------------------------------------------
# File browser (workspace)
# ----------------------------------------------------------------------------

BROWSER_ROOTS = {
    "vault": HOME / "Documents" / "Obsidian" / "vault",
    "git-prod": HOME / "Documents" / "GIT PROD",
    "jarvis-bin": HOME / ".local" / "bin",
    "jarvis-share": HOME / ".local" / "share" / "jarvis",
    "jarvis-config": HOME / ".config" / "jarvis",
}

PREVIEWABLE_EXT = {".md", ".txt", ".yaml", ".yml", ".json", ".toml", ".sh", ".py",
                   ".js", ".ts", ".tsx", ".jsx", ".html", ".css", ".sql", ".env.example"}

EXCLUDE_NAMES = {".git", "node_modules", ".venv", "venv", ".DS_Store",
                 ".obsidian", ".trash", "__pycache__", ".playwright-mcp",
                 ".next", "dist", "build"}


def _safe_resolve(root_key: str, rel_path: str) -> Path | None:
    """Empêche path traversal : assure que la résolution reste dans la root."""
    if root_key not in BROWSER_ROOTS:
        return None
    root = BROWSER_ROOTS[root_key]
    if not root.exists():
        return None
    target = (root / rel_path).resolve()
    try:
        target.relative_to(root.resolve())
    except ValueError:
        return None
    return target


def list_directory(root_key: str, rel_path: str = "") -> dict:
    target = _safe_resolve(root_key, rel_path)
    if target is None or not target.exists():
        return {"ok": False, "error": "chemin invalide"}
    if not target.is_dir():
        return {"ok": False, "error": "pas un dossier"}

    entries = []
    try:
        for child in sorted(target.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower())):
            if child.name in EXCLUDE_NAMES:
                continue
            entry = {
                "name": child.name,
                "path": str(child.relative_to(BROWSER_ROOTS[root_key])),
                "is_dir": child.is_dir(),
            }
            if not child.is_dir():
                try:
                    st = child.stat()
                    entry["size"] = st.st_size
                    entry["modified"] = int(st.st_mtime)
                except Exception:
                    pass
            entries.append(entry)
    except PermissionError:
        return {"ok": False, "error": "permission refusée"}

    return {
        "ok": True,
        "root": root_key,
        "path": rel_path,
        "entries": entries,
    }


def read_browser_file(root_key: str, rel_path: str) -> dict:
    target = _safe_resolve(root_key, rel_path)
    if target is None or not target.exists() or not target.is_file():
        return {"ok": False, "error": "fichier introuvable"}

    if target.stat().st_size > 1024 * 1024:
        return {"ok": False, "error": "fichier trop gros (>1 MB), ouvrez-le dans l'éditeur"}

    if target.suffix.lower() not in PREVIEWABLE_EXT and target.name not in {"README", "LICENSE", "Dockerfile", "Makefile"}:
        return {"ok": False, "error": "extension non prévisualisable"}

    try:
        content = target.read_text(encoding="utf-8", errors="replace")
        return {"ok": True, "content": content, "filename": target.name, "path": rel_path}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ----------------------------------------------------------------------------
# Embedded chat (claude -p en streaming SSE)
# ----------------------------------------------------------------------------

CHAT_HISTORY_FILE = HOME / ".local" / "share" / "jarvis" / "dashboard-chat.jsonl"


def append_chat_history(role: str, content: str) -> None:
    CHAT_HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(CHAT_HISTORY_FILE, "a") as f:
        f.write(json.dumps({
            "role": role,
            "content": content,
            "ts": datetime.now().isoformat(timespec="seconds"),
        }) + "\n")


def load_chat_history(limit: int = 20) -> list[dict]:
    if not CHAT_HISTORY_FILE.exists():
        return []
    try:
        lines = [l for l in CHAT_HISTORY_FILE.read_text().splitlines() if l.strip()]
        return [json.loads(l) for l in lines[-limit:]]
    except Exception:
        return []


def stream_chat(handler, message: str):
    """Stream une réponse claude -p au client via SSE."""
    if not message.strip():
        handler.send_response(400)
        handler.end_headers()
        return

    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream")
    handler.send_header("Cache-Control", "no-cache, no-store")
    handler.send_header("Connection", "keep-alive")
    handler.send_header("X-Accel-Buffering", "no")
    handler.end_headers()

    append_chat_history("user", message)
    push_event("chat", "Message dashboard envoyé à Jarvis", snippet=message[:80])

    history = load_chat_history(limit=10)
    history_text = ""
    for turn in history[:-1]:
        role = "le boss" if turn["role"] == "user" else "Vous (Jarvis)"
        history_text += f"\n## {role}\n{turn['content']}\n"

    system = (
        "Tu es Jarvis, le majordome du boss, accessible via le dashboard Control Room.\n"
        "Persona : vouvoiement, 'boss', réponses courtes (1-3 paragraphes par défaut), "
        "directes, pas de blabla. Markdown supporté.\n"
        "Tu as accès à tous les MCPs (Notion, Gmail, Calendar, Drive, Supabase, Vercel) "
        "et aux CLI Jarvis (jarvis-status, vault-search-v2, etc.).\n"
    )

    full_prompt = f"""{system}

# Contexte de la conversation
{history_text if history_text else "_(début de conversation)_"}

# Nouveau message du boss
{message}

# Instruction
Réponds directement en tant que Jarvis. Pas de préambule, pas de signature."""

    cmd = [
        str(LOCAL_BIN / "claude"),
        "--print",
        "--model", "sonnet",
        "--dangerously-skip-permissions",
        "--output-format", "stream-json",
        "--include-partial-messages",
        "--verbose",
    ]

    accumulated = ""
    try:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env={**os.environ, "JARVIS_CHAT_DASHBOARD": "1"},
        )
        proc.stdin.write(full_prompt.encode("utf-8"))
        proc.stdin.close()

        for line in proc.stdout:
            try:
                msg = json.loads(line.decode("utf-8").strip())
            except Exception:
                continue

            text_chunk = None
            if msg.get("type") == "stream_event":
                evt = msg.get("event", {})
                if evt.get("type") == "content_block_delta":
                    delta = evt.get("delta", {})
                    if delta.get("type") == "text_delta":
                        text_chunk = delta.get("text", "")

            if text_chunk:
                accumulated += text_chunk
                handler.wfile.write(f"data: {json.dumps({'chunk': text_chunk})}\n\n".encode())
                try: handler.wfile.flush()
                except: break

        proc.wait(timeout=10)
        handler.wfile.write(f"data: {json.dumps({'done': True, 'full': accumulated})}\n\n".encode())
        handler.wfile.flush()
        if accumulated.strip():
            append_chat_history("assistant", accumulated.strip())

    except (BrokenPipeError, ConnectionResetError):
        pass
    except Exception as e:
        try:
            handler.wfile.write(f"data: {json.dumps({'error': str(e)})}\n\n".encode())
            handler.wfile.flush()
        except: pass


def collect_logs_summary() -> list[dict]:
    """Quelques lignes des logs principaux."""
    logs = [
        ("Brief matinal", LOG_DIR / "jarvis-brief.log"),
        ("Routines", LOG_DIR / "jarvis-routine.log"),
        ("Bot Telegram", LOG_DIR / "jarvis-telegram-bot.log"),
        ("Notion mirror", LOG_DIR / "jarvis-notion-export.log"),
        ("Session-recap", LOG_DIR / "jarvis-session-recap.log"),
    ]
    out = []
    for name, path in logs:
        if not path.exists():
            out.append({"name": name, "exists": False})
            continue
        try:
            lines = path.read_text().splitlines()
            last = next((l for l in reversed(lines) if l.strip()), "")
            mtime = path.stat().st_mtime
            out.append({
                "name": name,
                "exists": True,
                "last_line": last[:300],
                "mtime": mtime,
                "size": path.stat().st_size,
            })
        except Exception:
            out.append({"name": name, "exists": False})
    return out


# ----------------------------------------------------------------------------
# HTTP Handler
# ----------------------------------------------------------------------------

# HTML pages — chargées depuis bin/ui/static/ (Phase 2 refacto MOS-004, 2026-05-09).
_STATIC_DIR = Path(__file__).resolve().parent / "ui" / "static"
_HTML_CACHE: dict[str, str] = {}


def _load_static_html(name: str) -> str:
    """Charge et cache une page HTML depuis bin/ui/static/<name>.html."""
    if name not in _HTML_CACHE:
        path = _STATIC_DIR / f"{name}.html"
        try:
            _HTML_CACHE[name] = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return f"<!DOCTYPE html><html><body><h1>500</h1><p>Static page {name} not found at {path}</p></body></html>"
    return _HTML_CACHE[name]


def _get_html_page() -> str:
    return _load_static_html("index")


def _get_agents_mesh_page() -> str:
    return _load_static_html("agents_mesh")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Mute default access logs

    def _json(self, data, code=200):
        body = json.dumps(data, default=str).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def _html(self, html):
        body = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _sse(self, since_id: int = 0):
        """Stream Server-Sent Events. Bloque la connexion tant qu'elle reste ouverte."""
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache, no-store")
            self.send_header("Connection", "keep-alive")
            self.send_header("X-Accel-Buffering", "no")
            self.end_headers()

            for evt in recent_events_since(since_id):
                self.wfile.write(f"id: {evt['id']}\ndata: {json.dumps(evt)}\n\n".encode())
                since_id = evt["id"]
            self.wfile.flush()

            last_heartbeat = time.time()
            while True:
                events = recent_events_since(since_id)
                if events:
                    for evt in events:
                        self.wfile.write(f"id: {evt['id']}\ndata: {json.dumps(evt)}\n\n".encode())
                        since_id = evt["id"]
                    self.wfile.flush()
                else:
                    if time.time() - last_heartbeat > 25:
                        self.wfile.write(b": heartbeat\n\n")
                        self.wfile.flush()
                        last_heartbeat = time.time()
                time.sleep(1)
        except (BrokenPipeError, ConnectionResetError):
            return

    def _static_asset(self, path: str) -> bool:
        """Sert un fichier de bin/ui/static/ si présent. Retourne True si servi."""
        rel = path.lstrip("/").removeprefix("static/")
        if "/" in rel or ".." in rel or not rel:
            return False
        ext = rel.rsplit(".", 1)[-1].lower() if "." in rel else ""
        mime = {"svg": "image/svg+xml", "ico": "image/x-icon",
                "png": "image/png", "css": "text/css", "js": "application/javascript"}.get(ext)
        if not mime:
            return False
        target = _STATIC_DIR / rel
        if not target.exists() or not target.is_file():
            return False
        body = target.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", mime + ("; charset=utf-8" if mime.startswith("text") or mime.endswith("xml") else ""))
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "public, max-age=3600")
        self.end_headers()
        self.wfile.write(body)
        return True

    def do_GET(self):
        path = urlparse(self.path).path
        try:
            if path == "/" or path == "/index.html":
                self._html(_get_html_page())
            elif path.startswith("/static/") and self._static_asset(path):
                return
            elif path == "/api/events":
                qs = urlparse(self.path).query
                last_id = 0
                for kv in qs.split("&"):
                    if kv.startswith("since="):
                        try: last_id = int(kv.split("=", 1)[1])
                        except: pass
                self._sse(last_id)
                return
            elif path == "/api/repos":
                self._json(collect_repos())
            elif path == "/api/debug/cfg":
                load_repos_config()
                _watchtower_load_projects()
                self._json({
                    "diagnostics": _CONFIG_DIAGNOSTICS,
                    "process": {
                        "pid": os.getpid(),
                        "started_at": _SERVER_STARTED_AT,
                        "uptime_seconds": time.time() - _SERVER_STARTED_TS,
                    },
                })
            elif path == "/api/domains":
                self._json(collect_domains())
            elif path == "/api/agents":
                self._json(collect_agents())
            elif path == "/api/subagents":
                self._json(collect_subagents())
            elif path == "/api/agent-topology":
                self._json(collect_agent_topology())
            elif path == "/agents" or path == "/agents/":
                self._html(_get_agents_mesh_page())
            elif path == "/api/briefs":
                self._json(collect_briefs())
            elif path == "/api/watchtower":
                self._json(collect_watchtower())
            elif path == "/api/watchtower/file":
                qs_dict = parse_qs(urlparse(self.path).query)
                params = {k: v[0] for k, v in qs_dict.items()}
                kind = params.get("kind", "summary")
                latest = _watchtower_latest_report_dir()
                if latest is None:
                    self._json({"error": "no report"}, 404)
                    return
                target = latest / ("summary.md" if kind == "summary" else "detail.md")
                if not target.exists():
                    self._json({"error": "not found"}, 404)
                    return
                self._json({
                    "path": str(target),
                    "report_date": latest.name,
                    "kind": kind,
                    "content": target.read_text(),
                    "modified": target.stat().st_mtime,
                })
            elif path == "/api/sessions":
                self._json(collect_sessions())
            elif path == "/api/telegram":
                self._json(collect_telegram_status())
            elif path == "/api/logs":
                self._json(collect_logs_summary())
            elif path == "/api/actions":
                self._json([
                    {"key": k, "label": v["label"], "background": v["spawn"]}
                    for k, v in ACTIONS.items()
                ])
            elif path == "/api/memory":
                self._json(collect_memory())
            elif path.startswith("/api/memory/file"):
                qs_dict = parse_qs(urlparse(self.path).query)
                params = {k: v[0] for k, v in qs_dict.items()}
                fn = params.get("name", "")
                proposed = params.get("proposed", "0") == "1"
                self._json(read_memory_file(fn, in_proposed=proposed))
            elif path == "/api/telemetry":
                self._json(collect_telemetry())
            elif path == "/api/browser":
                qs_dict = parse_qs(urlparse(self.path).query)
                params = {k: v[0] for k, v in qs_dict.items()}
                self._json(list_directory(
                    params.get("root", "vault"),
                    params.get("path", ""),
                ))
            elif path == "/api/browser/file":
                qs_dict = parse_qs(urlparse(self.path).query)
                params = {k: v[0] for k, v in qs_dict.items()}
                self._json(read_browser_file(
                    params.get("root", "vault"),
                    params.get("path", ""),
                ))
            elif path == "/api/browser/roots":
                self._json([
                    {"key": k, "label": k.replace("-", " ").title(), "path": str(p)}
                    for k, p in BROWSER_ROOTS.items() if p.exists()
                ])
            elif path == "/api/chat/history":
                self._json(load_chat_history(limit=30))
            else:
                self._json({"error": "not found"}, 404)
        except Exception as e:
            self._json({"error": str(e)}, 500)

    def do_POST(self):
        path = urlparse(self.path).path
        try:
            if path.startswith("/api/run/"):
                action = path[len("/api/run/"):]
                self._json(trigger_action(action))
            elif path == "/api/repos/category":
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length).decode("utf-8") if length else ""
                try:
                    payload = json.loads(raw)
                except Exception:
                    payload = {}
                repo = payload.get("repo", "")
                cat = payload.get("category", "")
                self._json(update_repo_category(repo, cat))
            elif path == "/api/repos/url":
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length).decode("utf-8") if length else ""
                try:
                    payload = json.loads(raw)
                except Exception:
                    payload = {}
                repo = payload.get("repo", "")
                url = payload.get("url", "")
                self._json(update_repo_url(repo, url))
            elif path == "/api/domains":
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length).decode("utf-8") if length else ""
                try:
                    payload = json.loads(raw)
                except Exception:
                    payload = {}
                self._json(upsert_domain(payload))
            elif path == "/api/domains/delete":
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length).decode("utf-8") if length else ""
                try:
                    payload = json.loads(raw)
                except Exception:
                    payload = {}
                self._json(delete_domain(payload.get("name", "")))
            elif path.startswith("/api/agents/") and path.endswith("/toggle"):
                label = path[len("/api/agents/"):-len("/toggle")]
                self._json(toggle_agent(label))
            elif path.startswith("/api/agents/") and path.endswith("/run"):
                label = path[len("/api/agents/"):-len("/run")]
                self._json(kickstart_agent(label))
            elif path == "/api/memory/promote":
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length).decode("utf-8") if length else ""
                try: payload = json.loads(raw)
                except: payload = {}
                self._json(promote_skill(payload.get("filename", "")))
            elif path == "/api/memory/reject":
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length).decode("utf-8") if length else ""
                try: payload = json.loads(raw)
                except: payload = {}
                self._json(reject_skill(payload.get("filename", "")))
            elif path == "/api/chat":
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length).decode("utf-8") if length else ""
                try: payload = json.loads(raw)
                except: payload = {}
                stream_chat(self, payload.get("message", ""))
                return
            else:
                self._json({"error": "not found"}, 404)
        except Exception as e:
            self._json({"error": str(e)}, 500)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=7474)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    ensure_watcher()
    print(f"Jarvis dashboard: http://{args.host}:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()

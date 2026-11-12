#!/usr/bin/env python3
"""Состояние ScanLab на реальном iPhone: устройство, версия, срок профиля.

Запускается сам по себе (без PowerShell):
    python tools/ios_status.py
    python tools/ios_status.py --json

Почему отдельный файл: разбор вывода `pymobiledevice3` строкой в PowerShell 5.1
уже дважды ломался (UTF-16 от `>`, кавычки в cmd, `$py`/`$Py` — одна переменная).
Python читает байты сам и отдаёт готовый вердикт.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

DEFAULT_UDID = "00008130-000A44C01443001C"
DEFAULT_BUNDLE = "com.scanlab.app.3CB3DRNXR2"
SIDELOADLY_DB = Path(os.environ.get("LOCALAPPDATA", "")) / "Sideloadly" / "installations.db"


def run(args: list[str], timeout: int = 120) -> tuple[int, str]:
    """Запускает pymobiledevice3 и возвращает (код, текст). Байты декодируем сами."""
    try:
        p = subprocess.run(args, capture_output=True, timeout=timeout)
    except FileNotFoundError:
        return 127, "pymobiledevice3 не найден"
    except subprocess.TimeoutExpired:
        return 124, "таймаут команды"
    text = (p.stdout or b"").decode("utf-8", "replace") + (p.stderr or b"").decode("utf-8", "replace")
    return p.returncode, text


def device_info(udid: str) -> dict:
    code, text = run([sys.executable, "-m", "pymobiledevice3", "usbmux", "list"])
    connected = udid in text
    info = {"connected": connected, "code": code}
    if connected:
        for line in text.splitlines():
            if udid in line:
                info["raw"] = line.strip().rstrip(",")
    return info


def app_info(udid: str, bundle: str) -> dict | None:
    code, text = run([sys.executable, "-m", "pymobiledevice3", "apps", "query", bundle, "--udid", udid])
    if code != 0:
        return None
    try:
        data = json.loads(text[text.index("{"):])
    except (ValueError, KeyError):
        return None
    app = data.get(bundle) or next(iter(data.values()), None)
    if not isinstance(app, dict):
        return None
    ent = app.get("Entitlements") or {}
    return {
        "bundle": app.get("CFBundleIdentifier"),
        "version": app.get("CFBundleShortVersionString"),
        "build": app.get("CFBundleVersion"),
        "name": app.get("CFBundleDisplayName"),
        "path": app.get("Path"),
        "team": ent.get("com.apple.developer.team-identifier"),
        "get_task_allow": ent.get("get-task-allow"),
        "min_os": app.get("MinimumOSVersion"),
    }


def profile_info(db_path: Path) -> dict | None:
    if not db_path.exists():
        return None
    try:
        db = sqlite3.connect(str(db_path))
        row = db.execute(
            "select name, version, last_updated, known_ttl, final_bundle_id, apple_id "
            "from installations order by id desc limit 1"
        ).fetchone()
    except sqlite3.Error as exc:
        return {"error": str(exc)}
    if not row:
        return {"error": "в базе нет установок"}
    name, version, updated, ttl, bundle, apple_id = row
    out = {
        "name": name,
        "db_version": version,
        "updated": str(updated)[:19],
        "ttl_days": ttl,
        "apple_id": apple_id,
        "final_bundle_id": bundle,
    }
    if updated and ttl:
        try:
            placed = dt.datetime.fromisoformat(str(updated)[:19])
            expires = placed + dt.timedelta(days=int(ttl))
            out["expires"] = expires.strftime("%d.%m.%Y %H:%M")
            out["expired"] = dt.datetime.now() > expires
        except ValueError:
            pass
    return out


def collect(udid: str, bundle: str) -> dict:
    dev = device_info(udid)
    return {
        "udid": udid,
        "bundle": bundle,
        "device": dev,
        "app": app_info(udid, bundle) if dev["connected"] else None,
        "profile": profile_info(SIDELOADLY_DB),
    }


def verdict(state: dict) -> tuple[str, str]:
    """(краткий вердикт, что делать)."""
    if not state["device"]["connected"]:
        return "телефон не подключён", "подключить кабелем и нажать «Доверять этому компьютеру»"
    app = state.get("app")
    if not app:
        return "ScanLab не установлен", "подписать и установить IPA через Sideloadly"
    prof = state.get("profile") or {}
    if prof.get("expired"):
        return (
            "профиль истёк — приложение не запустится",
            "переподписать свежей сборкой в Sideloadly (7 дней с момента установки)",
        )
    stale = prof.get("db_version") and app["version"] and prof["db_version"] != app["version"]
    if stale:
        return (
            f"на телефоне {app['version']} — это не та версия, что в базе Sideloadly",
            "поставить IPA из ветки builds",
        )
    return f"всё в порядке: {app['version']} (build {app['build']}), профиль жив", "работать"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", default=DEFAULT_UDID)
    ap.add_argument("--bundle", default=DEFAULT_BUNDLE)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    state = collect(args.udid, args.bundle)
    short, todo = verdict(state)

    if args.json:
        state["verdict"] = short
        state["next"] = todo
        print(json.dumps(state, ensure_ascii=False, indent=2))
        return 0 if "порядке" in short else 1

    dev = state["device"]
    print("=== ScanLab: состояние ===")
    print(f"UDID      : {state['udid']}")
    print(f"Bundle ID : {state['bundle']}")
    print("Устройство: " + ("подключено" if dev["connected"] else "НЕ подключено"))
    if dev.get("raw"):
        print("            " + dev["raw"])

    app = state.get("app")
    if app:
        print(f"Приложение: {app['name']} — {app['version']} (build {app['build']})")
        print(f"            {app['path']}")
        print(f"Подпись   : команда {app['team']}, get-task-allow={app['get_task_allow']}")
    else:
        print("Приложение: не установлено")

    prof = state.get("profile")
    if prof and prof.get("name"):
        print(f"Sideloadly: {prof['name']}, Apple ID {prof['apple_id']}")
        print(f"            выставлен {prof['updated']}, TTL {prof['ttl_days']} дн → {prof.get('expires', '?')}")
    elif prof and prof.get("error"):
        print(f"Sideloadly: {prof['error']}")
    else:
        print(f"Sideloadly: база не найдена ({SIDELOADLY_DB})")

    print(f"ВЕРДИКТ   : {short}")
    print(f"Дальше    : {todo}")
    return 0 if "порядке" in short else 1


if __name__ == "__main__":
    raise SystemExit(main())

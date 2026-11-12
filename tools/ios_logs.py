#!/usr/bin/env python3
"""Живые логи ScanLab с телефона: `syslog live` + фильтр, N секунд.

    python tools/ios_logs.py --seconds 20
    python tools/ios_logs.py --seconds 20 --pattern "ScanLab|scanlab|ARKit" --out logs/session.txt

Пишет: сколько всего строк, сколько совпало, последние совпадения и путь к полному логу.
Завершает `syslog live` сам (по таймауту), поэтому команда всегда возвращает управление.
"""

from __future__ import annotations

import argparse
import itertools
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

DEFAULT_UDID = "00008130-000A44C01443001C"
DEFAULT_PATTERN = r"ScanLab|scanlab|ScanLabApp"


def _head_lines(path: Path, limit: int = 5) -> list[str]:
    """Первые строки лога: там pymobiledevice3 печатает причину отказа."""
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            return [line.rstrip() for line in itertools.islice(handle, limit)]
    except OSError:
        return []


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", default=DEFAULT_UDID)
    ap.add_argument("--seconds", type=int, default=20)
    ap.add_argument("--pattern", default=DEFAULT_PATTERN)
    ap.add_argument("--out", default="", help="куда сохранить полный лог")
    ap.add_argument("--tail", type=int, default=30)
    args = ap.parse_args()

    out_path = Path(args.out) if args.out else Path("logs") / f"syslog-{time.strftime('%Y%m%d-%H%M%S')}.txt"
    try:
        out_path.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        # На Windows `mkdir(exist_ok=True)` всё равно бросает WinError 183, если
        # путь занят файлом (так остался %TEMP%\scanlab-logs от прежних прогонов).
        fallback = Path(tempfile.gettempdir()) / f"scanlab-syslog-{time.strftime('%Y%m%d-%H%M%S')}.txt"
        print(f"[logs] {out_path.parent} занят файлом — пишу в {fallback}")
        out_path = fallback

    cmd = [sys.executable, "-m", "pymobiledevice3", "syslog", "live", "--udid", args.udid]
    print(f"[logs] {args.seconds} с, фильтр: {args.pattern}")
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    started = time.time()
    total = 0
    hits: list[str] = []
    pattern = re.compile(args.pattern, re.IGNORECASE)

    # Читаем stdout в отдельном потоке: блокирующий readline() в главном цикле
    # игнорировал --seconds и висел, пока телефон не пришлёт строку.
    lines: "queue.Queue[bytes | None]" = queue.Queue()

    def reader() -> None:
        stream = proc.stdout
        if stream is None:
            lines.put(None)
            return
        for raw in stream:
            lines.put(raw)
        lines.put(None)

    threading.Thread(target=reader, daemon=True).start()

    try:
        with out_path.open("w", encoding="utf-8", errors="replace") as fh:
            while True:
                remaining = args.seconds - (time.time() - started)
                if remaining <= 0:
                    break
                try:
                    raw = lines.get(timeout=min(0.5, remaining))
                except queue.Empty:
                    if proc.poll() is not None and lines.empty():
                        break
                    continue
                if raw is None:
                    break
                text = raw.decode("utf-8", "replace").rstrip()
                total += 1
                fh.write(text + "\n")
                if pattern.search(text):
                    hits.append(text)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

    print(f"[logs] строк всего: {total}, совпало: {len(hits)}")
    for line in hits[-args.tail:]:
        print("  " + line)
    print(f"[logs] полный лог: {out_path}")
    if total == 0:
        print("[logs] пусто: телефон не отдаёт syslog (нет доверия/USB-соединения)")
        return 1
    if total <= 5 and any("no device" in line.lower() or "не найден" in line.lower()
                          for line in hits + _head_lines(out_path)):
        print("[logs] похоже, телефон не подключён: проверьте кабель и «Доверять»")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

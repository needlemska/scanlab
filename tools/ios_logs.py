#!/usr/bin/env python3
"""Живые логи ScanLab с телефона: `syslog live` + фильтр, N секунд.

    python tools/ios_logs.py --seconds 20
    python tools/ios_logs.py --seconds 20 --pattern "ScanLab|scanlab|ARKit" --out logs/session.txt

Пишет: сколько всего строк, сколько совпало, последние совпадения и путь к полному логу.
Завершает `syslog live` сам (по таймауту), поэтому команда всегда возвращает управление.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_UDID = "00008130-000A44C01443001C"
DEFAULT_PATTERN = r"ScanLab|scanlab|ScanLabApp"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", default=DEFAULT_UDID)
    ap.add_argument("--seconds", type=int, default=20)
    ap.add_argument("--pattern", default=DEFAULT_PATTERN)
    ap.add_argument("--out", default="", help="куда сохранить полный лог")
    ap.add_argument("--tail", type=int, default=30)
    args = ap.parse_args()

    out_path = Path(args.out) if args.out else Path("logs") / f"syslog-{time.strftime('%Y%m%d-%H%M%S')}.txt"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    cmd = [sys.executable, "-m", "pymobiledevice3", "syslog", "live", "--udid", args.udid]
    print(f"[logs] {args.seconds} с, фильтр: {args.pattern}")
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    started = time.time()
    total = 0
    hits: list[str] = []
    pattern = re.compile(args.pattern, re.IGNORECASE)
    try:
        with out_path.open("w", encoding="utf-8", errors="replace") as fh:
            while time.time() - started < args.seconds:
                line = proc.stdout.readline() if proc.stdout else b""
                if not line:
                    if proc.poll() is not None:
                        break
                    time.sleep(0.05)
                    continue
                text = line.decode("utf-8", "replace").rstrip()
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

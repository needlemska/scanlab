"""Run the on-device self-check and read its report without touching the phone.

The app can be told to run its checks from the launch environment
(`SCANLAB_DIAGNOSE=1`), and it writes `Documents/Scans/diagnostics-latest.txt`.
So the whole loop is: launch with the env var, wait for a fresh report, pull the
file over USB, parse PASS/FAIL lines, exit with a meaningful code.

Exit codes: 0 — all checks passed, 2 — some check failed, 3 — no fresh report.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import subprocess
import sys
import tempfile
import time

DEFAULT_UDID = "00008130-000A44C01443001C"
DEFAULT_BUNDLE = "com.scanlab.app.3CB3DRNXR2"
REPORT_REMOTE = "Documents/Scans/diagnostics-latest.txt"


def run(args: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-m", "pymobiledevice3"] + args,
        capture_output=True,
        timeout=timeout,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def launch(udid: str, bundle: str) -> str:
    """Start the app with the diagnostics trigger and return the tool output."""
    res = run(
        ["developer", "dvt", "launch", bundle, "--udid", udid, "--env", "SCANLAB_DIAGNOSE=1"],
        timeout=180,
    )
    text = (res.stdout or "") + (res.stderr or "")
    if "launched" not in text.lower() and res.returncode != 0:
        raise RuntimeError(f"launch failed: {text.strip()[:300]}")
    return text.strip()


def pull_report(udid: str, bundle: str) -> str | None:
    """Copy the report into a temp file and return its text."""
    target = pathlib.Path(tempfile.mkdtemp(prefix="scanlab-diag-")) / "diagnostics.txt"
    res = run(["apps", "pull", bundle, REPORT_REMOTE, str(target), "--udid", udid], timeout=180)
    if not target.exists() or target.stat().st_size == 0:
        return None
    text = target.read_text(encoding="utf-8", errors="replace")
    if res.returncode != 0 and "time:" not in text:
        return None
    return text


def report_time(text: str) -> dt.datetime | None:
    for line in text.splitlines():
        if line.startswith("time:"):
            raw = line.split(":", 1)[1].strip()
            try:
                return dt.datetime.fromisoformat(raw)
            except ValueError:
                return None
    return None


def parse_checks(text: str) -> list[dict]:
    checks = []
    for line in text.splitlines():
        parts = [p.strip() for p in line.split("|")]
        if len(parts) >= 3 and parts[0] in ("PASS", "FAIL"):
            checks.append({"passed": parts[0] == "PASS", "title": parts[1], "detail": parts[2]})
    return checks


def main() -> int:
    parser = argparse.ArgumentParser(description="Прогнать самопроверку ScanLab и прочитать отчёт")
    parser.add_argument("--udid", default=DEFAULT_UDID)
    parser.add_argument("--bundle", default=DEFAULT_BUNDLE)
    parser.add_argument("--timeout", type=int, default=180, help="сколько ждать свежий отчёт, с")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    started = dt.datetime.now().astimezone()
    print(f"[selfcheck] запускаю {args.bundle} с SCANLAB_DIAGNOSE=1")
    print("  " + launch(args.udid, args.bundle))

    deadline = time.time() + args.timeout
    text = None
    while time.time() < deadline:
        time.sleep(4)
        text = pull_report(args.udid, args.bundle)
        if not text:
            print("  отчёта ещё нет, ждём")
            continue
        stamp = report_time(text)
        if stamp is None or stamp >= started - dt.timedelta(minutes=2):
            break
        print(f"  отчёт старый ({stamp.isoformat()}), ждём новый")
        text = None

    if not text:
        print("[selfcheck] свежего отчёта нет: приложение не запустилось или не пишет файл")
        return 3

    checks = parse_checks(text)
    failed = [c for c in checks if not c["passed"]]
    if args.json:
        print(json.dumps({"checks": checks, "passed": len(checks) - len(failed), "failed": len(failed)},
                         ensure_ascii=False, indent=2))
    else:
        header = [line for line in text.splitlines() if not line.startswith(("PASS |", "FAIL |"))]
        print("\n".join(header))
        for check in checks:
            print(f"  {'PASS' if check['passed'] else 'FAIL'}  {check['title']}: {check['detail']}")
        print(f"[selfcheck] {len(checks) - len(failed)} из {len(checks)} проверок пройдено")
    return 0 if checks and not failed else 2


if __name__ == "__main__":
    sys.exit(main())

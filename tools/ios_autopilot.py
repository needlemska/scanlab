"""Полный проход сканера на телефоне без единого касания экрана.

С Windows нажать на экран iPhone нечем: DVT умеет запускать приложение, снимать
скриншот и читать логи, но тапов не передаёт. Поэтому приложение умеет автопилот
(см. `MeshScanView.runAutoPilot`): запускается с `SCANLAB_AUTO=<секунды>`, само
начинает скан, через N секунд останавливается, при желании калибруется эталоном
в кадре, экспортирует папку `lidar-…` и пишет `Documents/Scans/autopilot-latest.txt`.

Этот скрипт: запускает приложение с нужными переменными, ждёт свежий отчёт,
забирает его по USB и печатает результат.

Коды возврата: 0 — скан и экспорт прошли, 2 — автопилот отработал с ошибкой,
3 — свежего отчёта нет.
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
REPORT_REMOTE = "Documents/Scans/autopilot-latest.txt"


def run(args: list[str], timeout: int = 180) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-m", "pymobiledevice3"] + args,
        capture_output=True,
        timeout=timeout,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def launch(udid: str, bundle: str, seconds: float, reference: str | None) -> str:
    args = [
        "developer", "dvt", "launch", bundle, "--udid", udid,
        "--env", "SCANLAB_TAB=0",
        "--env", f"SCANLAB_AUTO={seconds:g}",
    ]
    if reference:
        args += ["--env", f"SCANLAB_AUTO_REF={reference}"]
    res = run(args)
    text = (res.stdout or "") + (res.stderr or "")
    if "launched" not in text.lower() and res.returncode != 0:
        raise RuntimeError(f"launch failed: {text.strip()[:300]}")
    return text.strip()


def pull_report(udid: str, bundle: str) -> dict | None:
    """Скопировать отчёт в temp и вернуть разобранный JSON (или None)."""
    target = pathlib.Path(tempfile.mkdtemp(prefix="scanlab-auto-")) / "autopilot.txt"
    run(["apps", "pull", bundle, REPORT_REMOTE, str(target), "--udid", udid])
    if not target.exists() or target.stat().st_size == 0:
        return None
    text = target.read_text(encoding="utf-8", errors="replace").strip()
    if not text.startswith("{"):
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def report_time(report: dict) -> dt.datetime | None:
    raw = report.get("time")
    if not isinstance(raw, str):
        return None
    try:
        return dt.datetime.fromisoformat(raw)
    except ValueError:
        return None


def mm(meters: float) -> str:
    return f"{meters * 1000:.1f}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Просканировать объект автопилотом и забрать отчёт")
    parser.add_argument("--udid", default=DEFAULT_UDID)
    parser.add_argument("--bundle", default=DEFAULT_BUNDLE)
    parser.add_argument("--seconds", type=float, default=25.0, help="сколько секунд сканировать")
    parser.add_argument("--reference", default=None, choices=["a4", "card", "coin"],
                        help="эталон в кадре для автокалибровки (необязательно)")
    parser.add_argument("--timeout", type=int, default=None, help="сколько ждать отчёт, с")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    timeout = args.timeout if args.timeout is not None else int(args.seconds) + 180
    started = dt.datetime.now().astimezone()
    print(f"[autopilot] запускаю {args.bundle}: скан {args.seconds:g} c"
          + (f", эталон {args.reference}" if args.reference else ", без калибровки"))
    print("  " + launch(args.udid, args.bundle, args.seconds, args.reference))

    deadline = time.time() + timeout
    report = None
    while time.time() < deadline:
        time.sleep(5)
        report = pull_report(args.udid, args.bundle)
        if report is None:
            print("  отчёта ещё нет, ждём")
            continue
        stamp = report_time(report)
        if stamp is None or stamp >= started - dt.timedelta(minutes=2):
            break
        print(f"  отчёт старый ({stamp.isoformat()}), ждём новый")
        report = None

    if report is None:
        print("[autopilot] свежего отчёта нет: приложение не запустилось или не пишет файл")
        return 3

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(f"  время: {report.get('time')} → {report.get('finishedAt')}")
        print(f"  скан: {report.get('scanSeconds')} c, экспорт: {report.get('exportSeconds')} c")
        print(f"  якорей {report.get('anchors')}, вершин {report.get('vertices')}, "
              f"треугольников {report.get('triangles')}")
        size = report.get("sizeMeters") or [0, 0, 0]
        print(f"  габарит меша: {mm(size[0])} × {mm(size[1])} × {mm(size[2])} мм")
        smart = report.get("smartMeters")
        if smart:
            print(f"  умный габарит: {mm(smart[0])} × {mm(smart[1])} × {mm(smart[2])} мм "
                  f"({report.get('smartMethod') or '—'})")
        else:
            print(f"  умный габарит: нет ({report.get('status')})")
        factor = report.get("calibrationFactor")
        if report.get("reference"):
            print(f"  калибровка по эталону {report['reference']}: поправка ×{factor}")
        else:
            print(f"  калибровка: без эталона, поправка ×{factor}")
        if report.get("archive"):
            print(f"  архив: {report['archive']}")
        if report.get("error"):
            print(f"  ошибка: {report['error']}")
        print(f"[autopilot] результат: {report.get('result')}")

    return 0 if report.get("result") == "ok" else 2


if __name__ == "__main__":
    sys.exit(main())

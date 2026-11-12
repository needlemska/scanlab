"""Выбрать UDID первого доступного iPhone-симулятора на macOS-раннере."""
import json
import subprocess
import sys


def main() -> int:
    raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
    data = json.loads(raw)
    for runtime, devices in data.get("devices", {}).items():
        for dev in devices:
            if dev.get("name", "").startswith("iPhone"):
                print(dev["udid"])
                print(f"# {dev['name']} / {runtime}", file=sys.stderr)
                return 0
    print("no iPhone simulator found", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

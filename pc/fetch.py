#!/usr/bin/env python3
"""Скачивание сканов с телефона по Wi-Fi.

В приложении ScanLab откройте «Библиотека» и нажмите значок Wi-Fi — на экране
появится адрес вида http://192.168.0.57:8080. Телефон и компьютер должны быть
в одной сети.

    python pc/fetch.py --url http://192.168.0.57:8080
    python pc/fetch.py --url http://192.168.0.57:8080 --out pc/out/phone
    python pc/fetch.py --url http://192.168.0.57:8080 --new-only

Вывод намеренно на английском и в ASCII: под Windows перенаправленный вывод
попадает в консольную кодировку (cp866/cp1251) и русский текст превращается
в мусор, который невозможно читать ни человеку, ни скрипту.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

LINK_RE = re.compile(r'href="(/zip/[^"]+)"')


def normalize_url(url: str) -> str:
    url = url.strip()
    if not url.startswith(("http://", "https://")):
        url = "http://" + url
    return url.rstrip("/")


def list_links(base: str, timeout: float = 15.0) -> list[str]:
    with urllib.request.urlopen(base + "/", timeout=timeout) as response:
        html = response.read().decode("utf-8", "replace")
    return sorted(set(LINK_RE.findall(html)))


def scan_name(href: str) -> str:
    return urllib.parse.unquote(href.rsplit("/", 1)[-1])


def target_path(out_dir: str, href: str) -> str:
    raw = scan_name(href)
    if not raw.endswith(".zip"):
        raw += ".zip"
    return os.path.join(out_dir, raw)


def human_size(size: int) -> str:
    if size < 1024:
        return f"{size} B"
    if size < 1_048_576:
        return f"{size / 1024:.1f} KB"
    return f"{size / 1_048_576:.1f} MB"


def ascii_text(value: str) -> str:
    """Системные тексты Windows приходят в cp1251 — в ASCII-вывод их нельзя пускать как есть."""
    return value.encode("ascii", "replace").decode("ascii")


def describe(error: Exception) -> str:
    """Понятная причина вместо локализованного текста Windows."""
    reason = getattr(error, "reason", error)
    winerror = getattr(reason, "winerror", None)
    if winerror == 10061:
        return "connection refused - check the IP and that the Wi-Fi server is on"
    if winerror in (10060, 10065, 11001):
        return "host unreachable - both devices must be on the same Wi-Fi"
    return ascii_text(f"{type(reason).__name__}: {reason}")


def download(base: str, href: str, out_dir: str, timeout: float = 600.0) -> tuple[str, int, bool]:
    path = target_path(out_dir, href)
    if os.path.exists(path):
        return path, os.path.getsize(path), False

    url = base + href
    temporary = path + ".part"
    total = 0
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response, open(temporary, "wb") as handle:
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                handle.write(chunk)
                total += len(chunk)
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.remove(temporary)
        raise
    return path, total, True


def main() -> int:
    parser = argparse.ArgumentParser(description="Download scans from iPhone over Wi-Fi")
    parser.add_argument("--url", required=True, help="address shown in the Library tab, e.g. http://192.168.0.57:8080")
    parser.add_argument("--out", default=os.path.join("pc", "out", "phone"), help="output folder (default pc/out/phone)")
    parser.add_argument("--new-only", action="store_true", help="skip files that are already downloaded")
    parser.add_argument("--list", action="store_true", help="only print what is on the phone")
    args = parser.parse_args()

    base = normalize_url(args.url)
    try:
        links = list_links(base)
    except urllib.error.URLError as error:
        print(f"Cannot reach {base}: {describe(error)}")
        print("Check: same Wi-Fi, server switched on (Wi-Fi icon in Library), port 8080, IP from the phone screen.")
        return 2

    if not links:
        print("Phone has no scans yet.")
        return 0

    print(f"Phone has {len(links)} scan(s):")
    for href in links:
        print("  " + scan_name(href))

    if args.list:
        return 0

    os.makedirs(args.out, exist_ok=True)
    print(f"Saving to {os.path.abspath(args.out)}")

    failures = 0
    for href in links:
        name = scan_name(href)
        if args.new_only and os.path.exists(target_path(args.out, href)):
            print(f"  = {name} already downloaded")
            continue
        try:
            path, size, fresh = download(base, href, args.out)
        except urllib.error.URLError as error:
            failures += 1
            print(f"  ! {name}: {describe(error)}")
            continue
        mark = "+" if fresh else "="
        print(f"  {mark} {os.path.basename(path)}  {human_size(size)}")

    print("Done." if failures == 0 else f"Done, but {failures} file(s) failed.")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

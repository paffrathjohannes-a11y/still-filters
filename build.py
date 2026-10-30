#!/usr/bin/env python3
"""Baut die Still-Blocker aus freien Listen, prüft sie mit WebKit und legt sie zur Veröffentlichung ab.

Ablauf (auch lokal ausführbar: `swift build -c release && python3 build.py`):
1. Alle Quellen aus lists.json laden und ihre Lizenzangabe prüfen.
2. Mit still-check konvertieren: privacy.json, ads.json und ads-<sprache>.json (Basis + Sprachliste).
3. Mit WebKit prüfen (Testseite + echte Seiten + YouTube mit dem Skript der Video-Erweiterung).
4. Gegen die zuletzt veröffentlichte Fassung vergleichen: Regelzahl darf nicht um > 20 % einbrechen.
5. Domainliste für den Schutz in allen Apps ableiten (domains.py) und prüfen: bekannte Werbeserver drin,
   wichtige Dienste (Apple, Google, Microsoft, Banken …) nie.
6. Nur wenn alle harten Prüfungen bestehen: public/v1 mit manifest.json schreiben (Exit 0).
   Echte Seiten sind weich: Ausfälle landen in warnings.md (wird zum Issue), blockieren aber nicht.
"""
import datetime
import hashlib
import json
import pathlib
import subprocess
import sys
import urllib.request

import domains as dns

ROOT = pathlib.Path(__file__).resolve().parent
CONFIG = json.loads((ROOT / "lists.json").read_text())
BIN = ROOT / ".build/release/still-check"
WORK = ROOT / ".build/lists"
OUT = ROOT / "public/v1"
PUBLISHED = "https://paffrathjohannes-a11y.github.io/still-filters/v1/manifest.json"
MAX_DROP = 0.2

failures: list[str] = []
warnings: list[str] = []


def fetch(source_id: str) -> pathlib.Path:
    source = CONFIG["sources"][source_id]
    path = WORK / f"{source_id}.txt"
    request = urllib.request.Request(source["url"], headers={"User-Agent": "still-filters (+https://github.com/paffrathjohannes-a11y/still-filters)"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
    path.write_bytes(data)
    head = data[:6000].decode("utf-8", errors="replace")
    marker = source.get("licenceMarker")
    if marker and marker.lower() not in head.lower():
        failures.append(f"Lizenzangabe von {source['name']} hat sich geändert (erwartet „{marker}“) – Liste nicht verwendet")
    lines = sum(1 for line in data.splitlines() if line and not line.startswith(b"!"))
    if lines < 100:
        failures.append(f"{source['name']}: nur {lines} Regeln geladen")
    return path


def convert(name: str, sources: list[str], paths: dict[str, pathlib.Path]) -> dict:
    out = OUT / f"{name}.json"
    args = [str(BIN), "convert", "--out", str(out)] + [str(paths[s]) for s in sources]
    result = subprocess.run(args, capture_output=True, text=True, timeout=900)
    (WORK / f"convert-{name}.log").write_text(result.stdout + result.stderr)
    if result.returncode != 0 or not out.exists():
        failures.append(f"Konvertierung {name} fehlgeschlagen")
        return {}
    stats_file = out.with_suffix(".stats.json")
    stats = json.loads(stats_file.read_text())
    stats_file.unlink()
    data = out.read_bytes()
    return {"file": out.name, "rules": stats["safariRules"], "sha256": hashlib.sha256(data).hexdigest(),
            "bytes": len(data), "sources": sources, "unsupported": stats.get("unsupported", {})}


def main() -> int:
    WORK.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)

    needed = set(CONFIG["languages"].values())
    for blocker in CONFIG["blockers"].values():
        needed.update(blocker)
    paths = {}
    for source_id in sorted(needed):
        try:
            paths[source_id] = fetch(source_id)
        except Exception as error:  # Netzfehler
            failures.append(f"{CONFIG['sources'][source_id]['name']} nicht ladbar: {error}")
    if failures:
        return finish({})

    outputs = {"privacy": convert("privacy", CONFIG["blockers"]["privacy"], paths),
               "ads": convert("ads", CONFIG["blockers"]["ads"], paths)}
    variants = {}
    for code, source_id in sorted(CONFIG["languages"].items()):
        name = f"ads-{source_id.removeprefix('lang-')}"
        if name not in variants:
            variants[name] = convert(name, CONFIG["blockers"]["ads"] + [source_id], paths)
    for name, info in {**outputs, **variants}.items():
        if info and info["rules"] > 150_000:
            failures.append(f"{name}: {info['rules']} Regeln über Safaris Limit")

    # Prüfung mit WebKit (Basis-Werbung + Privatsphäre, dazu die deutsche Variante als größte Sprachkombination)
    verify = subprocess.run([str(BIN), "verify", "--report", str(WORK / "report"),
                             "--video-script", str(ROOT / "video/youtube-main.js"),
                             str(OUT / "ads.json"), str(OUT / "privacy.json")],
                            capture_output=True, text=True, timeout=1800)
    (WORK / "verify.log").write_text(verify.stdout + verify.stderr)
    report_json = WORK / "report/report.json"
    if not report_json.exists():
        failures.append("WebKit-Prüfung lieferte keinen Bericht")
    else:
        for result in json.loads(report_json.read_text()):
            if not result["meaningful"] or result["passed"]:
                continue
            # Echte Seiten und YouTube sind weich: Sie melden sich als Issue, halten die Listen aber nicht auf
            soft = result["name"].startswith(("http", "YouTube")) or result["name"] == "Genug aussagekräftige echte Seiten"
            (warnings if soft else failures).append(f"{result['name']}: " + "; ".join(result["details"]))
        (OUT / "report.md").write_text((WORK / "report/report.md").read_text())

    # Vergleich mit der veröffentlichten Fassung
    try:
        with urllib.request.urlopen(PUBLISHED, timeout=30) as response:
            previous = json.loads(response.read())
        for name, info in {**outputs, **variants}.items():
            old = previous.get("blockers", {}).get(name, {}).get("rules")
            if info and old and info["rules"] < old * (1 - MAX_DROP):
                failures.append(f"{name}: Regelzahl eingebrochen ({old} → {info['rules']})")
    except Exception:
        warnings.append("Veröffentlichte Fassung nicht abrufbar – kein Vergleich der Regelzahlen (beim ersten Lauf normal)")

    # Domainliste für den Schutz in allen Apps (DNS auf dem Gerät)
    lines = []
    for source_id in CONFIG["blockers"]["ads"] + CONFIG["blockers"]["privacy"]:
        lines += paths[source_id].read_text(encoding="utf-8", errors="replace").splitlines()
    extra = [l.strip() for l in (ROOT / "dns-extra.txt").read_text().splitlines() if l.strip() and not l.startswith("#")]
    domain_list = dns.build(lines, extra)
    domain_set = set(domain_list)
    missing = [d for d in dns.MUST_BLOCK if not dns.is_blocked(d, domain_set)]
    wrong = [d for d in dns.MUST_NOT_BLOCK if dns.is_blocked(d, domain_set)]
    if missing:
        failures.append("DNS-Liste blockt bekannte Werbeserver nicht: " + ", ".join(missing))
    if wrong:
        failures.append("DNS-Liste würde wichtige Dienste sperren: " + ", ".join(wrong))
    data = ("\n".join(domain_list) + "\n").encode()
    (OUT / "domains.txt").write_bytes(data)
    dns_info = {"file": "domains.txt", "count": len(domain_list), "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}

    return finish({**outputs, **variants}, dns_info)


def finish(blockers: dict, dns_info: dict | None = None) -> int:
    languages = {code: f"ads-{source_id.removeprefix('lang-')}" for code, source_id in CONFIG["languages"].items()}
    manifest = {
        "version": 1,
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "blockers": blockers,
        "languages": languages,
        "dns": dns_info,
        "attribution": [{"name": s["name"], "licence": s["licence"], "url": s["url"]} for s in CONFIG["sources"].values()],
    }
    (WORK / "warnings.md").write_text("\n".join(f"- {w}" for w in warnings))
    (WORK / "failures.md").write_text("\n".join(f"- {f}" for f in failures))
    for line in failures:
        print("FEHLER:", line)
    for line in warnings:
        print("WARNUNG:", line)
    if failures:
        return 1
    video = json.loads((ROOT / "video/video.json").read_text())
    video.pop("comment", None)
    (OUT / "video.json").write_text(json.dumps(video, ensure_ascii=False))
    (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1))
    # Datenschutz- und Hilfeseite der App
    for page in (ROOT / "site").iterdir():
        (ROOT / "public" / page.name).write_bytes(page.read_bytes())
    (ROOT / "public/index.html").write_text(
        "<!doctype html><meta charset=utf-8><title>Still filters</title>"
        "<p>Safari content blocker lists for the Still app, built daily from free filter lists. "
        "See <a href='v1/manifest.json'>manifest</a> and <a href='v1/report.md'>latest check</a>.</p>")
    print(f"OK: {len(blockers)} Blocker, {sum(b.get('rules', 0) for b in blockers.values())} Regeln insgesamt")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""MacToys localization pipeline.

  scripts/i18n.py sync                  build, then merge every target's .stringsdata into the catalog
  scripts/i18n.py status                translated / total per language
  scripts/i18n.py export <lang> <file>  untranslated (or --all) strings as compact JSON for translators
  scripts/i18n.py import <lang> <file>  merge a translations JSON back, validating placeholders
  scripts/i18n.py compile <resources-dir> [--pseudo]
                                        write <lang>.lproj/{Localizable,InfoPlist}.strings(+dict);
                                        --pseudo adds an "eo" pseudo-language that wraps every
                                        localized string in ⟦…⟧ so unlocalized text stands out
  scripts/i18n.py languages             languages to declare in CFBundleLocalizations
  scripts/i18n.py export-chunks <lang> <dir> [--size N] [--all] [--plural-only]
                                        untranslated strings in numbered chunks with short ids:
                                        <dir>/chunk-001.json = [{"id", "en", "comment"?, "plural"?}]
  scripts/i18n.py import-chunks <lang> <dir>
                                        merge <dir>/chunk-NNN.<lang>.json = {"id": "text" | {"one": …, "other": …}}

The source of truth is Resources/Localization/*.xcstrings (String Catalogs, editable in Xcode).
The compiler extracts keys from string literals passed to LocalizedStringKey, LocalizedStringResource
and String.LocalizationValue parameters (Package.swift adds -emit-localized-strings to every target).
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG_DIR = ROOT / "Resources" / "Localization"
CATALOG = CATALOG_DIR / "Localizable.xcstrings"
INFOPLIST_CATALOG = CATALOG_DIR / "InfoPlist.xcstrings"
STRINGS_DIR = ROOT / ".build" / "strings"
PSEUDO = "eo"

# Every language MacToys ships. Add one here and translate it; nothing else needs to change.
LANGUAGES = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es", "pt-BR", "it", "ru"]

# printf-style specifiers as Foundation formats them (positional, flags, width, length).
SPEC = re.compile(r"%(?:\d+\$)?[-+ 0#']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGcCsSpaA%]")


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")


def specs(text):
    """Placeholder signature: positional ones by index, others in order; %% ignored."""
    out = []
    for i, m in enumerate(s for s in SPEC.findall(text) if s != "%%"):
        pos = re.match(r"%(\d+)\$", m)
        conv = re.sub(r"^%(?:\d+\$)?[-+ 0#']*\d*(?:\.\d+)?", "", m)
        conv = {"d": "lld", "ld": "lld", "i": "lld", "qd": "lld", "lu": "llu"}.get(conv, conv)
        out.append((int(pos.group(1)) if pos else i + 1, conv))
    return sorted(out)


def sync():
    subprocess.run(["swift", "build"], cwd=ROOT, check=True)
    files = sorted(str(p) for p in STRINGS_DIR.rglob("*.stringsdata") if "MacToysTests" not in p.parts)
    if not CATALOG.exists():
        CATALOG_DIR.mkdir(parents=True, exist_ok=True)
        save(CATALOG, {"sourceLanguage": "en", "strings": {}, "version": "1.0"})
    args = ["xcrun", "xcstringstool", "sync", str(CATALOG)]
    for f in files:
        args += ["--stringsdata", f]
    subprocess.run(args, check=True)
    # xcstringstool keeps keys that disappeared as "stale"; drop them so translators never see dead text.
    data = load(CATALOG)
    stale = [k for k, v in data["strings"].items() if v.get("extractionState") == "stale"]
    for k in stale:
        del data["strings"][k]
    save(CATALOG, data)
    print(f"{len(data['strings'])} keys ({len(stale)} stale removed) from {len(files)} source files")


def unit_value(loc):
    if "stringUnit" in loc:
        return loc["stringUnit"].get("value")
    return None


def status():
    data = load(CATALOG)
    keys = [k for k, v in data["strings"].items() if v.get("shouldTranslate", True)]
    print(f"{len(keys)} translatable keys")
    for lang in LANGUAGES[1:]:
        done = sum(1 for k in keys if lang in data["strings"][k].get("localizations", {}))
        print(f"  {lang:8} {done:5}  {100 * done // max(1, len(keys)):3}%")
    if INFOPLIST_CATALOG.exists():
        ip = load(INFOPLIST_CATALOG)
        print(f"InfoPlist: {len(ip['strings'])} keys, languages: "
              + ", ".join(sorted({l for v in ip['strings'].values() for l in v.get('localizations', {})})))


def source_text(key, entry):
    en = entry.get("localizations", {}).get("en")
    if en and unit_value(en):
        return unit_value(en)
    return key


def export(lang, path, include_all=False, catalog=CATALOG):
    data = load(catalog)
    out = {}
    for key, entry in sorted(data["strings"].items()):
        if not entry.get("shouldTranslate", True):
            continue
        if not include_all and lang in entry.get("localizations", {}):
            continue
        item = {"en": source_text(key, entry)}
        if entry.get("comment"):
            item["comment"] = entry["comment"]
        if any(c in ("lld", "llu", "ld", "d") for _, c in specs(key)):
            item["plural"] = "optional: give an object of CLDR categories (one, few, many, other…) instead of a string"
        out[key] = item
    save(Path(path), out)
    print(f"exported {len(out)} strings for {lang} to {path}")


def import_(lang, path, catalog=CATALOG):
    data = load(catalog)
    translations = load(path)
    problems, added = [], 0
    for key, value in translations.items():
        entry = data["strings"].get(key)
        if entry is None:
            problems.append(f"unknown key: {key!r}")
            continue
        src = source_text(key, entry)
        forms = value if isinstance(value, dict) else {"other": value}
        bad = False
        for form, text in forms.items():
            if not isinstance(text, str) or not text.strip():
                problems.append(f"empty {form} for {key!r}")
                bad = True
                continue
            # Plural "one" forms may drop the number ("1 file" → "a file"); everything else must keep them.
            if specs(text) != specs(src) and not (isinstance(value, dict) and form != "other"):
                problems.append(f"placeholders differ for {key!r}: {text!r}")
                bad = True
        if bad:
            continue
        locs = entry.setdefault("localizations", {})
        if isinstance(value, dict):
            locs[lang] = {"variations": {"plural": {f: {"stringUnit": {"state": "translated", "value": t}}
                                                    for f, t in value.items()}}}
        else:
            locs[lang] = {"stringUnit": {"state": "translated", "value": value}}
        added += 1
    save(catalog, data)
    print(f"imported {added} {lang} strings into {catalog.name}")
    for p in problems[:50]:
        print("  !", p)
    if problems:
        print(f"  {len(problems)} problem(s) skipped")
    return 0 if not problems else 1


ACCENTS = str.maketrans("aceinoruyAEIOUCN", "áçéîñöŕûýÁÉÎÖÛÇÑ")


def pseudo(text):
    parts, last = [], 0
    for m in SPEC.finditer(text):
        parts.append(text[last:m.start()].translate(ACCENTS))
        parts.append(m.group(0))
        last = m.end()
    parts.append(text[last:].translate(ACCENTS))
    return "⟦" + "".join(parts) + "⟧"


def with_pseudo(catalog):
    data = load(catalog)
    for key, entry in data["strings"].items():
        if entry.get("shouldTranslate", True) and key.strip():
            entry.setdefault("localizations", {})[PSEUDO] = {
                "stringUnit": {"state": "translated", "value": pseudo(source_text(key, entry))}}
    return data


def compile_(resources, use_pseudo=False):
    resources = Path(resources)
    resources.mkdir(parents=True, exist_ok=True)
    for catalog in (CATALOG, INFOPLIST_CATALOG):
        if not catalog.exists():
            continue
        src = catalog
        if use_pseudo:
            tmp = Path(tempfile.mkdtemp()) / catalog.name
            save(tmp, with_pseudo(catalog))
            src = tmp
        subprocess.run(["xcrun", "xcstringstool", "compile", str(src), "--output-directory", str(resources)],
                       check=True, stdout=subprocess.DEVNULL)
    # Every shipped language gets an .lproj (even before it is translated) so the system language
    # menu and Bundle.preferredLocalizations see it.
    for lang in LANGUAGES + ([PSEUDO] if use_pseudo else []):
        (resources / f"{lang}.lproj").mkdir(exist_ok=True)


def export_chunks(lang, folder, size=200, include_all=False, plural_only=False):
    data = load(CATALOG)
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    items, ids = [], {}
    for key, entry in sorted(data["strings"].items()):
        if not entry.get("shouldTranslate", True) or not key.strip():
            continue
        # Keys with nothing but placeholders, symbols and digits ("$", "%lld%%", "⌘ %@") stay as they are.
        if not re.search(r"[^\W\d_]", SPEC.sub("", key)):
            continue
        has_int = any(c in ("lld", "llu") for _, c in specs(key))
        if plural_only and not has_int:
            continue
        if not include_all and lang in entry.get("localizations", {}):
            continue
        i = str(len(ids) + 1)
        ids[i] = key
        item = {"id": i, "en": source_text(key, entry)}
        if entry.get("comment"):
            item["comment"] = entry["comment"]
        if has_int:
            item["plural"] = True
        items.append(item)
    for n in range(0, len(items), size):
        save(folder / f"chunk-{n // size + 1:03}.json", items[n:n + size])
    save(folder / "ids.json", ids)
    print(f"exported {len(items)} strings for {lang} into {(len(items) + size - 1) // size} chunks in {folder}")


def import_chunks(lang, folder):
    folder = Path(folder)
    ids = load(folder / "ids.json")
    merged = {}
    for f in sorted(folder.glob(f"chunk-*.{lang}.json")):
        for i, value in load(f).items():
            if i in ids:
                merged[ids[i]] = value
            else:
                print(f"  ! {f.name}: unknown id {i}")
    tmp = Path(tempfile.mkdtemp()) / "merged.json"
    save(tmp, merged)
    missing = len(ids) - len(merged)
    status = import_(lang, tmp)
    if missing:
        print(f"  {missing} of {len(ids)} strings have no translation yet")
    return status


def languages():
    print(" ".join(LANGUAGES))


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    cmd = argv[1]
    if cmd == "sync":
        sync()
    elif cmd == "status":
        status()
    elif cmd == "export":
        export(argv[2], argv[3], include_all="--all" in argv,
               catalog=INFOPLIST_CATALOG if "--infoplist" in argv else CATALOG)
    elif cmd == "import":
        return import_(argv[2], argv[3], catalog=INFOPLIST_CATALOG if "--infoplist" in argv else CATALOG)
    elif cmd == "compile":
        compile_(argv[2], use_pseudo="--pseudo" in argv)
    elif cmd == "languages":
        languages()
    elif cmd == "export-chunks":
        size = int(argv[argv.index("--size") + 1]) if "--size" in argv else 200
        export_chunks(argv[2], argv[3], size=size, include_all="--all" in argv, plural_only="--plural-only" in argv)
    elif cmd == "import-chunks":
        return import_chunks(argv[2], argv[3])
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

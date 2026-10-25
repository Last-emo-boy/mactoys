#!/usr/bin/env python3
"""Find (and with --fix, rewrite) Core component calls whose localized title would be shown verbatim.

`RowLabel("Title", subtitle: path)` resolves to the all-verbatim overload because `path` is a runtime
String (see the comment in MacToysCore/UI/SettingsPage.swift). The fix is the explicit label:
`RowLabel("Title", verbatimSubtitle: path)`. The same applies to ShortcutRow, ColorRow, SliderRow
(`subtitle:`) and InfoBar (`message:` → `verbatimMessage:`).

A subtitle counts as runtime when it isn't a string literal, `nil`, a `Text(…)` or a ternary/expression
that only yields those. Ambiguous expressions are reported, not rewritten.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CALL = re.compile(r'\b(RowLabel|ShortcutRow|ColorRow|SliderRow|InfoBar)\(')


def split_args(src, start):
    """Return (end index of the call, list of (label, value, value_start, value_end)) for the call at `start`."""
    depth, i, args, cur_start = 0, start, [], start
    in_str = False
    while i < len(src):
        c = src[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth < 0:
                args.append((cur_start, i))
                return i, args
        elif c == "," and depth == 0:
            args.append((cur_start, i))
            cur_start = i + 1
        i += 1
    return None, []


def classify(value):
    v = value.strip()
    # A literal, possibly with interpolations that contain their own quotes.
    if v == "nil" or (v.startswith('"') and v.endswith('"')) or (v.startswith('"""') and v.endswith('"""')):
        return "literal"
    if v.startswith("Text(") or v.startswith("Text."):
        return "text"
    if "?" in v and ":" in v:
        return "ternary"
    return "runtime"


def scan(path, fix):
    src = path.read_text(encoding="utf-8")
    edits, reports = [], []
    for m in CALL.finditer(src):
        name = m.group(1)
        end, spans = split_args(src, m.end())
        if end is None or not spans:
            continue
        parts = [src[a:b] for a, b in spans]
        first = parts[0].strip()
        if not re.fullmatch(r'"(?:[^"\\]|\\.)*"', first, re.S) and not (name == "InfoBar" and len(parts) > 1):
            continue
        if name == "InfoBar":
            labels = {p.split(":", 1)[0].strip(): (p, spans[i]) for i, p in enumerate(parts) if ":" in p}
            title = labels.get("title")
            if not title or not re.fullmatch(r'\s*title:\s*"(?:[^"\\]|\\.)*"\s*', title[0], re.S):
                continue
            target, new_label = labels.get("message"), "verbatimMessage"
        else:
            target = next(((p, spans[i]) for i, p in enumerate(parts) if p.strip().startswith("subtitle:")), None)
            new_label = "verbatimSubtitle"
        if not target:
            continue
        value = target[0].split(":", 1)[1]
        kind = classify(value)
        line = src.count("\n", 0, m.start()) + 1
        if kind == "runtime":
            a, b = target[1]
            old = src[a:b]
            label = "message" if name == "InfoBar" else "subtitle"
            edits.append((a, b, old.replace(f"{label}:", f"{new_label}:", 1)))
            reports.append(f"{path.relative_to(ROOT)}:{line}: {name} {label}: {value.strip()[:60]}")
        elif kind == "ternary" and not re.search(r'"|\bnil\b', value):
            reports.append(f"{path.relative_to(ROOT)}:{line}: CHECK {name} ternary: {value.strip()[:60]}")
    if fix and edits:
        for a, b, new in sorted(edits, reverse=True):
            src = src[:a] + new + src[b:]
        path.write_text(src, encoding="utf-8")
    return reports


def main():
    fix = "--fix" in sys.argv
    reports = []
    for p in sorted((ROOT / "Sources").rglob("*.swift")):
        if "MacToysCore/UI/SettingsPage.swift" in str(p):
            continue
        reports += scan(p, fix)
    for r in reports:
        print(r)
    print(f"{len(reports)} call(s) {'rewritten' if fix else 'found'}")


if __name__ == "__main__":
    main()

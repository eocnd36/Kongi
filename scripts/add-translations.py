#!/usr/bin/env python3
"""Append translations to Resources/<lang>.lproj/Localizable.strings.

    python3 scripts/add-translations.py translations.json "Section name"

translations.json looks like {"ko": {"English key": "번역", ...}, "ja": {...}}.
Keys that already exist in a file are replaced in place; new keys are appended under the section comment.
Run scripts/check-localizations.py afterwards.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')


def escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def main() -> None:
    translations = json.loads(pathlib.Path(sys.argv[1]).read_text())
    section = sys.argv[2] if len(sys.argv) > 2 else "Additions"
    for language, entries in translations.items():
        path = ROOT / "Resources" / f"{language}.lproj" / "Localizable.strings"
        lines = path.read_text().splitlines()
        remaining = dict(entries)
        for index, line in enumerate(lines):
            match = ENTRY.match(line.strip())
            if match and match.group(1).replace('\\"', '"') in remaining:
                key = match.group(1).replace('\\"', '"')
                lines[index] = f'"{escape(key)}" = "{escape(remaining.pop(key))}";'
        if remaining:
            lines += ["", f"/* {section} */"]
            lines += [f'"{escape(key)}" = "{escape(value)}";' for key, value in remaining.items()]
        path.write_text("\n".join(lines) + "\n")
        print(f"{language}: {len(entries)} entries")


if __name__ == "__main__":
    main()

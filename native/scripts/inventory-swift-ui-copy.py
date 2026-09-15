#!/usr/bin/env python3
"""Create/check an exact Markdown inventory of visible SwiftUI string literals."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

CALLS = (
    "Text",
    "Label",
    "Button",
    "Picker",
    "Toggle",
    "TextField",
    "DatePicker",
    "ContentUnavailableView",
    "navigationTitle",
    "accessibilityLabel",
    "help",
    "static let",
)
LITERAL = re.compile(r'"(?:\\.|[^"\\])*"')
BEGIN, END = "<!-- BEGIN EXTRACTED_UI_TEXTS -->", "<!-- END EXTRACTED_UI_TEXTS -->"


def extract(source: Path) -> list[dict[str, object]]:
    rows = []
    for path in sorted(source.rglob("*.swift")):
        if any(
            part.startswith(".") or part in {"build", "SourcePackages"}
            for part in path.parts
        ):
            continue
        for line_number, line in enumerate(
            path.read_text(encoding="utf-8", errors="replace").splitlines(), 1
        ):
            if not any(call in line for call in CALLS):
                continue
            for literal in LITERAL.findall(line):
                if (
                    re.search(rf"systemImage\s*:\s*{re.escape(literal)}", line)
                    or "keyboardShortcut" in line
                    or "specifier:" in line
                ):
                    continue
                value = literal[1:-1]
                if value.strip():
                    rows.append(
                        {
                            "file": str(path.relative_to(source)),
                            "line": line_number,
                            "literal": literal,
                            "value": value,
                        }
                    )
    return rows


def render(name: str, rows: list[dict[str, object]]) -> str:
    return f"# {name} UI text inventory\n\nThis file is an exact, source-extracted inventory of visible SwiftUI text. It is a review record, not a writing prompt: preserve wording, punctuation, capitalization, and interpolation exactly unless the owner approves a specific change. Do not add promotional headings, eyebrows, AI signposting, or explanatory copy without an explicit product decision.\n\n{BEGIN}\n```json\n{json.dumps(rows, ensure_ascii=False, indent=2)}\n```\n{END}\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    expected = render(args.name, extract(args.source))
    if args.check:
        if (
            not args.output.exists()
            or args.output.read_text(encoding="utf-8") != expected
        ):
            print(
                f"UI text inventory is stale; regenerate {args.output}", file=sys.stderr
            )
            return 1
        return 0
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(expected, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

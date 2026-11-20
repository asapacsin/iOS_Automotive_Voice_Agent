#!/usr/bin/env python3
"""F-09b §17 item 3 (T-031zb): every panel the App shows has its tools.

Fails when a panel used with `.screenPanel(.<key>)` in App/NovaDrive has no `PanelRegistry` entry in
Packages/NovaCore/Sources/NovaKit/ScreenState.swift, or when an entry has a layer and no close tool (row 9).
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
REGISTRY = "Packages/NovaCore/Sources/NovaKit/ScreenState.swift"
APP = "App/NovaDrive"
USE = re.compile(r"\.screenPanel\(\s*\.(\w+)\s*\)")
ENTRY = re.compile(r"^\s*\.(\w+):\s*PanelEntry\(layer:\s*(\w+),.*?close:\s*(\"[^\"]*\"|nil)", re.M)


def problems(root: pathlib.Path = ROOT) -> list[str]:
    src = root / REGISTRY
    if not src.exists():
        return [f"{REGISTRY}: missing"]
    entries = {m.group(1): (m.group(2), m.group(3)) for m in ENTRY.finditer(src.read_text(encoding="utf-8"))}
    out = []
    used = set()
    app = root / APP
    if app.exists():
        for p in sorted(app.rglob("*.swift")):
            for m in USE.finditer(p.read_text(encoding="utf-8", errors="ignore")):
                if m.group(1) not in used:
                    used.add(m.group(1))
                    if m.group(1) not in entries:
                        out.append(f"{p.relative_to(root)}: .screenPanel(.{m.group(1)}) has no PanelRegistry entry")
    for key, (layer, close) in sorted(entries.items()):
        if layer != "nil" and close in ("nil", '""'):
            out.append(f"{REGISTRY}: .{key} has layer {layer} and no close tool")
    return out


def main() -> int:
    issues = problems()
    for issue in issues:
        print(f"check_panel_tools: {issue} (F-09b §17 item 3)")
    if issues:
        return 1
    print("check_panel_tools: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Fails when an app's copy of the voice assistant tool catalog drifts from
shared/voice-assistant/tools.json, or when the catalog itself is malformed."""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CANONICAL = ROOT / "shared/voice-assistant/tools.json"
COPIES = [
    ROOT / "ios/calorietracker/VoiceAssistant/VoiceAssistantTools.json",
    ROOT / "android/app/src/main/assets/voice_assistant_tools.json",
]
EFFECTS = {"read", "navigate", "write", "destructive"}
CONFIRMS = {"never", "setting", "always"}


def problems_in(catalog: dict) -> list[str]:
    problems = []
    names = set()
    for tool in catalog.get("tools", []):
        name = tool.get("name", "")
        if not name or name in names:
            problems.append(f"missing or duplicate tool name: {name!r}")
        names.add(name)
        if tool.get("effect") not in EFFECTS:
            problems.append(f"{name}: effect must be one of {sorted(EFFECTS)}")
        if tool.get("confirm") not in CONFIRMS:
            problems.append(f"{name}: confirm must be one of {sorted(CONFIRMS)}")
        if tool.get("effect") == "destructive" and tool.get("confirm") != "always":
            problems.append(f"{name}: destructive tools must always confirm")
        params = tool.get("parameters", {})
        if params.get("type") != "object":
            problems.append(f"{name}: parameters must be an object schema")
        needs_flag = tool.get("confirm") != "never"
        if needs_flag and "user_confirmed" not in params.get("properties", {}):
            problems.append(f"{name}: confirming tools need a user_confirmed parameter")
        if not tool.get("description"):
            problems.append(f"{name}: description is required")
    return problems


def main() -> int:
    canonical = CANONICAL.read_bytes()
    failures = problems_in(json.loads(canonical))
    for copy in COPIES:
        if not copy.exists():
            failures.append(f"{copy.relative_to(ROOT)} is missing")
        elif copy.read_bytes() != canonical:
            failures.append(f"{copy.relative_to(ROOT)} differs from {CANONICAL.relative_to(ROOT)}; copy it again")
    for failure in failures:
        print(f"error: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

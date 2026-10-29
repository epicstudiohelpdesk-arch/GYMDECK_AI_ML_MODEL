#!/usr/bin/env python3
"""Add only the workout sample-pack frames to a sparse CI checkout.

CI checks out shared/workout-vectors without its ~7,000 *_v2_*.png frames
(1.2 GB). Debug builds, unit tests and instrumentation tests only use the small
sample pack listed in sample-pack.txt, so this adds exactly those frames.
"""
import pathlib
import re
import subprocess

SAMPLE_PACK = pathlib.Path("shared/workout-vectors/sample-pack.txt")

sparse = subprocess.run(
    ["git", "config", "--get", "core.sparseCheckout"], capture_output=True, text=True
).stdout.strip()
if sparse != "true":
    print("full checkout: every workout frame is already present; nothing to add")
    raise SystemExit(0)

patterns = []
for line in SAMPLE_PACK.read_text().splitlines():
    exercise = line.split("#", 1)[0].strip()
    if not exercise:
        continue
    if not re.fullmatch(r"[A-Za-z0-9_-]+", exercise):
        raise SystemExit(f"Invalid exercise name in sample pack: {exercise!r}")
    for gender in ("male", "female"):
        for frame in range(4):
            patterns.append(f"/shared/workout-vectors/{exercise}_{gender}_v2_{frame}.png")
if not patterns:
    raise SystemExit("Workout sample pack must not be empty")

subprocess.run(
    ["git", "sparse-checkout", "add", "--stdin"],
    input="\n".join(patterns) + "\n",
    text=True,
    check=True,
)
missing = [p for p in patterns if not pathlib.Path(p.lstrip("/")).is_file()]
if missing:
    raise SystemExit(f"{len(missing)} sample frame(s) missing after checkout, e.g. {missing[0]}")
print(f"added {len(patterns)} workout sample frames")

"""Report project mise tool updates without modifying versions or lockfiles."""

import json
import os
from pathlib import Path
import subprocess
import sys


def summarize(updates):
    lines = ["## mise tool updates", "",
             "Candidates require review; versions and lockfiles were not changed.", "",
             "| Tool | Requested | Current | Latest |", "| --- | --- | --- | --- |"]
    for name, update in sorted(updates.items()):
        # Fail on unexpected output instead of reporting a successful empty check.
        values = [name, *[update[key] for key in ("requested", "current", "latest")]]
        if not all(isinstance(value, str) and value for value in values):
            raise ValueError(f"invalid mise outdated entry: {name}")
        lines.append("| " + " | ".join(value.replace("|", "\\|").replace("\n", " ") for value in values) + " |")
    if not updates:
        lines += ["", "All project tools are up to date."]
    return "\n".join(lines) + "\n"


def main():
    try:
        result = subprocess.run(
            ["mise", "outdated", "--bump", "--no-global", "--json"],
            text=True, capture_output=True, check=True,
        )
    except subprocess.CalledProcessError as error:
        if error.stderr:
            print(error.stderr, file=sys.stderr, end="")
        raise
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    updates = json.loads(result.stdout)
    if not isinstance(updates, dict):
        raise ValueError("expected a mise outdated JSON object")
    markdown = summarize(updates)
    directory = Path("tool-updates")
    directory.mkdir(exist_ok=True)
    (directory / "updates.json").write_text(json.dumps(updates, indent=2) + "\n")
    (directory / "summary.md").write_text(markdown)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
            stream.write(markdown)
    print(markdown, end="")
    return bool(updates)


if __name__ == "__main__":
    sys.exit(main())

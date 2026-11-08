"""Report project mise tool updates without modifying versions or lockfiles."""

import json
import os
import re
import subprocess
import sys
from pathlib import Path


def summarize(updates, unchecked=()):
    lines = [
        "## mise tool updates",
        "",
        "Candidates require review; versions and lockfiles were not changed.",
        "",
        "| Tool | Requested | Current | Latest |",
        "| --- | --- | --- | --- |",
    ]
    for name, update in sorted(updates.items()):
        # Fail on unexpected output instead of reporting a successful empty check.
        values = [name, *[update[key] for key in ("requested", "current", "latest")]]
        if not all(isinstance(value, str) and value for value in values):
            raise ValueError(f"invalid mise outdated entry: {name}")
        lines.append(
            "| "
            + " | ".join(
                value.replace("|", "\\|").replace("\n", " ") for value in values
            )
            + " |"
        )
    if unchecked:
        lines += [
            "",
            "Update check incomplete; some tools could not be checked.",
            *[f"- {warning}" for warning in unchecked],
        ]
    elif not updates:
        lines += ["", "All project tools are up to date."]
    return "\n".join(lines) + "\n"


def main():
    try:
        result = subprocess.run(
            ["mise", "outdated", "--bump", "--no-global", "--json"],
            text=True,
            capture_output=True,
            check=True,
            env=dict(os.environ, NO_COLOR="1"),
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
    # mise 2026.11.4 exits 0 even when individual lookups fail. Its summary
    # names the unchecked tools; an empty JSON object then does not mean current.
    unchecked = re.findall(
        r"Could not check \d+ tools? for updates:[^\r\n]*", result.stderr
    )
    markdown = summarize(updates, unchecked)
    directory = Path("tool-updates")
    directory.mkdir(exist_ok=True)
    (directory / "updates.json").write_text(json.dumps(updates, indent=2) + "\n")
    (directory / "summary.md").write_text(markdown)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
            stream.write(markdown)
    print(markdown, end="")
    return bool(updates or unchecked)


if __name__ == "__main__":
    sys.exit(main())

"""Report LLVM coverage for Sources/Relay only and enforce committed floors."""

import argparse
import json
import os
from pathlib import Path
import sys


METRICS = ("lines", "functions", "regions")
ROOT = Path(__file__).resolve().parents[1]


def aggregate(files):
    result = {}
    for metric in METRICS:
        count = sum(f["summary"][metric]["count"] for f in files)
        covered = sum(f["summary"][metric]["covered"] for f in files)
        if count <= 0 or not 0 <= covered <= count:
            raise ValueError(f"invalid or empty {metric} coverage")
        result[metric] = {
            "count": count,
            "covered": covered,
            "percent": 100 * covered / count,
        }
    return result


def report(export, thresholds, source_root):
    source_root = source_root.resolve()
    files = {}
    for data in export["data"]:
        for entry in data["files"]:
            path = Path(entry["filename"]).resolve()
            if not path.is_relative_to(source_root):
                continue
            name = path.relative_to(source_root).as_posix()
            if name in files:
                raise ValueError(f"duplicate coverage entry: {name}")
            files[name] = entry
    expected = {p.relative_to(source_root).as_posix() for p in source_root.rglob("*.swift")}
    if not expected or set(files) != expected:
        raise ValueError(f"source coverage mismatch: missing={sorted(expected - set(files))}, "
                         f"unexpected={sorted(set(files) - expected)}")
    total = aggregate(files.values())
    areas = {area: aggregate([f for name, f in files.items() if name.startswith(area + "/")])
             for area in sorted({name.split('/')[0] for name in files if '/' in name})}
    unconfigured = sorted(set(areas) - set(thresholds["areas"]))
    if unconfigured:
        raise ValueError(f"missing coverage floors for areas: {', '.join(unconfigured)}")
    failures = []
    for metric, floor in thresholds["total"].items():
        if total[metric]["percent"] < floor:
            failures.append(f"Total {metric}: {total[metric]['percent']:.2f}% < {floor:.2f}%")
    for area, floor in thresholds["areas"].items():
        if area not in areas:
            raise ValueError(f"missing coverage area: {area}")
        if areas[area]["lines"]["percent"] < floor:
            failures.append(f"{area} lines: {areas[area]['lines']['percent']:.2f}% < {floor:.2f}%")
    summary = ["## CLI coverage", "", "Sources/Relay only, including main.swift. Tests, generated code and the device Runner are excluded.",
               "", "| Area | Lines | Functions | Regions | Line floor |", "| --- | ---: | ---: | ---: | ---: |"]
    for name, metrics in [("Total", total), *areas.items()]:
        cells = [f"{metrics[m]['percent']:.2f}% ({metrics[m]['covered']}/{metrics[m]['count']})" for m in METRICS]
        floor = thresholds["total"]["lines"] if name == "Total" else thresholds["areas"][name]
        summary.append(f"| {name} | " + " | ".join(cells) + f" | {floor}% |")
    summary += ["", "### Files", "", "| File | Line coverage |", "| --- | ---: |"]
    for name, f in sorted(files.items()):
        line = f["summary"]["lines"]
        percent = 100 * line["covered"] / line["count"] if line["count"] else 0
        summary.append(f"| {name} | {percent:.2f}% ({line['covered']}/{line['count']}) |")
    summary += ["", "Coverage floors: " + ("FAILED" if failures else "passed"), *[f"- {f}" for f in failures], ""]
    return {"total": total, "areas": areas, "failures": failures}, "\n".join(summary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("export", type=Path)
    parser.add_argument("--output", type=Path, default=Path("coverage"))
    args = parser.parse_args()
    export = json.loads(args.export.read_text())
    thresholds = json.loads((ROOT / "scripts/coverage-thresholds.json").read_text())
    result, markdown = report(export, thresholds, ROOT / "Sources/Relay")
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "llvm-coverage.json").write_text(json.dumps(export))
    (args.output / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    (args.output / "summary.md").write_text(markdown)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
            stream.write(markdown)
    print(markdown)
    return bool(result["failures"])


if __name__ == "__main__":
    sys.exit(main())

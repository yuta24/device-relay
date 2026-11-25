#!/bin/bash
# Runs the checks of this repository. mise runs the same steps through one-line tasks, and CI runs the
# same script, so the steps live here only.
#
#   scripts/check.sh                  every step, in this order: the lints, coverage (which runs the Swift
#                                     tests), then the Python tests. The run stops at the first failure.
#   scripts/check.sh lint:shell ...   only the named steps, in the given order
#
# Steps are named after the mise tasks: lint:swift lint:python lint:workflow lint:shell coverage test:swift
# test:python. The tools come from PATH; mise is not called. A tool that is missing stops the run with its
# name, so install it yourself (mise install --locked, or your package manager).
set -euo pipefail

usage() {
	echo "usage: scripts/check.sh [<step>...]" >&2
	echo "steps: lint:swift lint:python lint:workflow lint:shell coverage test:swift test:python" >&2
	exit 2
}

# Any directory: the steps use paths relative to the repository root.
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

require() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "check.sh: $1 is not in PATH" >&2
		exit 1
	fi
}

lint_swift() {
	require swiftformat
	swiftformat Package.swift Sources Tests Runner --lint --cache ignore
}

lint_python() {
	require ruff
	ruff check scripts
	ruff format scripts --check
}

lint_workflow() {
	require actionlint
	actionlint -pyflakes=
}

lint_shell() {
	require shellcheck
	shellcheck scripts/*.sh
}

# `swift test` builds too, so no step calls a separate build.
test_swift() {
	require xcrun
	xcrun swift test --enable-code-coverage
}

# The Swift tests run here so that `scripts/check.sh coverage` reports the floors for this run.
coverage() {
	test_swift
	require python3
	local coverage_path
	coverage_path="$(xcrun swift test --show-codecov-path)"
	python3 scripts/coverage.py "$coverage_path" --output coverage
}

test_python() {
	require python3
	python3 -m unittest discover -s scripts -p 'test_*.py'
}

run_step() {
	case "$1" in
	lint:swift) lint_swift ;;
	lint:python) lint_python ;;
	lint:workflow) lint_workflow ;;
	lint:shell) lint_shell ;;
	coverage) coverage ;;
	test:swift) test_swift ;;
	test:python) test_python ;;
	esac
}

steps=("$@")
if [ "${#steps[@]}" -eq 0 ]; then
	steps=(lint:swift lint:python lint:workflow lint:shell coverage test:python)
fi

# Check every name up front, so an unknown one runs nothing.
for step in "${steps[@]}"; do
	case "$step" in
	lint:swift | lint:python | lint:workflow | lint:shell | coverage | test:swift | test:python) ;;
	*) usage ;;
	esac
done

for step in "${steps[@]}"; do
	echo "check.sh: $step" >&2
	run_step "$step"
done

#!/bin/bash
# Classify NUL-delimited PR paths; unknown inputs keep code validation enabled.
set -euo pipefail

classify() {
	local path='' seen=false code=false package=false
	while IFS= read -r -d '' path || [ -n "$path" ]; do
		seen=true
		case "$path" in
		README.md | README.ja.md | docs/*) ;;
		*) code=true ;;
		esac
		case "$path" in
		Sources/* | Runner/* | skills/* | scripts/* | Package.swift | Makefile | mise.toml | mise.lock | .github/workflows/ci.yml | .github/workflows/release.yml)
			package=true
			;;
		esac
	done
	if [ "$seen" = false ]; then
		code=true
		package=true
	fi
	printf 'code=%s\nrun=%s\n' "$code" "$package"
}

if [ "$#" -eq 0 ]; then
	classify
elif [ "$#" -eq 2 ]; then
	paths_file=$(mktemp)
	trap 'rm -f "$paths_file"' EXIT
	# Include both sides of renames; compare the full PR against its merge base.
	git diff --name-only --no-renames -z "$1...$2" -- >"$paths_file"
	classify <"$paths_file"
else
	echo "usage: bash scripts/ci-changes.sh [base-sha head-sha]" >&2
	exit 2
fi

# make install links the release build of relay into $(PREFIX)/bin (default ~/.local/bin).
# The link points into this checkout, so relay finds the runner project here.
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
# Xcode's toolchain: another swift first in PATH (swiftly) may not match the Xcode SDK.
SWIFT ?= xcrun swift
PRODUCT := $(CURDIR)/.build/release/relay

.DEFAULT_GOAL := help
.PHONY: help install uninstall

help:
	@echo "make install    build a release and link $(BINDIR)/relay to this checkout"
	@echo "make uninstall  remove that link when it points to this checkout"
	@echo "checks:  scripts/check.sh  (mise run check)"
	@echo "package: scripts/dist.sh   (mise run dist)"

install:
	$(SWIFT) build -c release
	@mkdir -p "$(BINDIR)"
	@if [ -e "$(BINDIR)/relay" ] && [ ! -L "$(BINDIR)/relay" ]; then \
		echo "$(BINDIR)/relay exists and is not a symlink; remove it first" >&2; exit 1; \
	fi
	ln -sfn "$(PRODUCT)" "$(BINDIR)/relay"
	@echo "linked $(BINDIR)/relay -> $(PRODUCT)"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) echo "note: $(BINDIR) is not in PATH" >&2 ;; esac
	@echo "next: relay doctor"

# Removes the link only when it points to this checkout's build. relay runner uninstall removes ~/.relay/runner.
uninstall:
	@if [ -L "$(BINDIR)/relay" ] && [ "$$(readlink "$(BINDIR)/relay")" = "$(PRODUCT)" ]; then \
		rm "$(BINDIR)/relay" && echo "removed $(BINDIR)/relay"; \
	elif [ -e "$(BINDIR)/relay" ] || [ -L "$(BINDIR)/relay" ]; then \
		echo "$(BINDIR)/relay is not a link to $(PRODUCT); left as is" >&2; exit 1; \
	else \
		echo "$(BINDIR)/relay is not installed"; \
	fi

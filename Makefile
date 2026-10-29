# make install links the release build of relay into $(PREFIX)/bin (default ~/.local/bin).
# The link points into this checkout, so relay install finds the runner project here.
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
# Xcode's toolchain: another swift first in PATH (swiftly) may not match the Xcode SDK.
SWIFT ?= xcrun swift
PRODUCT := $(CURDIR)/.build/release/relay

.PHONY: build install uninstall test

build:
	$(SWIFT) build -c release

install: build
	@mkdir -p "$(BINDIR)"
	@if [ -e "$(BINDIR)/relay" ] && [ ! -L "$(BINDIR)/relay" ]; then \
		echo "$(BINDIR)/relay exists and is not a symlink; remove it first" >&2; exit 1; \
	fi
	ln -sfn "$(PRODUCT)" "$(BINDIR)/relay"
	@echo "linked $(BINDIR)/relay -> $(PRODUCT)"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) echo "note: $(BINDIR) is not in PATH" >&2 ;; esac
	@echo "next: relay install && relay doctor"

# Removes the link only when it points to this checkout's build. relay uninstall removes ~/.relay/runner.
uninstall:
	@if [ -L "$(BINDIR)/relay" ] && [ "$$(readlink "$(BINDIR)/relay")" = "$(PRODUCT)" ]; then \
		rm "$(BINDIR)/relay" && echo "removed $(BINDIR)/relay"; \
	elif [ -e "$(BINDIR)/relay" ] || [ -L "$(BINDIR)/relay" ]; then \
		echo "$(BINDIR)/relay is not a link to $(PRODUCT); left as is" >&2; exit 1; \
	else \
		echo "$(BINDIR)/relay is not installed"; \
	fi

test:
	$(SWIFT) test

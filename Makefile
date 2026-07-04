# t-pgsql Makefile

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
MANDIR ?= $(PREFIX)/share/man/man1
ZSHDIR ?= $(PREFIX)/share/zsh/site-functions
BASHDIR ?= $(PREFIX)/share/bash-completion/completions
FISHDIR ?= $(PREFIX)/share/fish/vendor_completions.d
VERSION ?= $(shell git describe --tags --always 2>/dev/null || echo "3.9.0")

# Debian package version: strip a leading "v" (v3.9.0 -> 3.9.0) and ensure the
# version starts with a digit (a bare commit hash gets a "0~" prefix), as
# required by dpkg.
DEB_VERSION := $(shell v=`echo "$(VERSION)" | sed -e 's/^v//'`; if echo "$$v" | grep -q '^[0-9]'; then echo "$$v"; else echo "0~$$v"; fi)

.PHONY: all build check-build install uninstall deb release clean help

all: help

## build: Assemble the single-file t-pgsql from src/ modules
build:
	@./build.sh

## check-build: Verify the committed t-pgsql matches src/ (CI / pre-commit)
check-build:
	@./build.sh --check
	@bash -n t-pgsql && echo "syntax OK"

## install: Install t-pgsql to system (with completions and man page)
install:
	@echo "Installing t-pgsql to $(DESTDIR)$(BINDIR)..."
	@install -d $(DESTDIR)$(BINDIR)
	@install -m 0755 t-pgsql $(DESTDIR)$(BINDIR)/t-pgsql
	@echo "Installing man page..."
	@install -d $(DESTDIR)$(MANDIR)
	@install -m 0644 man/t-pgsql.1 $(DESTDIR)$(MANDIR)/t-pgsql.1
	@echo "Installing shell completions..."
	@install -d $(DESTDIR)$(ZSHDIR) $(DESTDIR)$(BASHDIR) $(DESTDIR)$(FISHDIR)
	@install -m 0644 completions/_t-pgsql $(DESTDIR)$(ZSHDIR)/_t-pgsql
	@install -m 0644 completions/t-pgsql.bash $(DESTDIR)$(BASHDIR)/t-pgsql
	@install -m 0644 completions/t-pgsql.fish $(DESTDIR)$(FISHDIR)/t-pgsql.fish
	@echo "Done! Run 't-pgsql --help' to get started."

## uninstall: Remove t-pgsql from system
uninstall:
	@echo "Removing t-pgsql from $(DESTDIR)$(BINDIR)..."
	@rm -f $(DESTDIR)$(BINDIR)/t-pgsql
	@rm -f $(DESTDIR)$(MANDIR)/t-pgsql.1
	@rm -f $(DESTDIR)$(ZSHDIR)/_t-pgsql
	@rm -f $(DESTDIR)$(BASHDIR)/t-pgsql
	@rm -f $(DESTDIR)$(FISHDIR)/t-pgsql.fish
	@echo "Done!"

## deb: Build Debian package
deb:
	@echo "Building Debian package (version $(DEB_VERSION))..."
	@rm -rf build/deb
	@mkdir -p build/deb/DEBIAN
	@mkdir -p build/deb/usr/bin
	@mkdir -p build/deb/usr/share/man/man1
	@mkdir -p build/deb/usr/share/zsh/vendor-completions
	@mkdir -p build/deb/usr/share/bash-completion/completions
	@mkdir -p build/deb/usr/share/fish/vendor_completions.d
	@cp t-pgsql build/deb/usr/bin/
	@chmod 755 build/deb/usr/bin/t-pgsql
	@gzip -9 -n -c man/t-pgsql.1 > build/deb/usr/share/man/man1/t-pgsql.1.gz
	@install -m 0644 completions/_t-pgsql build/deb/usr/share/zsh/vendor-completions/_t-pgsql
	@install -m 0644 completions/t-pgsql.bash build/deb/usr/share/bash-completion/completions/t-pgsql
	@install -m 0644 completions/t-pgsql.fish build/deb/usr/share/fish/vendor_completions.d/t-pgsql.fish
	@echo "Package: t-pgsql" > build/deb/DEBIAN/control
	@echo "Version: $(DEB_VERSION)" >> build/deb/DEBIAN/control
	@echo "Section: database" >> build/deb/DEBIAN/control
	@echo "Priority: optional" >> build/deb/DEBIAN/control
	@echo "Architecture: all" >> build/deb/DEBIAN/control
	@echo "Depends: postgresql-client, openssh-client, bash (>= 4.0)" >> build/deb/DEBIAN/control
	@echo "Maintainer: Asim Atasert <asimatasert@outlook.com>" >> build/deb/DEBIAN/control
	@echo "Description: PostgreSQL database sync and clone tool" >> build/deb/DEBIAN/control
	@echo " Advanced CLI tool for backing up, restoring, and synchronizing" >> build/deb/DEBIAN/control
	@echo " PostgreSQL databases with SSH tunnel support." >> build/deb/DEBIAN/control
	@dpkg-deb --build build/deb build/t-pgsql_$(DEB_VERSION)_all.deb
	@echo "Package created: build/t-pgsql_$(DEB_VERSION)_all.deb"

## release: Create release artifacts
release:
	@echo "Creating release artifacts for $(VERSION)..."
	@mkdir -p dist
	@cp t-pgsql dist/t-pgsql
	@chmod +x dist/t-pgsql
	@cd dist && tar -czf t-pgsql-$(VERSION).tar.gz t-pgsql
	@cd dist && sha256sum t-pgsql-$(VERSION).tar.gz > t-pgsql-$(VERSION).tar.gz.sha256 2>/dev/null || \
		shasum -a 256 t-pgsql-$(VERSION).tar.gz > t-pgsql-$(VERSION).tar.gz.sha256
	@echo "Release artifacts created in dist/"
	@ls -la dist/

## clean: Clean build artifacts
clean:
	@rm -rf build dist
	@echo "Cleaned!"

## help: Show this help
help:
	@echo "t-pgsql Makefile"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@sed -n 's/^## //p' $(MAKEFILE_LIST) | column -t -s ':' | sed 's/^/  /'
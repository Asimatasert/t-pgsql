# t-pgsql Makefile

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
VERSION ?= $(shell git describe --tags --always 2>/dev/null || echo "1.0.0")

.PHONY: all install uninstall deb homebrew-tap release clean help

all: help

## install: Install t-pgsql to system
install:
	@echo "Installing t-pgsql to $(BINDIR)..."
	@install -d $(BINDIR)
	@install -m 0755 t-pgsql $(BINDIR)/t-pgsql
	@echo "Done! Run 't-pgsql --help' to get started."

## uninstall: Remove t-pgsql from system
uninstall:
	@echo "Removing t-pgsql from $(BINDIR)..."
	@rm -f $(BINDIR)/t-pgsql
	@echo "Done!"

## deb: Build Debian package
deb:
	@echo "Building Debian package..."
	@mkdir -p build/deb/DEBIAN
	@mkdir -p build/deb/usr/bin
	@cp t-pgsql build/deb/usr/bin/
	@chmod 755 build/deb/usr/bin/t-pgsql
	@echo "Package: t-pgsql" > build/deb/DEBIAN/control
	@echo "Version: $(VERSION)" >> build/deb/DEBIAN/control
	@echo "Section: database" >> build/deb/DEBIAN/control
	@echo "Priority: optional" >> build/deb/DEBIAN/control
	@echo "Architecture: all" >> build/deb/DEBIAN/control
	@echo "Depends: postgresql-client, openssh-client, bash (>= 4.0)" >> build/deb/DEBIAN/control
	@echo "Maintainer: Asim Atasert <asimatasert@outlook.com>" >> build/deb/DEBIAN/control
	@echo "Description: PostgreSQL database sync and clone tool" >> build/deb/DEBIAN/control
	@echo " Advanced CLI tool for backing up, restoring, and synchronizing" >> build/deb/DEBIAN/control
	@echo " PostgreSQL databases with SSH tunnel support." >> build/deb/DEBIAN/control
	@dpkg-deb --build build/deb build/t-pgsql_$(VERSION)_all.deb
	@echo "Package created: build/t-pgsql_$(VERSION)_all.deb"

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
	@sed -n 's/^## //p' $(MAKEFILE_LIST) | column -t -s ':' | sed 's/^/  /
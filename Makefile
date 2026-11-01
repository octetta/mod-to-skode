.DEFAULT_GOAL := help

# ------------------------------------------------------------------------------
# Configuration & Binaries
# ------------------------------------------------------------------------------
SHELL := /bin/bash
GLEAM ?= gleam
NPM   ?= npm
PYTHON ?= python3
CC    ?= gcc
ESBUILD ?= npx esbuild
PORT  ?= 3000
HOST  ?= 0.0.0.0
VERSION ?=

VENDOR_DIR  := .vendor/quickjs
CLI_BIN     := bin/mod2skode
CLI_ENTRY   := build/dev/javascript/mod_to_skode/cli.mjs
CLI_BUNDLE  := dist/mod2skode.mjs
CLI_WRAPPER := dist/wrapper.c

MOD_FILES := $(wildcard *.mod *.MOD)
ZIP_FILES := $(MOD_FILES:.mod=.zip) $(MOD_FILES:.MOD=.zip)

.PHONY: help all clean distclean install build build-web dev run start preview test test-gleam test-cli check format deps update-skred cli

help:
	@echo "mod-to-skode Makefile targets:"
	@echo "  make help         Show this help message"
	@echo "  make cli          Build standalone native CLI binary (bin/mod2skode via QuickJS)"
	@echo "  make dev          Start Vite dev server (host $(HOST):$(PORT))"
	@echo "  make run          Alias for 'make dev'"
	@echo "  make build        Compile Gleam and build production web bundle into dist/"
	@echo "  make build-web    Alias for 'make build'"
	@echo "  make preview      Preview production build in dist/ on $(HOST):$(PORT)"
	@echo "  make test         Run test suite via Gleam JavaScript target"
	@echo "  make test-gleam   Alias for 'make test'"
	@echo "  make test-cli     Test the standalone CLI binary on ELYSIUM.MOD"
	@echo "  make check        Verify compilation and Gleam formatting"
	@echo "  make format       Format all Gleam source and test files"
	@echo "  make deps         Install Gleam and npm dependencies"
	@echo "  make update-skred Pull Skred WASM from github.com/octetta/pulp (latest or VERSION=x.y.z)"
	@echo "  make all          Convert all local .mod/.MOD files to .zip via bin/mod2skode"
	@echo "  make <file>.zip   Convert a single .mod file to .zip via bin/mod2skode"
	@echo "  make install      Deploy ELYSIUM.zip to ../skred-web/amiga.zip"
	@echo "  make clean        Remove generated .zip files, build, and dist artifacts"
	@echo "  make distclean    Deep clean including .vendor and bin directories"

deps:
	@echo "==> Downloading Gleam dependencies..."
	$(GLEAM) deps download
	@echo "==> Installing npm packages..."
	$(NPM) install

node_modules: package.json package-lock.json
	@echo "==> Installing npm packages..."
	$(NPM) install
	@touch -c node_modules

update-skred:
	@echo "==> Fetching Skred WASM from github.com/octetta/pulp releases..."
	./scripts/fetch-skred.sh $(VERSION)

# ------------------------------------------------------------------------------
# Standalone Native CLI Binary (Gleam + QuickJS)
# ------------------------------------------------------------------------------
$(VENDOR_DIR)/qjsc:
	@mkdir -p .vendor
	@if [ ! -d "$(VENDOR_DIR)" ]; then \
		echo "==> Cloning QuickJS (no git submodules)..."; \
		git clone --depth 1 https://github.com/bellard/quickjs.git $(VENDOR_DIR); \
	fi
	@echo "==> Compiling QuickJS (qjsc and libquickjs.a)..."
	$(MAKE) -C $(VENDOR_DIR) qjsc libquickjs.a

$(CLI_BIN): $(VENDOR_DIR)/qjsc
	@mkdir -p bin dist
	@echo "==> Compiling Gleam code..."
	$(GLEAM) build --target javascript
	@echo "==> Bundling CLI with esbuild..."
	$(ESBUILD) $(CLI_ENTRY) \
		--bundle \
		--format=esm \
		--platform=neutral \
		--external:std \
		--external:os \
		--footer:js="main();" \
		--outfile=$(CLI_BUNDLE)
	@echo "==> Generating QuickJS C bytecode wrapper..."
	$(VENDOR_DIR)/qjsc -m -e -o $(CLI_WRAPPER) $(CLI_BUNDLE)
	@echo "==> Compiling standalone native CLI executable (-Os -s)..."
	$(CC) -Os -s \
		-I$(VENDOR_DIR) \
		$(CLI_WRAPPER) \
		$(VENDOR_DIR)/libquickjs.a \
		-lm -ldl -o $(CLI_BIN)
	@echo "==> Standalone native CLI binary ready at $(CLI_BIN):"
	@ls -lh $(CLI_BIN)

cli: $(CLI_BIN)

test-cli: $(CLI_BIN)
	@echo "==> Testing bin/mod2skode with --help..."
	@$(CLI_BIN) --help
	@echo "==> Testing bin/mod2skode conversion on ELYSIUM.MOD..."
	@mkdir -p tmp
	@$(CLI_BIN) ELYSIUM.MOD -o tmp/test_elysium.zip
	@unzip -t tmp/test_elysium.zip
	@rm -f tmp/test_elysium.zip
	@echo "==> CLI tests passed!"

# ------------------------------------------------------------------------------
# Web Application & Testing
# ------------------------------------------------------------------------------
build: node_modules
	@echo "==> Compiling Gleam code to JavaScript..."
	$(GLEAM) build --target javascript
	@echo "==> Bundling with Vite for production..."
	$(NPM) run build

build-web: build

dev: node_modules
	@echo "==> Compiling Gleam and launching Vite dev server..."
	$(GLEAM) build --target javascript
	npx vite --host $(HOST) --open --port $(PORT)

run: dev
start: dev

preview: build
	@echo "==> Launching production preview on $(HOST):$(PORT)..."
	npx vite preview --host $(HOST) --open --port $(PORT)

test:
	@echo "==> Running Gleam unit tests..."
	$(GLEAM) test --target javascript

test-gleam: test

check:
	@echo "==> Verifying compilation and formatting..."
	$(GLEAM) check
	$(GLEAM) format --check src test

format:
	@echo "==> Formatting Gleam source and test files..."
	$(GLEAM) format src test

# Generic rule to convert a .mod file to a .zip using the native Gleam CLI binary
%.zip: %.mod $(CLI_BIN)
	$(CLI_BIN) $< -o $@

%.zip: %.MOD $(CLI_BIN)
	$(CLI_BIN) $< -o $@

all: $(ZIP_FILES)

# Specific target to build and deploy ELYSIUM.MOD directly to skred-web as amiga.zip
install: ELYSIUM.zip
	cp ELYSIUM.zip ../skred-web/amiga.zip
	@echo "Copied ELYSIUM.zip to ../skred-web/amiga.zip"

clean:
	@echo "==> Cleaning build artifacts..."
	rm -rf build dist dev erl_crash.dump tmp bin *.zip

distclean: clean
	@echo "==> Removing vendored QuickJS..."
	rm -rf .vendor

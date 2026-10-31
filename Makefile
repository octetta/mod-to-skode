.DEFAULT_GOAL := help

# ------------------------------------------------------------------------------
# Configuration & Binaries
# ------------------------------------------------------------------------------
SHELL := /bin/bash
GLEAM ?= gleam
NPM   ?= npm
PYTHON ?= python3
PORT  ?= 3000
HOST  ?= 0.0.0.0
VERSION ?=

MOD_FILES := $(wildcard *.mod *.MOD)
ZIP_FILES := $(MOD_FILES:.mod=.zip) $(MOD_FILES:.MOD=.zip)

.PHONY: help all clean install build build-web dev run start preview test test-gleam check format deps update-skred

help:
	@echo "mod-to-skode Makefile targets:"
	@echo "  make help         Show this help message"
	@echo "  make dev          Start Vite dev server (host $(HOST):$(PORT))"
	@echo "  make run          Alias for 'make dev'"
	@echo "  make build        Compile Gleam and build production web bundle into dist/"
	@echo "  make build-web    Alias for 'make build'"
	@echo "  make preview      Preview production build in dist/ on $(HOST):$(PORT)"
	@echo "  make test         Run test suite via Gleam JavaScript target"
	@echo "  make test-gleam   Alias for 'make test'"
	@echo "  make check        Verify compilation and Gleam formatting"
	@echo "  make format       Format all Gleam source and test files"
	@echo "  make deps         Install Gleam and npm dependencies"
	@echo "  make update-skred Pull Skred WASM from github.com/octetta/pulp (latest or VERSION=x.y.z)"
	@echo "  make all          Convert all local .mod/.MOD files to .zip via mod2skode.py"
	@echo "  make <file>.zip   Convert a single .mod file to .zip via mod2skode.py"
	@echo "  make install      Deploy ELYSIUM.zip to ../skred-web/amiga.zip"
	@echo "  make clean        Remove generated .zip files, build, and dist artifacts"

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

# Generic rule to convert a .mod file to a .zip using the python script
%.zip: %.mod
	$(PYTHON) mod2skode.py $< -o $@

%.zip: %.MOD
	$(PYTHON) mod2skode.py $< -o $@

all: $(ZIP_FILES)

# Specific target to build and deploy ELYSIUM.MOD directly to skred-web as amiga.zip
install: ELYSIUM.zip
	cp ELYSIUM.zip ../skred-web/amiga.zip
	@echo "Copied ELYSIUM.zip to ../skred-web/amiga.zip"

clean:
	@echo "==> Cleaning build artifacts..."
	rm -rf build dist dev erl_crash.dump

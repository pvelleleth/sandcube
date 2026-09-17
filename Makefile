GO ?= go
CRYSTAL ?= crystal
VERSION ?= 0.1.1
CRYSTAL_FLAGS ?= --threads 1
export CRYSTAL_CACHE_DIR ?= /tmp/sandcube-crystal
export GOPATH ?= /tmp/sandcube-gopath
export GOMAXPROCS ?= 2
export GOCACHE ?= /tmp/sandcube-gocache

.PHONY: build test test-package integration-cli integration integration-images integration-reliability integration-resources deps fmt
deps:
	shards install

build: deps
	mkdir -p bin
	cd services/containerd-runtime && CGO_ENABLED=0 $(GO) build -trimpath -buildvcs=false -o ../../bin/containerd-runtime .
	$(CRYSTAL) build src/main.cr -o bin/sandcube-api $(CRYSTAL_FLAGS)
	$(CRYSTAL) build src/launcher.cr -o bin/sandcube-launcher $(CRYSTAL_FLAGS)
	$(CRYSTAL) run scripts/package.cr -- $(VERSION) bin/sandcube-launcher bin/sandcube-api bin/containerd-runtime scripts/install-deps.sh bin/sandcube

test: deps
	cd services/containerd-runtime && $(GO) test -buildvcs=false -race ./...
	cd services/containerd-runtime && $(GO) vet -buildvcs=false ./...
	$(CRYSTAL) spec --threads 1
	sh -n scripts/install.sh scripts/install-deps.sh scripts/release.sh
	python3 scripts/test_installer.py

test-package: build
	python3 scripts/test_package.py

integration-cli: build
	python3 scripts/integration_cli.py

integration: build
	python3 scripts/integration.py

integration-images: build
	python3 scripts/integration_images.py

integration-reliability: build
	python3 scripts/integration_reliability.py

integration-resources: build
	python3 scripts/integration_resources.py

fmt:
	cd services/containerd-runtime && $(GO) fmt ./...
	$(CRYSTAL) tool format src spec

GO ?= go
CRYSTAL ?= crystal
export CRYSTAL_CACHE_DIR ?= /tmp/sandcube-crystal
export GOPATH ?= /tmp/sandcube-gopath
export GOMAXPROCS ?= 2
export GOCACHE ?= /tmp/sandcube-gocache

.PHONY: build test integration integration-images integration-reliability integration-resources deps fmt
deps:
	shards install

build: deps
	mkdir -p bin
	cd services/containerd-runtime && $(GO) build -buildvcs=false -o ../../bin/containerd-runtime .
	$(CRYSTAL) build src/main.cr -o bin/sandcube --threads 1

test: deps
	cd services/containerd-runtime && $(GO) test -buildvcs=false -race ./...
	cd services/containerd-runtime && $(GO) vet -buildvcs=false ./...
	$(CRYSTAL) spec --threads 1

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

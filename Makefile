#!/usr/bin/make -f

PACKAGES_SIMTEST=$(shell go list ./... | grep '/simulation')
COMMIT := $(shell git log -1 --format='%H')
DOCKER := $(shell which docker)
LEDGER_ENABLED ?= true
BINDIR ?= $(GOPATH)/bin
BUILD_DIR = ./build
VERSION = v1.0.5

export GO111MODULE = on

# process build tags

# don't override user values
ifeq (,$(VERSION))
  VERSION := $(shell git describe --tags --always)
  # if VERSION is empty, then populate it with branch's name and raw commit hash
  ifeq (,$(VERSION))
    VERSION := $(BRANCH)-$(COMMIT)
  endif
endif

build_tags = netgo
ifeq ($(LEDGER_ENABLED),true)
  ifeq ($(OS),Windows_NT)
    GCCEXE = $(shell where gcc.exe 2> NUL)
    ifeq ($(GCCEXE),)
      $(error gcc.exe not installed for ledger support, please install or set LEDGER_ENABLED=false)
    else
      build_tags += ledger
    endif
  else
    UNAME_S = $(shell uname -s)
    ifeq ($(UNAME_S),OpenBSD)
      $(warning OpenBSD detected, disabling ledger support (https://github.com/cosmos/cosmos-sdk/issues/1988))
    else
      GCC = $(shell command -v gcc 2> /dev/null)
      ifeq ($(GCC),)
        $(error gcc not installed for ledger support, please install or set LEDGER_ENABLED=false)
      else
        build_tags += ledger
      endif
    endif
  endif
endif

ifeq ($(WITH_CLEVELDB),yes)
  build_tags += gcc
endif
build_tags += $(BUILD_TAGS)
build_tags := $(strip $(build_tags))

whitespace :=
empty = $(whitespace) $(whitespace)
comma := ,
build_tags_comma_sep := $(subst $(empty),$(comma),$(build_tags))

ldflags = -X github.com/cosmos/cosmos-sdk/version.Name=manifest \
		  -X github.com/cosmos/cosmos-sdk/version.AppName=manifestd \
		  -X github.com/cosmos/cosmos-sdk/version.Version=$(VERSION) \
		  -X github.com/cosmos/cosmos-sdk/version.Commit=$(COMMIT) \
		  -X github.com/liftedinit/manifest-ledger/app.Bech32Prefix=manifest \
		  -X "github.com/cosmos/cosmos-sdk/version.BuildTags=$(build_tags_comma_sep)"

ifeq ($(WITH_CLEVELDB),yes)
  ldflags += -X github.com/cosmos/cosmos-sdk/types.DBBackend=cleveldb
endif
ifeq ($(LINK_STATICALLY),true)
	ldflags += -linkmode=external -extldflags "-Wl,-z,muldefs -static"
endif
ldflags += $(LDFLAGS)
ldflags := $(strip $(ldflags))

BUILD_FLAGS := -tags "$(build_tags_comma_sep)" -ldflags '$(ldflags)' -trimpath
###########
# Install #
###########

all: install

install:
	@echo "--> ensure dependencies have not been modified"
	@go mod verify
	@echo "--> installing manifestd instrumented for coverage"
	@go install $(BUILD_FLAGS) -cover -covermode=atomic -mod=readonly -coverpkg=github.com/liftedinit/manifest-ledger/... ./cmd/manifestd

init:
	./scripts/init.sh

build:
ifeq ($(OS),Windows_NT)
	$(error demo server not supported)
	exit 1
else
	go build -mod=readonly $(BUILD_FLAGS) -cover -covermode=atomic -coverpkg=github.com/liftedinit/manifest-ledger/... -o $(BUILD_DIR)/manifestd ./cmd/manifestd
endif

build-vendored:
	go build -mod=vendor $(BUILD_FLAGS) -o $(BUILD_DIR)/manifestd ./cmd/manifestd

.PHONY: all build build-linux install init lint build-vendored

###############################################################################
###                          INTERCHAINTEST (ictest)                        ###
###############################################################################

ictest-ibc:
	cd interchaintest && go test -race -v -run TestIBC . -count=1

ictest-tokenfactory:
	cd interchaintest && go test -race -v -run TestTokenFactory . -count=1

ictest-manifest:
	cd interchaintest && go test -race -v -run TestManifestModule . -count=1

ictest-poa:
	cd interchaintest && go test -race -v -run TestPOA . -count=1

ictest-group-poa:
	cd interchaintest && go test -race -v -run TestGroupPOA . -count=1

ictest-cosmwasm:
	cd interchaintest && go test -race -v -run TestCosmWasm . -count=1

ictest-chain-upgrade:
	cd interchaintest && go test -race -v -run TestBasicManifestUpgrade . -count=1

ictest-group:
	cd interchaintest && go test -race -v -run TestGroupMetadataLimits . -count=1

.PHONY: ictest-ibc ictest-tokenfactory

###############################################################################
###                                Build Image                              ###
###############################################################################

local-image:
	@echo "--> Building local image"
	docker build . -t manifest:local

.PHONY: local-image

#################
###   Test    ###
#################

test:
	@echo "--> Running tests"
	go test -v ./...

.PHONY: test

COV_ROOT="/tmp/manifest-ledger-coverage"
COV_UNIT_E2E="${COV_ROOT}/unit-e2e"
COV_SIMULATION="${COV_ROOT}/simulation"
COV_PKG="github.com/liftedinit/manifest-ledger/..."
COV_SIM_CMD=${COV_SIMULATION}/simulation.test
COV_SIM_COMMON=-Enabled=True -NumBlocks=100 -Commit=true -Period=5 -Params=$(shell pwd)/simulation/sim_params.json -Verbose=false -test.v -test.gocoverdir=${COV_SIMULATION}

coverage: ## Run coverage report
	@echo "--> Creating GOCOVERDIR"
	@mkdir -p ${COV_UNIT_E2E} ${COV_SIMULATION}
	@echo "--> Cleaning up coverage files, if any"
	@rm -rf ${COV_UNIT_E2E}/* ${COV_SIMULATION}/*
	@echo "--> Building instrumented simulation test binary"
	@go test -c ./app -mod=readonly -covermode=atomic -coverpkg=${COV_PKG} -cover -o ${COV_SIM_CMD}
	@echo "  --> Running Full App Simulation"
	@${COV_SIM_CMD} -test.run TestFullAppSimulation ${COV_SIM_COMMON} > /dev/null 2>&1
	@echo "  --> Running App Simulation After Import"
	@${COV_SIM_CMD} -test.run TestAppSimulationAfterImport ${COV_SIM_COMMON} > /dev/null 2>&1
	@echo "  --> Running App State Determinism Simulation"
	@${COV_SIM_CMD} -test.run TestAppStateDeterminism ${COV_SIM_COMMON} > /dev/null 2>&1
	@echo "--> Running unit & e2e tests coverage"
	@go test -p 1 -timeout 30m -race -covermode=atomic -v -cpu=$$(nproc) -cover $$(go list ./...) ./interchaintest/... -coverpkg=${COV_PKG} -args -test.gocoverdir="${COV_UNIT_E2E}"
	@echo "--> Merging coverage reports"
	@go tool covdata merge -i=${COV_UNIT_E2E},${COV_SIMULATION} -o ${COV_ROOT}
	@echo "--> Converting binary coverage report to text format"
	@go tool covdata textfmt -i=${COV_ROOT} -o ${COV_ROOT}/coverage-merged.out
	@echo "--> Filtering coverage reports"
	@./scripts/filter-coverage.sh ${COV_ROOT}/coverage-merged.out ${COV_ROOT}/coverage-merged-filtered.out
	@echo "--> Generating coverage report"
	@go tool cover -func=${COV_ROOT}/coverage-merged-filtered.out
	@echo "--> Generating HTML coverage report"
	@go tool cover -html=${COV_ROOT}/coverage-merged-filtered.out -o coverage.html
	@echo "--> Coverage report available at coverage.html"
	@echo "--> Cleaning up coverage files"
	@rm -rf ${COV_UNIT_E2E}/* ${COV_SIMULATION}/*
	@echo "--> Running coverage complete"

.PHONY: coverage


##################
###  Protobuf  ###
##################

protoVer=0.14.0
protoImageName=ghcr.io/cosmos/proto-builder:$(protoVer)
protoImage=$(DOCKER) run --rm -v $(CURDIR):/workspace --workdir /workspace $(protoImageName)

proto-all: proto-format proto-lint proto-gen

proto-gen:
	@echo "Generating protobuf files..."
	@$(protoImage) sh ./scripts/protocgen.sh
	@go mod tidy

proto-format:
	@$(protoImage) find ./ -name "*.proto" -exec clang-format -i {} \;

proto-lint:
	@$(protoImage) buf lint proto/ --error-format=json

.PHONY: proto-all proto-gen proto-format proto-lint

#################
###  Linting  ###
#################

golangci_lint_cmd=golangci-lint
golangci_version=v1.63.4

lint:
	@echo "--> Running linter"
	@go install github.com/golangci/golangci-lint/cmd/golangci-lint@$(golangci_version)
	@$(golangci_lint_cmd) run ./... --timeout 15m

lint-fix:
	@echo "--> Running linter and fixing issues"
	@go install github.com/golangci/golangci-lint/cmd/golangci-lint@$(golangci_version)
	@$(golangci_lint_cmd) run ./... --fix --timeout 15m

.PHONY: lint lint-fix

#### FORMAT ####
goimports_version=latest

format-install:
	@echo "--> Installing goimports $(goimports_version)"
	@go install golang.org/x/tools/cmd/goimports@$(goimports_version)
	@echo "--> Installing goimports $(goimports_version) complete"

format: ## Run formatter (goimports)
	@echo "--> Running goimports"
	$(MAKE) format-install
	@find . -name '*.go' -not -name '*.pulsar.go' -not -name '*.pb.go' -exec goimports -w -local github.com/liftedinit/manifest-ledger {} \;

#### GOVULNCHECK ####
govulncheck_version=latest

govulncheck-install:
	@echo "--> Installing govulncheck $(govulncheck_version)"
	@go install golang.org/x/vuln/cmd/govulncheck@$(govulncheck_version)
	@echo "--> Installing govulncheck $(govulncheck_version) complete"

govulncheck: ## Run govulncheck
	@echo "--> Running govulncheck"
	$(MAKE) govulncheck-install
	@govulncheck ./...

#### VET ####

vet: ## Run go vet
	@echo "--> Running go vet"
	@go vet ./...

.PHONY: vet

#### Simulation ####

SIM_PARAMS ?= $(shell pwd)/simulation/sim_params.json
SIM_NUM_BLOCKS ?= 100
SIM_PERIOD ?= 5
SIM_COMMIT ?= true
SIM_ENABLED ?= true
SIM_VERBOSE ?= false
SIM_TIMEOUT ?= 24h
SIM_SEED ?= 42
SIM_COMMON_ARGS = -NumBlocks=${SIM_NUM_BLOCKS} -Enabled=${SIM_ENABLED} -Commit=${SIM_COMMIT} -Period=${SIM_PERIOD} -Params=${SIM_PARAMS} -Verbose=${SIM_VERBOSE} -Seed=${SIM_SEED} -v -timeout ${SIM_TIMEOUT}

sim-full-app:
	@echo "--> Running full app simulation (blocks: ${SIM_NUM_BLOCKS}, commit: ${SIM_COMMIT}, period: ${SIM_PERIOD}, seed: ${SIM_SEED}, params: ${SIM_PARAMS}"
	@go test ./app -run TestFullAppSimulation ${SIM_COMMON_ARGS}

sim-full-app-random:
	$(MAKE) sim-full-app SIM_SEED=$$RANDOM

# Note: known to fail when using app wiring v1
sim-import-export:
	@echo "--> Running app import/export simulation (blocks: ${SIM_NUM_BLOCKS}, commit: ${SIM_COMMIT}, period: ${SIM_PERIOD}, seed: ${SIM_SEED}, params: ${SIM_PARAMS}"
	@go test ./app -run TestAppImportExport ${SIM_COMMON_ARGS}

# Note: known to fail when using app wiring v1
sim-import-export-random:
	$(MAKE) sim-import-export SIM_SEED=$$RANDOM

sim-after-import:
	@echo "--> Running app after import simulation (blocks: ${SIM_NUM_BLOCKS}, commit: ${SIM_COMMIT}, period: ${SIM_PERIOD}, seed: ${SIM_SEED}, params: ${SIM_PARAMS}"
	@go test ./app -run TestAppSimulationAfterImport ${SIM_COMMON_ARGS}

sim-after-import-random:
	$(MAKE) sim-after-import SIM_SEED=$$RANDOM

sim-app-determinism:
	@echo "--> Running app determinism simulation (blocks: ${SIM_NUM_BLOCKS}, commit: ${SIM_COMMIT}, period: ${SIM_PERIOD}, seed: ${SIM_SEED}, params: ${SIM_PARAMS}"
	@go test ./app -run TestAppStateDeterminism ${SIM_COMMON_ARGS}

sim-app-determinism-random:
	$(MAKE) sim-app-determinism SIM_SEED=$$RANDOM

.PHONY: sim-full-app sim-full-app-random sim-import-export sim-after-import sim-app-determinism sim-import-export-random sim-after-import-random sim-app-determinism-random
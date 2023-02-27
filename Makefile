
# Image URL to use all building/pushing image targets
IMG ?= agent:latest
# KUBEBUILDER_ENVTEST_KUBERNETES_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
KUBEBUILDER_ENVTEST_KUBERNETES_VERSION = 1.25.0

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# This is a requirement for 'setup-envtest.sh' in the test target.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

# Get cluster-api version and build ldflags
clusterapi := $(shell go list -m sigs.k8s.io/cluster-api)
clusterapi_version := $(lastword  ., ,$(clusterapi))
clusterapi_version_tuple := $(subst ., ,$(clusterapi_version:v%=%))
clusterapi_major := $(word 1,$(clusterapi_version_tuple))
clusterapi_minor := $(word 2,$(clusterapi_version_tuple))
clusterapi_patch := $(word 3,$(clusterapi_version_tuple))
CLUSTERAPI_LDFLAGS := "-X 'sigs.k8s.io/cluster-api/version.gitMajor=$(clusterapi_major)' -X 'sigs.k8s.io/cluster-api/version.gitMinor=$(clusterapi_minor)' -X 'sigs.k8s.io/cluster-api/version.gitVersion=$(clusterapi_version)'"

.PHONY: all
all: build 

# Directories.
ROOT_DIR:=$(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
TOOLS_DIR := hack/tools
TOOLS_BIN_DIR := $(TOOLS_DIR)/bin
BIN_DIR := bin

GOBUILD=go build

# Define Docker related variables.
REGISTRY ?= projectsveltos
IMAGE_NAME ?= sveltos-agent-manager
ARCH ?= amd64
OS ?= $(shell uname -s | tr A-Z a-z)
K8S_LATEST_VER ?= $(shell curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
export CONTROLLER_IMG ?= $(REGISTRY)/$(IMAGE_NAME)
TAG ?= dev

## Tool Binaries
CONTROLLER_GEN := $(TOOLS_BIN_DIR)/controller-gen
ENVSUBST := $(TOOLS_BIN_DIR)/envsubst
GOIMPORTS := $(TOOLS_BIN_DIR)/goimports
GOLANGCI_LINT := $(TOOLS_BIN_DIR)/golangci-lint
KUSTOMIZE := $(TOOLS_BIN_DIR)/kustomize
GINKGO := $(TOOLS_BIN_DIR)/ginkgo
SETUP_ENVTEST := $(TOOLS_BIN_DIR)/setup_envs
KIND := $(TOOLS_BIN_DIR)/kind
KUBECTL := $(TOOLS_BIN_DIR)/kubectl
CLUSTERCTL := $(TOOLS_BIN_DIR)/clusterctl

$(CONTROLLER_GEN): $(TOOLS_DIR)/go.mod # Build controller-gen from tools folder.
	cd $(TOOLS_DIR); $(GOBUILD) -tags=tools -o $(subst hack/tools/,,$@) sigs.k8s.io/controller-tools/cmd/controller-gen

$(ENVSUBST): $(TOOLS_DIR)/go.mod # Build envsubst from tools folder.
	cd $(TOOLS_DIR); $(GOBUILD) -tags=tools -o $(subst hack/tools/,,$@) github.com/a8m/envsubst/cmd/envsubst

$(KUSTOMIZE): $(TOOLS_DIR)/go.mod # Build kustomize from tools folder.
	cd $(TOOLS_DIR); $(GOBUILD) -tags=tools -o $(BIN_DIR)/kustomize sigs.k8s.io/kustomize/kustomize/v4

$(GOLANGCI_LINT): $(TOOLS_DIR)/go.mod # Build golangci-lint from tools folder.
	cd $(TOOLS_DIR); $(GOBUILD) -tags=tools -o $(subst hack/tools/,,$@) github.com/golangci/golangci-lint/cmd/golangci-lint

$(SETUP_ENVTEST): $(TOOLS_DIR)/go.mod # Build setup-envtest from tools folder.
	cd $(TOOLS_DIR); $(GOBUILD) -tags=tools -o $(subst hack/tools/,,$@) sigs.k8s.io/controller-runtime/tools/setup-envtest

$(GOIMPORTS):
	cd $(TOOLS_DIR); $(GOBUILD) -tags=tools -o $(subst hack/tools/,,$@) golang.org/x/tools/cmd/goimports

$(GINKGO): $(TOOLS_DIR)/go.mod
	cd $(TOOLS_DIR) && $(GOBUILD) -tags tools -o $(subst hack/tools/,,$@) github.com/onsi/ginkgo/v2/ginkgo

$(KIND): $(TOOLS_DIR)/go.mod
	cd $(TOOLS_DIR) && $(GOBUILD) -tags tools -o $(subst hack/tools/,,$@) sigs.k8s.io/kind

$(KUBECTL):
	curl -L https://storage.googleapis.com/kubernetes-release/release/$(K8S_LATEST_VER)/bin/$(OS)/$(ARCH)/kubectl -o $@
	chmod +x $@

$(CLUSTERCTL): $(TOOLS_DIR)/go.mod ## Build clusterctl binary
	cd $(TOOLS_DIR); $(GOBUILD) -ldflags $(CLUSTERAPI_LDFLAGS) -o $(subst hack/tools/,,$@) sigs.k8s.io/cluster-api/cmd/clusterctl
	mkdir -p $(HOME)/.cluster-api # create cluster api init directory, if not present

.PHONY: tools
tools: $(CONTROLLER_GEN) $(ENVSUBST) $(KUSTOMIZE) $(GOLANGCI_LINT) $(SETUP_ENVTEST) $(GOIMPORTS) $(GINKGO)  ## build all tools

.PHONY: clean
clean: ## Remove all built tools
	rm -rf $(TOOLS_BIN_DIR)/*

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: manifests
manifests: $(CONTROLLER_GEN) $(KUSTOMIZE) $(ENVSUBST) ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases
	MANIFEST_IMG=$(CONTROLLER_IMG)-$(ARCH) MANIFEST_TAG=$(TAG) $(MAKE) set-manifest-image
	$(KUSTOMIZE) build config/default | $(ENVSUBST) > manifest/manifest.yaml

.PHONY: generate
generate: $(CONTROLLER_GEN) ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: fmt
fmt: $(GOIMPORTS) ## Run go fmt against code.
	$(GOIMPORTS) -local github.com/projectsveltos -w .
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: lint
lint: $(GOLANGCI_LINT) generate ## Lint codebase
	$(GOLANGCI_LINT) run -v --fast=false --max-issues-per-linter 0 --max-same-issues 0 --timeout 5m	

##@ Testing

ifeq ($(shell go env GOOS),darwin) # Use the darwin/amd64 binary until an arm64 version is available
KUBEBUILDER_ASSETS ?= $(shell $(SETUP_ENVTEST) use --use-env -p path --arch amd64 $(KUBEBUILDER_ENVTEST_KUBERNETES_VERSION))
else
KUBEBUILDER_ASSETS ?= $(shell $(SETUP_ENVTEST) use --use-env -p path $(KUBEBUILDER_ENVTEST_KUBERNETES_VERSION))
endif

# K8S_VERSION for the Kind cluster can be set as environment variable. If not defined,
# this default value is used
ifndef K8S_VERSION
K8S_VERSION := v1.25.2
endif

KIND_CONFIG ?= kind-cluster.yaml
CONTROL_CLUSTER_NAME ?= sveltos-management
KIND_CLUSTER_YAML ?= test/sveltos-management-workload.yaml
TIMEOUT ?= 10m
NUM_NODES ?= 5

.PHONY: kind-test
kind-test: test create-cluster fv $(GINKGO) ## Build docker image; start kind cluster; load docker image; install all cluster api components and run fv

.PHONY: fv
fv: $(GINKGO) ## Run Sveltos Controller tests using existing cluster
	cd test/fv; ../../$(GINKGO) -nodes $(NUM_NODES) --label-filter='FV' --v --trace --randomize-all

.PHONY: test
test: manifests generate fmt vet $(SETUP_ENVTEST) ## Run uts.
	KUBEBUILDER_ASSETS="$(KUBEBUILDER_ASSETS)" go test $(shell go list ./... |grep -v test/fv |grep -v test/helpers) $(TEST_ARGS) -coverprofile cover.out 

.PHONY: create-cluster
create-cluster: $(KIND) $(KUBECTL) $(ENVSUBST) ## Create a new kind cluster designed for development
	sed -e "s/K8S_VERSION/$(K8S_VERSION)/g"  test/$(KIND_CONFIG) > test/$(KIND_CONFIG).tmp
	$(KIND) create cluster --name=$(CONTROL_CLUSTER_NAME) --config test/$(KIND_CONFIG).tmp

	@echo "Start projectsveltos classifier"
	$(MAKE) deploy-projectsveltos

.PHONY: delete-cluster
delete-cluster: $(KIND) ## Deletes the kind cluster $(CONTROL_CLUSTER_NAME)
	$(KIND) delete cluster --name $(CONTROL_CLUSTER_NAME)

##@ Build

.PHONY: build
build: generate fmt vet ## Build manager binary.
	go build -o bin/manager main.go

.PHONY: run
run: manifests generate fmt vet ## Run a controller from your host.
	go run ./main.go

.PHONY: docker-build
docker-build: ## Build docker image with the manager.
	go generate
	docker build -t $(CONTROLLER_IMG)-$(ARCH):$(TAG) .
	MANIFEST_IMG=$(CONTROLLER_IMG)-$(ARCH) MANIFEST_TAG=$(TAG) $(MAKE) set-manifest-image
	$(MAKE) set-manifest-pull-policy

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	docker push ${IMG}

.PHONY: load-image
load-image: docker-build $(KIND)
	$(KIND) load docker-image $(CONTROLLER_IMG)-$(ARCH):$(TAG) --name $(CONTROL_CLUSTER_NAME)

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: install
install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/crd | kubectl delete --ignore-not-found=$(ignore-not-found) -f -

.PHONY: deploy
deploy: manifests $(CONTROLLER_GEN) $(KUSTOMIZE) ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases
	MANIFEST_IMG=$(CONTROLLER_IMG)-$(ARCH) MANIFEST_TAG=$(TAG) $(MAKE) set-manifest-image
	$(KUSTOMIZE) build config/default | kubectl apply -f -

.PHONY: undeploy
undeploy: $(CONTROLLER_GEN) $(KUSTOMIZE) ## Undeploy controller from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases
	MANIFEST_IMG=$(CONTROLLER_IMG)-$(ARCH) MANIFEST_TAG=$(TAG) $(MAKE) set-manifest-image
	$(KUSTOMIZE) build config/default | kubectl delete --ignore-not-found=$(ignore-not-found) -f -

##
set-manifest-image:
	$(info Updating kustomize image patch file for manager resource)
	sed -i'' -e 's@image: .*@image: '"${MANIFEST_IMG}:$(MANIFEST_TAG)"'@' ./config/default/manager_image_patch.yaml

set-manifest-pull-policy:
	$(info Updating kustomize pull policy file for manager resource)
	sed -i'' -e 's@imagePullPolicy: .*@imagePullPolicy: '"$(PULL_POLICY)"'@' ./config/default/manager_pull_policy.yaml


## fv helpers

deploy-projectsveltos: $(KUSTOMIZE)
	# Load projectsveltos image into cluster
	@echo 'Load projectsveltos image into cluster'
	$(MAKE) load-image
	
	@echo 'Install libsveltos CRDs'
	$(KUBECTL) apply -f https://raw.githubusercontent.com/projectsveltos/libsveltos/$(TAG)/config/crd/bases/lib.projectsveltos.io_debuggingconfigurations.yaml
	$(KUBECTL) apply -f https://raw.githubusercontent.com/projectsveltos/libsveltos/$(TAG)/config/crd/bases/lib.projectsveltos.io_classifiers.yaml
	$(KUBECTL) apply -f https://raw.githubusercontent.com/projectsveltos/libsveltos/$(TAG)/config/crd/bases/lib.projectsveltos.io_classifierreports.yaml
	$(KUBECTL) apply -f https://raw.githubusercontent.com/projectsveltos/libsveltos/$(TAG)/config/crd/bases/lib.projectsveltos.io_healthchecks.yaml
	$(KUBECTL) apply -f https://raw.githubusercontent.com/projectsveltos/libsveltos/$(TAG)/config/crd/bases/lib.projectsveltos.io_healthcheckreports.yaml

	# Install projectsveltos manager components
	@echo 'Install projectsveltos classifier components'
	cd config/manager && ../../$(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | $(ENVSUBST) | $(KUBECTL) apply -f-

	@echo "Waiting for projectsveltos manager to be available..."
	$(KUBECTL) wait --for=condition=Available deployment/sveltos-agent-manager -n projectsveltos --timeout=$(TIMEOUT)

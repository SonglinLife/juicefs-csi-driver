# Copyright 2018 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

IMAGE?=juicedata/juicefs-csi-driver
REGISTRY?=docker.io
DASHBOARD_IMAGE?=juicedata/csi-dashboard
TARGETARCH?=amd64
VERSION=$(shell git describe --tags --match 'v*' --always --dirty)
GIT_BRANCH?=$(shell git rev-parse --abbrev-ref HEAD)
GIT_COMMIT?=$(shell git rev-parse HEAD)
DEV_TAG=dev-$(shell git describe --always --dirty)
BUILD_DATE?=$(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
PKG=github.com/juicedata/juicefs-csi-driver
CLIENT_GO_PKG=k8s.io/client-go
LDFLAGS?="-X ${PKG}/pkg/driver.driverVersion=${VERSION} \
		  -X ${PKG}/pkg/driver.gitCommit=${GIT_COMMIT} \
		  -X ${PKG}/pkg/driver.buildDate=${BUILD_DATE} \
		  -X ${CLIENT_GO_PKG}/pkg/version.buildDate=${BUILD_DATE} \
		  -X ${CLIENT_GO_PKG}/pkg/version.gitVersion=${VERSION} \
		  -X ${CLIENT_GO_PKG}/pkg/version.gitCommit=${GIT_COMMIT} \
		  -s -w"
GO111MODULE=on

GOPROXY?=https://goproxy.io
GOPATH=$(shell go env GOPATH)
GOOS=$(shell go env GOOS)
GOBIN=$(shell pwd)/bin

.PHONY: juicefs-csi-driver
juicefs-csi-driver:
	mkdir -p bin
	CGO_ENABLED=0 GOOS=linux go build -ldflags ${LDFLAGS} -o bin/juicefs-csi-driver ./cmd/

.PHONY: verify
verify:
	./hack/verify-all

.PHONY: test
test:
	go test -gcflags=all=-l -v -cover ./pkg/... -coverprofile=cov1.out

.PHONY: test-sanity
test-sanity:
	go test -v -cover ./tests/sanity/... -coverprofile=cov2.out

.PHONY: dashboard-dist
dashboard-dist:
	cd dashboard-ui-v2 && pnpm run build

.PHONY: dashboard-lint
dashboard-lint:
	cd dashboard-ui-v2 && pnpm run lint

.PHONY: dashboard
dashboard:
	mkdir -p bin
	CGO_ENABLED=0 go build -tags=jsoniter -ldflags ${LDFLAGS} -o bin/juicefs-csi-dashboard ./cmd/dashboard/

.PHONY: dashboard-dev
dashboard-dev: dashboard
	./bin/juicefs-csi-dashboard -v=6 --dev --static-dir=./dashboard-ui-v2/dist

.PHONY: dashboard-image
dashboard-image: juicefs-csi-driver dashboard
	docker build --build-arg HTTP_PROXY=$(HTTP_PROXY) --build-arg HTTPS_PROXY=$(HTTPS_PROXY) --build-arg GOPROXY=$(GOPROXY) \
		-t $(REGISTRY)/juicedata/csi-dashboard:$(VERSION) -f docker/dashboard.Dockerfile .

# build deploy yaml
yaml:
	echo "# DO NOT EDIT: generated by 'kustomize build'" > deploy/k8s.yaml
	kustomize build deploy/kubernetes/release >> deploy/k8s.yaml
	cp deploy/k8s.yaml deploy/k8s_before_v1_18.yaml
	sed -i.orig 's@storage.k8s.io/v1@storage.k8s.io/v1beta1@g' deploy/k8s_before_v1_18.yaml

	echo "# DO NOT EDIT: generated by 'kustomize build'" > deploy/webhook.yaml
	kustomize build deploy/kubernetes/webhook >> deploy/webhook.yaml
	echo "# DO NOT EDIT: generated by 'kustomize build'" > deploy/webhook-with-certmanager.yaml
	kustomize build deploy/kubernetes/webhook-with-certmanager >> deploy/webhook-with-certmanager.yaml
	./hack/update_install_script.sh

.PHONY: deploy
deploy: yaml
	kubectl apply -f $<

.PHONY: deploy-delete
uninstall: yaml
	kubectl delete -f $<

# build dev image
.PHONY: image-dev
image-dev: juicefs-csi-driver dashboard
	docker build --build-arg TARGETARCH=$(TARGETARCH) -t $(REGISTRY)/$(IMAGE):$(DEV_TAG) -f docker/dev.Dockerfile bin
	docker build --build-context project=. --build-context ui=dashboard-ui-v2/ -f docker/dashboard.Dockerfile \
		-t $(REGISTRY)/$(DASHBOARD_IMAGE):$(DEV_TAG) .

# push dev image
.PHONY: push-dev
push-dev:
ifeq ("$(DEV_K8S)", "microk8s")
	docker image save -o juicefs-csi-driver-$(DEV_TAG).tar $(IMAGE):$(DEV_TAG)
	sudo microk8s.ctr image import juicefs-csi-driver-$(DEV_TAG).tar
	rm -f juicefs-csi-driver-$(DEV_TAG).tar
	docker image save -o juicefs-csi-dashboard-$(DEV_TAG).tar $(REGISTRY)/$(DASHBOARD_IMAGE):$(DEV_TAG)
	sudo microk8s.ctr image import juicefs-csi-dashboard-$(DEV_TAG).tar
	rm -f juicefs-csi-dashboard-$(DEV_TAG).tar
else ifeq ("$(DEV_K8S)", "kubeadm")
	docker tag $(IMAGE):$(DEV_TAG) $(DEV_REGISTRY):$(DEV_TAG)
	docker push $(DEV_REGISTRY):$(DEV_TAG)
else
	minikube cache add $(IMAGE):$(DEV_TAG)
endif

.PHONY: deploy-dev/kustomization.yaml
deploy-dev/kustomization.yaml:
	mkdir -p $(@D)
	touch $@
	cd $(@D); kustomize edit add resource ../deploy/kubernetes/release;
ifeq ("$(DEV_K8S)", "kubeadm")
	cd $(@D); kustomize edit set image juicedata/juicefs-csi-driver=$(DEV_REGISTRY):$(DEV_TAG)
else
	cd $(@D); kustomize edit set image juicedata/juicefs-csi-driver=:$(DEV_TAG)
endif

deploy-dev/k8s.yaml: deploy-dev/kustomization.yaml deploy/kubernetes/release/*.yaml
	echo "# DO NOT EDIT: generated by 'kustomize build $(@D)'" > $@
	kustomize build $(@D) >> $@
	# Add .orig suffix only for compactiblity on macOS
ifeq ("$(DEV_K8S)", "microk8s")
	sed -i 's@/var/lib/kubelet@/var/snap/microk8s/common/var/lib/kubelet@g' $@
endif
ifeq ("$(DEV_K8S)", "kubeadm")
	sed -i.orig 's@juicedata/juicefs-csi-driver.*$$@$(DEV_REGISTRY):$(DEV_TAG)@g' $@
else
	sed -i.orig 's@juicedata/juicefs-csi-driver.*$$@juicedata/juicefs-csi-driver:$(DEV_TAG)@g' $@
	sed -i.orig 's@juicedata/csi-dashboard.*$$@juicedata/csi-dashboard:$(DEV_TAG)@g' $@
endif

.PHONY: deploy-dev
deploy-dev: deploy-dev/k8s.yaml
	kapp deploy --app juicefs-csi-driver --file $<

.PHONY: delete-dev
delete-dev: deploy-dev/k8s.yaml
	kapp delete --app juicefs-csi-driver

.PHONY: install-dev
install-dev: verify test image-dev push-dev deploy-dev/k8s.yaml deploy-dev

bin/mockgen: | bin
	go install github.com/golang/mock/mockgen@v1.5.0

mockgen: bin/mockgen
	./hack/update-gomock

npm-install:
	npm install
	npm ci

check-docs:
	npm run markdown-lint
	autocorrect --fix ./docs/
	npm run check-broken-link

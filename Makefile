OVERLAY ?= dev
REGISTRY ?= explained
TAG ?= dev

# Where the service sources live. This directory sits inside the explAIned tree alongside the
# services, so the default is simply the parent.
SRC ?= ..

.PHONY: help build diff apply delete restart images push sync-upstream check-drift

help:
	@echo "make build      OVERLAY=dev|homelab   render manifests to stdout"
	@echo "make diff       OVERLAY=dev|homelab   diff the overlay against the live cluster"
	@echo "make apply      OVERLAY=dev|homelab   apply it"
	@echo "make delete     OVERLAY=dev|homelab   tear it down — on dev this takes the namespace, and the PVCs with it"
	@echo "make restart    OVERLAY=dev|homelab   roll every Deployment (after editing explained-endpoints)"
	@echo "make images     TAG=... [REGISTRY=]   build and tag all nine images"
	@echo "make push       TAG=... REGISTRY=...  push them"
	@echo "make sync-upstream                    re-copy the files vendored from $(SRC)"
	@echo "make check-drift                      fail if those copies have drifted"

# The namespace differs per overlay — `explained` for dev, the pre-existing `apps` on the
# homelab — so it is read off the overlay rather than duplicated here. Reading the
# kustomization rather than the rendered output matters: the homelab overlay contains no
# Namespace object at all, because its deploy account may not create one.
NAMESPACE = $(shell awk '/^namespace:/{print $$2; exit}' overlays/$(OVERLAY)/kustomization.yaml)

build:
	kubectl kustomize overlays/$(OVERLAY)

diff:
	kubectl diff -k overlays/$(OVERLAY) || true

apply:
	kubectl apply -k overlays/$(OVERLAY)

delete:
	kubectl delete -k overlays/$(OVERLAY)

# explained-endpoints is the one hand-written ConfigMap, so it has no content hash in its name
# and editing it does not roll anything on its own. This is the missing half of that edit.
restart:
	kubectl rollout restart deployment -l app.kubernetes.io/part-of=explained \
		$(if $(NAMESPACE),-n $(NAMESPACE),)

images:
	docker build -t $(REGISTRY)/identity-service:$(TAG)       $(SRC)/explAInedIdentityService
	docker build -t $(REGISTRY)/article-service:$(TAG)        $(SRC)/explAInedArticleService
	docker build -t $(REGISTRY)/comment-service:$(TAG)        $(SRC)/explAInedCommentService
	docker build -t $(REGISTRY)/profile-service:$(TAG)        $(SRC)/explAInedProfileService
	docker build -t $(REGISTRY)/recommendation-service:$(TAG) $(SRC)/explAInedRecommendationService
	docker build -t $(REGISTRY)/event-consumer-service:$(TAG) $(SRC)/explAInedArticleEventConsumerService
	docker build -t $(REGISTRY)/faiss-service:$(TAG)          $(SRC)/explAIned-faiss
	docker build -t $(REGISTRY)/ranking-service:$(TAG)        $(SRC)/explAIned-ml
	docker build -t $(REGISTRY)/ml-jobs:$(TAG) -f $(SRC)/explAIned-ml/Dockerfile.jobs $(SRC)/explAIned-ml

push:
	@for i in identity-service article-service comment-service profile-service \
	          recommendation-service event-consumer-service faiss-service ranking-service ml-jobs; do \
	  docker push $(REGISTRY)/$$i:$(TAG); \
	done

# Three files here are copies of files that live in $(SRC). Copies rot, so there is a target
# to refresh them and a target that fails when they have rotted.
sync-upstream:
	cp $(SRC)/explAInedArticleEventConsumerService/schema.sql base/infra/files/clickhouse-schema.sql
	cp $(SRC)/monitoring/rules/recommendations.yml           base/monitoring/files/recommendations.yml
	cp $(SRC)/monitoring/grafana/provisioning/dashboards/microservices.json base/monitoring/files/microservices.json

check-drift:
	@diff -q $(SRC)/explAInedArticleEventConsumerService/schema.sql base/infra/files/clickhouse-schema.sql \
	  || { echo "clickhouse-schema.sql has drifted — run make sync-upstream"; exit 1; }
	@diff -q $(SRC)/monitoring/rules/recommendations.yml base/monitoring/files/recommendations.yml \
	  || { echo "recommendations.yml has drifted — run make sync-upstream"; exit 1; }
	@diff -q $(SRC)/monitoring/grafana/provisioning/dashboards/microservices.json base/monitoring/files/microservices.json \
	  || { echo "microservices.json has drifted — run make sync-upstream"; exit 1; }
	@echo "vendored files match $(SRC)"

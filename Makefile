OVERLAY ?= dev
NAMESPACE ?= explained
REGISTRY ?= explained
TAG ?= dev

# Where the service sources live. Every image is built from its own directory in that repo.
SRC ?= ../explAIned

.PHONY: help build diff apply delete restart images sync-upstream check-drift

help:
	@echo "make build      OVERLAY=dev|prod   render manifests to stdout"
	@echo "make diff       OVERLAY=dev|prod   diff the overlay against the live cluster"
	@echo "make apply      OVERLAY=dev|prod   apply it"
	@echo "make delete     OVERLAY=dev|prod   tear it down (volumes survive)"
	@echo "make restart                       roll every Deployment (after editing explained-endpoints)"
	@echo "make images     TAG=... SRC=...    build and tag all nine images"
	@echo "make sync-upstream                 re-copy the files vendored from $(SRC)"
	@echo "make check-drift                   fail if those copies have drifted"

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
	kubectl -n $(NAMESPACE) rollout restart deployment

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

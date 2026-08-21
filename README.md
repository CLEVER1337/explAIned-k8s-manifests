# explAIned-k8s-manifests

Kubernetes manifests for the explAIned stack: six .NET services, two Python services, nine
offline jobs, five stateful dependencies and the monitoring pair — as plain YAML with
kustomize overlays. No Helm, no operators, nothing to install before `kubectl apply`.

This directory sits inside the explAIned tree next to the services it deploys, and carries its
own git history — it deploys the stack, it is not part of it, and it moves on a release
cadence rather than on a feature one. Everything below resolves paths against the parent
directory (`SRC` in the Makefile), so nothing needs a checkout anywhere else.

Nothing here is generated from the sources. The three files that are copies of upstream files
are listed under [Vendored files](#vendored-files), and `make check-drift` fails when they rot.

```
base/
  namespace.yaml
  config/shared-config.yaml            the one ConfigMap everything reads
  config/*-appsettings.json            two services that need their appsettings.json replaced
  storage/pvc.yaml                     the two shared volumes
  infra/                               postgres, redis, kafka, elasticsearch, clickhouse
  services/                            the eight workloads + PodDisruptionBudgets
  jobs/                                seven CronJobs
  monitoring/                          prometheus + grafana, with the dashboards from upstream
  ingress.yaml
overlays/
  dev/                                 one node, one replica, committed dev credentials
  prod/                                real hostnames, real storage, secrets you supply
```

## Quick start

Needs kustomize v5 syntax — `kubectl` 1.27+ (its built-in kustomize) or a standalone
`kustomize` v5. The `labels:`/`pairs:` and `patches:`/`target:` blocks are not understood by
the v4 vintage still shipped with older kubectl.

```bash
# 1. Build the nine images, from the service directories one level up.
#    TAG=dev is what overlays/dev expects.
make images TAG=dev

# 2. Load them into your cluster (kind shown; minikube uses `minikube image load`)
for i in identity article comment profile recommendation event-consumer faiss ranking; do
  kind load docker-image explained/$i-service:dev
done
kind load docker-image explained/ml-jobs:dev

# 3. Deploy
make apply OVERLAY=dev

# 4. Watch it come up. Expect ~2 minutes: Elasticsearch and Kafka are the slow ones, and the
#    .NET services sit in their wait-for-postgres init container until PostgreSQL is ready.
kubectl -n explained get pods -w
```

Then point `api.explained.local` and `grafana.explained.local` at your ingress controller
(`/etc/hosts` is fine), or skip the ingress entirely:

```bash
kubectl -n explained port-forward svc/identity-service 5125:5125
kubectl -n explained port-forward svc/grafana 3000:3000
kubectl -n explained port-forward svc/prometheus 9090:9090   # no ingress, on purpose
```

`make delete OVERLAY=dev` tears it down. PersistentVolumeClaims survive — deleting a namespace
does remove them, so use the make target rather than `kubectl delete ns explained` if you want
the data back.

## How configuration works

One ConfigMap, `explained-endpoints`, holds *addressable building blocks* — `POSTGRES_HOST`,
`REDIS_PORT`, `JWT_ISSUER`, `ARTICLES_BASE_URL`. It holds no finished settings. Each workload
pulls it in with `envFrom` and composes what its own runtime wants:

```yaml
- name: ConnectionStrings__PostgreSQL
  value: Host=$(POSTGRES_HOST);Port=$(POSTGRES_PORT);Database=articles;Username=$(POSTGRES_USER);Password=$(POSTGRES_PASSWORD)
```

The kubelet expands `$(VAR)` against everything already in scope, `envFrom` included, so the
Secret only ever has to carry the password — never a whole connection string with a hostname
baked into it. Python services get `REDIS_URL` built the same way, because pydantic-settings
reads flat uppercase names.

Five Secrets, all supplied by the overlay: `explained-postgres`, `explained-redis`,
`explained-elasticsearch`, `explained-jwt`, `explained-grafana`.

### The one thing that will bite you

`explAInedRecommendationService/Program.cs:9` and
`explAInedArticleEventConsumerService/Program.cs:7` both call
`builder.Configuration.AddJsonFile("appsettings.json")`. `CreateBuilder` has already loaded
that file; adding it again appends it as the **last** provider, and the last provider wins —
above environment variables. So for those two services, and only those two, `ConnectionStrings__Redis`
and friends set in the Deployment are silently ignored and the service dials `localhost`.

CLAUDE.md already warns about this pattern; these two are where it actually happens.

The workaround here is to mount a *smaller* `appsettings.json` over the one in the image
(`base/config/*-appsettings.json`), keeping only genuinely static settings — log levels, the
feed's latency budget, the sink's batch size — and deleting every addressable key. What is not
in the file cannot shadow anything, so env vars work normally again.

**Deleting those two `AddJsonFile` lines upstream makes both files unnecessary.** That is the
real fix; this repo works either way.

## Bootstrap order

Nothing here depends on being applied in a particular order, but three things have to happen
before the stack is fully functional, and two of them are Jobs that run automatically:

| | what | how |
|---|---|---|
| 1 | four PostgreSQL databases (`asd`, `articles`, `comments`, `profiles`) | initdb ConfigMap, first boot only |
| 2 | two Kafka topics, 3 partitions each | `kafka-create-topics` Job, retries until the broker answers |
| 3 | ClickHouse schema (`explained.user_events`, `explained.feed_impressions`) | `clickhouse-schema` Job, every statement is `IF NOT EXISTS` |

EF Core migrations are not in that list: every .NET service applies its own at startup
(`db.Database.Migrate()`), which is also why each has a `wait-for-postgres` init container —
the migration is not retried, so a pod that starts before PostgreSQL simply throws.

The recommendation loop needs a fourth thing that no Job can do for you: **data**. Until
`ml-embeddings` and `faiss-build-index` have run, `/search` answers 503 and the feed serves
its lower rungs. That is a working system, not an outage — see the degradation ladder in
`explAInedRecommendationService/CONTRACT.md`.

## Scaling notes

Replica counts are not uniform, because three of these workloads are Kafka consumers and a
consumer's replica count is a consumer-group size.

- **article-service** runs the API *and* both background workers. An HPA scales it between 2
  and **3** — the partition count of `articles.events`. A fourth replica joins the indexer
  group holding no partition. Note also that every replica polls the same outbox rows;
  that is safe (at-least-once, which the indexer tolerates) but duplicated. Splitting
  `OutboxPublisherHostedService` into its own single-replica Deployment is the clean fix and
  needs a code change to make the hosted services individually switchable.
- **event-consumer-service** is pinned at 1 with no HPA. A sink that scales itself is a sink
  that rebalances under load.
- **faiss-service** is pinned at 1 because the index is a full in-memory copy per pod — the
  same reason its Dockerfile runs one uvicorn worker. Memory scales with corpus size, not
  traffic.
- Everything else scales on CPU.

## Monitoring

The compose stack listed eight static `localhost:` targets. That does not survive pods, so
Prometheus here uses pod service discovery: workloads opt in with `prometheus.io/scrape`,
`prometheus.io/port` and `prometheus.io/path` annotations, and carry a label
`explained.io/service: article` which is relabelled to `service`.

That label is the compatibility bridge — every panel in `microservices.json` and every alert
in `recommendations.yml` selects on `service="article"`, `service="faiss"` and so on, so both
carry over from the compose setup untouched.

RBAC is a namespaced `Role`, matching `own_namespace: true` in the scrape config. Widen both
together or neither.

## Vendored files

Three files are copies of files from the parent directory. Copies rather than symlinks on
purpose: `kustomize build` follows the file into the ConfigMap, so a symlink pointing outside
the kustomization root would break the build the moment this directory is rendered from
anywhere else.

| here | upstream (relative to `..`) |
|---|---|
| `base/infra/files/clickhouse-schema.sql` | `explAInedArticleEventConsumerService/schema.sql` |
| `base/monitoring/files/recommendations.yml` | `monitoring/rules/recommendations.yml` |
| `base/monitoring/files/microservices.json` | `monitoring/grafana/provisioning/dashboards/microservices.json` |

`make sync-upstream` refreshes them, `make check-drift` fails when they have diverged — worth
running in CI.

## Known gaps

Things this repo does not solve, in rough order of how much they matter.

**No health endpoints.** None of the six .NET services has one, so their probes hit `/metrics`
instead. That proves Kestrel is serving; it does not prove PostgreSQL, Redis or Kafka are
reachable. `AddHealthChecks()` with a `DbContext` check, mapped at `/health/ready`, is a small
change upstream and the single biggest improvement available to these manifests.

**Data protection keys are per-pod.** The identity service's key ring lands in an `emptyDir`
and dies with the pod. JWTs are unaffected — they are signed with the symmetric `Jwt:Key` —
but anything ASP.NET Identity protects (email confirmation, password reset) is only valid on
the pod that issued it. Persist the ring to Redis before shipping those flows.

**Two ReadWriteMany volumes.** `faiss-index` (build-index writes, the service reads) and
`mlflow-store` (train-lightgbm writes, the ranking service reads). The dev overlay downgrades
both to ReadWriteOnce, which works only because every pod lands on the same node. In prod,
either point them at a real RWX StorageClass or replace the mechanism: an object-store sync
for the index, a proper MLflow tracking server instead of SQLite on a shared filesystem.

**No NetworkPolicies.** Everything can reach everything. `faiss-service`, `ranking-service`
and the databases have no business being reachable from outside the loop, and a default-deny
plus per-service allows is the obvious next layer. Left out rather than half-done.

**Image tags for the five dependencies** — `apache/kafka:4.1.0`,
`clickhouse/clickhouse-server:25.3-alpine`, `docker.elastic.co/elasticsearch/elasticsearch:9.3.0`,
`prom/prometheus:v3.1.0`, `grafana/grafana:11.5.1` — were chosen to match what the services
expect, not verified against a registry from this machine. The one that is a hard constraint
is Elasticsearch: the article service pins `Elastic.Clients.Elasticsearch` 9.3.x, and an 8.x
server fails the client's product check. Kafka only needs to be 4.x for KRaft. Check the tags
resolve before your first apply.

**Secrets are Kubernetes Secrets**, which is base64, not encryption. The dev values are
committed deliberately (they are already in the repo's `appsettings.json`); prod expects
gitignored `.env` files, and the honest upgrade is SOPS or External Secrets.

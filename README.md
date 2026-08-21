# explAIned-k8s-manifests

Kubernetes manifests for the explAIned stack: six .NET services, two Python services, seven
offline jobs, the dependencies they need and the monitoring pair — as plain YAML with
kustomize overlays. No Helm, no operators, nothing to install before `kubectl apply`.

This directory sits inside the explAIned tree next to the services it deploys, and carries its
own git history: it deploys the stack, it is not part of it. Everything resolves paths against
the parent directory (`SRC` in the Makefile), so nothing needs a checkout anywhere else.

```
base/                          everything both environments share
components/
  self-hosted-databases/       PostgreSQL, ClickHouse, Elasticsearch as StatefulSets
  autoscaling/                 HPAs + PodDisruptionBudgets
overlays/
  dev/                         kind/minikube: databases in-cluster, credentials committed
  homelab/                     the k3s cluster in clever-homelab — the real target
```

The two overlays differ more than a base/overlay split usually implies, and the split of
`base` from `components` is what carries that: **base contains nothing that assumes a
cluster-admin credential or an API group beyond core/apps/batch/networking.** That is not
tidiness, it is the homelab's deploy account — see below.

## The two targets

|  | `overlays/dev` | `overlays/homelab` |
|---|---|---|
| cluster | kind / minikube / Docker Desktop | k3s, 1 server + 2 agents |
| namespace | `explained`, created | `apps`, pre-existing — cannot create one |
| PostgreSQL / ClickHouse / Elasticsearch | in-cluster StatefulSets | VMs at `10.42.0.20/.21/.22` |
| Redis / Kafka | in-cluster | in-cluster |
| autoscaling | off (one replica of everything) | **not permitted** |
| external access | Ingress → gateway | NodePort → gateway, Caddy in front |
| credentials | committed | `make secrets-pull`, gitignored |
| images | `explained/*:dev`, loaded locally | `git.homelab.lan/ci/explained-*` |

`overlays/homelab/README.md` covers the first run there. For dev:

```bash
make images TAG=dev                     # nine images from the directories one level up
for i in identity article comment profile recommendation event-consumer faiss ranking; do
  kind load docker-image explained/$i-service:dev
done
kind load docker-image explained/ml-jobs:dev
make apply OVERLAY=dev
```

Needs kustomize v5 syntax — `kubectl` 1.27+ or a standalone `kustomize` v5. The
`labels:`/`pairs:`, `components:` and `patches:`/`target:` blocks are not understood by the v4
vintage shipped with older kubectl.

## How configuration works

One ConfigMap, `explained-endpoints`, holds *addressable building blocks* — `POSTGRES_HOST`,
`REDIS_PORT`, `JWT_ISSUER`, `CLICKHOUSE_USER`. It holds no finished settings. Each workload
pulls it in with `envFrom` and composes what its own runtime wants:

```yaml
- name: ConnectionStrings__PostgreSQL
  value: Host=$(POSTGRES_HOST);Port=$(POSTGRES_PORT);Database=articles;Username=$(POSTGRES_USER);Password=$(POSTGRES_PASSWORD)
```

The kubelet expands `$(VAR)` against everything already in scope, `envFrom` included, so the
Secret only ever carries the password — never a whole connection string with a hostname baked
into it. Python services get `REDIS_URL` built the same way, because pydantic-settings reads
flat uppercase names.

The payoff is that moving the databases out of the cluster is a six-key patch in the homelab
overlay and nothing else changes.

Six Secrets, supplied by the overlay: `explained-postgres`, `explained-redis`,
`explained-clickhouse`, `explained-elasticsearch`, `explained-jwt`, `explained-grafana`.

### The one thing that will bite you

`explAInedRecommendationService/Program.cs` and
`explAInedArticleEventConsumerService/Program.cs` both call
`builder.Configuration.AddJsonFile("appsettings.json")`. `CreateBuilder` has already loaded
that file; adding it again appends it as the **last** provider, and the last provider wins —
above environment variables. So for those two services, and only those two,
`ConnectionStrings__Redis` and friends set in the Deployment are silently ignored and the
service dials `localhost`.

The workaround here is to mount a *smaller* `appsettings.json` over the one in the image
(`base/config/*-appsettings.json`), keeping only genuinely static settings — log levels, the
feed's latency budget, the sink's batch size — and deleting every addressable key. What is not
in the file cannot shadow anything, so env vars work normally again.

**Deleting those two `AddJsonFile` lines upstream makes both files unnecessary.**

## Routing

There is one nginx pod, `gateway`, holding the whole path map:

```
/user  /session   → identity-service
/articles         → article-service
/comments         → comment-service
/profiles         → profile-service
/api/feed         → recommendation-service
```

Nothing is rewritten — the services already own disjoint top-level paths, so each request
arrives with the path it expects.

It exists because the homelab has no ingress controller: Traefik is disabled there (80 and 443
on the hypervisor are DNAT'd to Caddy, so a controller could not claim them) and Caddy maps one
hostname to one NodePort. Rather than five hostnames and five NodePorts, the routing moved
into the cluster. Dev puts an Ingress in front of the same gateway, so both environments share
one path map and cannot drift.

`faiss-service`, `ranking-service`, `event-consumer-service` and Prometheus are deliberately
unrouted.

## Monitoring

Prometheus discovers targets over **DNS**, against the headless Services in
`base/services/metrics-endpoints.yaml`. The obvious choice is pod service discovery, and the
first draft used it — it does not survive the homelab, whose deploy account cannot create the
ServiceAccount and Role that a Kubernetes SD needs. DNS needs no API access, produces the same
target list, and works identically on kind and k3s, so there is one scrape config instead of
two.

The `service` label is set per scrape job, which is the compatibility bridge: every panel in
`microservices.json` and every alert in `recommendations.yml` selects on `service="article"`,
`service="faiss"` and so on, so both carry over from the docker-compose setup untouched.

## Bootstrap order

Nothing has to be applied in a particular order. Three things must happen before the stack is
functional, and two are Jobs that retry until they can:

| | what | how |
|---|---|---|
| 1 | four PostgreSQL databases (`asd`, `articles`, `comments`, `profiles`) | dev: initdb ConfigMap, first boot only. homelab: `pg_app_databases` in the Ansible inventory |
| 2 | two Kafka topics, 3 partitions each | `kafka-create-topics` Job |
| 3 | ClickHouse schema (`explained.user_events`, `explained.feed_impressions`) | `clickhouse-schema` Job — every statement is `IF NOT EXISTS`, and its `CREATE DATABASE` is allowed to fail where the account may not create one |

Both Jobs carry `ttlSecondsAfterFinished: 3600`, which matters for a second reason: a Job spec
is immutable, so re-applying the overlay while a completed one is still around fails if its
spec changed. An hour after it finishes it is gone and the next apply recreates it. To force
it sooner, `kubectl delete job kafka-create-topics` and apply again.

EF Core migrations are not in that list: every .NET service applies its own at startup
(`db.Database.Migrate()`), which is why each has a `wait-for-postgres` init container — the
migration is not retried, so a pod that starts before PostgreSQL simply throws.

The recommendation loop needs a fourth thing no Job can supply: **data**. Until `ml-embeddings`
and `faiss-build-index` have run, `/search` answers 503 and the feed serves its lower rungs.
That is a working system, not an outage — see the ladder in
`explAInedRecommendationService/CONTRACT.md`.

## Scaling notes

Replica counts are not uniform, because three workloads are Kafka consumers and a consumer's
replica count is a consumer-group size.

- **article-service** runs the API *and* both background workers. The HPA (dev/prod-style
  clusters only) caps at **3** — the partition count of `articles.events`. A fourth replica
  joins the indexer group holding no partition. Note also that every replica polls the same
  outbox rows: safe, since at-least-once is what the indexer already tolerates, but
  duplicated. Splitting `OutboxPublisherHostedService` into its own single-replica Deployment
  is the clean fix and needs a code change to make the hosted services individually
  switchable.
- **event-consumer-service** is pinned at 1. A sink that scales itself is a sink that
  rebalances under load.
- **faiss-service** is pinned at 1 because the index is a full in-memory copy per pod — the
  same reason its Dockerfile runs one uvicorn worker. Memory scales with corpus size, not
  traffic.

## Vendored files

Three files are copies of files from the parent directory. Copies rather than symlinks on
purpose: `kustomize build` follows the file into a ConfigMap, and a symlink pointing outside
the kustomization root breaks the build.

| here | upstream (relative to `..`) |
|---|---|
| `base/infra/files/clickhouse-schema.sql` | `explAInedArticleEventConsumerService/schema.sql` |
| `base/monitoring/files/recommendations.yml` | `monitoring/rules/recommendations.yml` |
| `base/monitoring/files/microservices.json` | `monitoring/grafana/…/microservices.json` |

`make sync-upstream` refreshes them, `make check-drift` fails when they diverge — worth
running in CI.

## Known gaps

**No health endpoints.** None of the six .NET services has one, so their probes hit `/metrics`.
That proves Kestrel is serving; it does not prove PostgreSQL, Redis or Kafka are reachable.
`AddHealthChecks()` with a `DbContext` check, mapped at `/health/ready`, is a small change
upstream and the single biggest improvement available to these manifests.

**Data protection keys are per-pod.** The identity service's key ring lands in an `emptyDir`.
JWTs are unaffected — symmetric `Jwt:Key` — but anything ASP.NET Identity protects (email
confirmation, password reset) is only valid on the pod that issued it. Persist the ring to
Redis before shipping those flows.

**No NetworkPolicies.** Everything can reach everything. The deploy account *can* create them
(`networking.k8s.io` is in its Role), so this is a gap rather than a blocker — a default-deny
plus per-service allows is the obvious next layer.

**Dependency image tags** — `apache/kafka:4.1.0`, `nginxinc/nginx-unprivileged:1.27-alpine`,
`prom/prometheus:v3.1.0`, `grafana/grafana:11.5.1`, and in the dev-only component
`clickhouse/clickhouse-server:25.3-alpine` and
`docker.elastic.co/elasticsearch/elasticsearch:9.3.0` — were chosen to match what the services
expect, not verified against a registry. Elasticsearch is the one hard constraint: the article
service pins `Elastic.Clients.Elasticsearch` 9.3.x and an 8.x server fails the client's
product check. In the homelab that server is a VM pinned at 9.4.1 by Ansible, which satisfies
it.

**Nothing here has been rendered.** `kubectl` and `kustomize` are not installed on the machine
these were written on. Every YAML and JSON file parses, and the Ansible changes pass
`ansible-playbook --syntax-check`, but `kustomize build` has not run against either overlay.
Do that before the first apply.

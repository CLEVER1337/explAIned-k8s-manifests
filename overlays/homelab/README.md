# overlays/homelab

Deploys explAIned onto the k3s cluster in **clever-homelab**: one server (tainted) and two
agents, on a NAT-only libvirt network behind a Caddy that terminates TLS for the LAN.

This overlay does not build out of the box. `secrets/*.env` are gitignored and four of the six
do not exist anywhere but the database guests, so `kustomize build` failing with
"no such file or directory" is the intended first experience — better than succeeding with an
invented password.

## What this environment decides for you

| | |
|---|---|
| **Databases** | PostgreSQL, ClickHouse and Elasticsearch already run on VMs (`.20`, `.21`, `.22`), tuned for the RAM those guests have. The `self-hosted-databases` component is **not** added — the endpoints ConfigMap is repointed instead. Redis and Kafka have no VM, so they stay in-cluster. |
| **RBAC** | The deploy account is namespace-scoped: core, apps, batch, networking. No `autoscaling`, no `policy`, no RBAC, no namespaces. So no HPAs, no PodDisruptionBudgets, no ServiceAccounts, and `apps` is joined rather than created. Prometheus discovers targets over DNS for exactly this reason. |
| **Ingress** | There isn't one. Traefik is disabled — 80 and 443 on the hypervisor are DNAT'd to Caddy, so an in-cluster controller could not claim them. Caddy proxies one hostname to one NodePort; the path routing happens in the `gateway` pod. |
| **Storage** | `local-path` only, so ReadWriteOnce. That works out fine: a local-path PV carries node affinity, the scheduler pins every pod mounting it to that node, and RWO means "one node", not "one pod" — so the FAISS builder and the FAISS service share a volume as intended. |
| **Size** | 2 vCPU and 2.5 GB per agent, on **10 GB disks**. Every resource request in this overlay was picked against that, and it is the constraint most likely to bite. |

## First run

**1. The homelab side must be applied first.** These manifests assume four PostgreSQL
databases, a ClickHouse database called `explained`, and an Elasticsearch role that covers the
`articles` index. All three are inventory changes in clever-homelab; if you have not run
`make configure` there since they landed, do that before anything here.

**2. Secrets.**

```bash
make secrets-pull                       # postgres, clickhouse, elasticsearch — off the guests
cd overlays/homelab/secrets
cp jwt.env.example jwt.env              # openssl rand -base64 48
cp redis.env.example redis.env          # openssl rand -hex 24
cp grafana.env.example grafana.env
```

`jwt.env` and `redis.env` are not fetched because nothing in the homelab generates them —
they belong to this application, not to the infrastructure.

**3. Images.** They come from Forgejo's registry as `git.homelab.lan/ci/explained-*`. Nothing
needs an `imagePullSecrets`: the homelab attaches `forgejo-registry` to the namespace's
`default` ServiceAccount. Push them with the `ci` token, or let a workflow do it — see "From a
push to a running pod" in the clever-homelab README.

**4. Apply.**

```bash
KUBECONFIG=../clever-homelab/ansible/inventory/.kubeconfig-deploy \
  make apply OVERLAY=homelab
```

That kubeconfig points at the API server's guest address, which is reachable from the CI
runner but **not** from a workstation. From a laptop, use `.kubeconfig` (full admin, through
the jump host) or run the apply from the runner.

**5. Names.** Nothing resolves `explained.homelab.lan` on its own. Add it and
`grafana.explained.homelab.lan` to `/etc/hosts` on the workstation, pointing at the
hypervisor — same as `git.homelab.lan`.

## Ports

| | | |
|---|---|---|
| `explained.homelab.lan` | NodePort 30080 | gateway → the five public services |
| `grafana.explained.homelab.lan` | NodePort 30300 | Grafana |
| Prometheus | — | not published; `kubectl port-forward svc/prometheus 9090:9090` |

Both NodePorts are already in `caddy_k3s_apps` in the homelab inventory.

## What to watch

The recommendation loop degrades quietly by design — the feed never answers 5xx — so pod
status is the wrong place to look for most failures here.

- **`ml-embeddings` being OOMKilled.** The likeliest ongoing problem: it loads SBERT and
  encodes in batches, and it is the largest thing that ever runs in this namespace. The
  symptom is exit 137 in the job log, not a Python traceback. Real fixes are more RAM on the
  agents or moving that one job to a VM; shrinking the batch only postpones it.
- **Agent disk.** 10 GB each, holding the image cache and every PVC that lands there.
  `k3s_prune_schedule` in the homelab keeps images in check; the PVC sizes here total ~7 GB if
  they all land on one node. This is the ceiling that arrives first.
- **ES indexer lag.** If the Elasticsearch role still has `elasticsearch_index_pattern: app-*`,
  every index call is a 403 and the indexer stops committing offsets — no data is lost, but
  search stops updating. Check the `article-service-indexer` consumer group before blaming
  the search code.
- **`feed_impressions` staying empty.** The recommendation service swallows ClickHouse
  failures. If `ClickHouse:Username`/`Password` are not reaching it, the table just never
  fills.

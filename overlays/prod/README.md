# overlays/prod

This overlay does not build out of the box, and that is deliberate:

```
$ kustomize build overlays/prod
Error: ... secrets/postgres.env: no such file or directory
```

A build that fails with "file not found" is a better outcome than one that succeeds with
`POSTGRES_PASSWORD=pass`.

## Before the first apply

**1. Secrets.** Copy each `.env.example` and fill it in. The real files are gitignored.

```bash
cd overlays/prod/secrets
for f in *.env.example; do cp "$f" "${f%.example}"; done
$EDITOR *.env
```

Read the comments in each one — three of them describe a rotation that is not just "change
this value":

- `elasticsearch.env` — the password is written to the ES security index on first boot.
  Changing this file later does not change the password, it just stops the article service
  authenticating.
- `jwt.env` — all five services read this Secret. A partial rollout means new identity pods
  mint tokens the old validating pods reject.
- `redis.env` — goes into a `redis://` URL for the Python services, so it needs percent-encoding
  if it contains `@ : / ? # %`. Stick to `[A-Za-z0-9_-]`.

Committing these instead is not the intended path. SOPS or External Secrets Operator is the
upgrade; both slot in by replacing the `secretGenerator` block with an `ExternalSecret` or a
`sops`-decrypting KRM function, and nothing else in this repo changes.

**2. The ten `REPLACE-ME` values** — one StorageClass name and nine image tags:

```bash
grep -rn REPLACE-ME overlays/prod/kustomization.yaml
```

The nine `registry.example.com/...` names next to them need changing too. In CI that is
`kustomize edit set image explained/article-service=your.registry/article-service@sha256:...`
rather than an edit by hand.

**3. Hostnames.** `api.explained.example` and `grafana.explained.example` appear in the ingress
patches, the Grafana root URL and `JWT_ISSUER`/`JWT_AUDIENCE`. The JWT pair is the one to be
careful with: it is compared as a string by every validating service, so changing it
invalidates every token already issued. Pick it before the first deploy, not after.

**4. Check the two assumptions this overlay makes about your cluster.**

- It removes the privileged `sysctl vm.max_map_count` init container from Elasticsearch,
  assuming your nodes already set it. Most managed node images do. If yours does not, fix it
  on the node — a privileged init container is the first thing a `restricted` Pod Security
  policy rejects.
- It sets a `storageClassName` on `faiss-index` and `mlflow-store` and assumes that class can
  actually provide ReadWriteMany. If it cannot, do not paper over it — see "two
  ReadWriteMany volumes" in the root README for what to replace instead.

## What differs from dev

| | dev | prod |
|---|---|---|
| replicas | 1 everywhere | 2–3, HPAs active |
| PodDisruptionBudgets | removed | active |
| article-service | 1 | HPA 2→3, not pinned — the count is a consumer-group size |
| ES heap | 512m | 2g, 6Gi limit |
| shared volumes | RWO, same-node | RWX StorageClass |
| ingress | `*.explained.local`, no TLS | real hosts, cert-manager, forced SSL redirect |
| secrets | committed | supplied, gitignored |
| images | `:dev`, local | registry + pinned tag |

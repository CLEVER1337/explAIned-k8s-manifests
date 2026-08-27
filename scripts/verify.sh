#!/usr/bin/env bash
# End-to-end verification of a deployed explAIned stack.
#
# Not a probe sweep. Every probe in this repository hits /metrics, which proves Kestrel is
# listening and nothing else — a pod whose database is gone stays Ready. This drives the
# system the way a user does and asserts on what comes back.
#
# The interesting assertion is step 4. `GET /articles/search` reads Elasticsearch, and
# nothing writes to Elasticsearch synchronously: an article reaches it only by way of an
# outbox row, the publisher polling that row, Kafka, and the indexer consuming it. So a
# search that finds an article created seconds earlier has exercised PostgreSQL, the outbox
# transaction, the publisher, both Kafka topics' transport, the indexer and Elasticsearch —
# in one assertion, from outside, with no cluster access.
#
#   ./scripts/verify.sh                      against https://explained.homelab.lan
#   BASE=https://other ./scripts/verify.sh   somewhere else
#   SKIP_CLUSTER=1 ./scripts/verify.sh       HTTP only, no kubectl
#
# Creates a user, an article and a comment, then archives what it can. Identity exposes no
# delete, so each run leaves one account behind — see the note it prints at the end.
set -uo pipefail

BASE="${BASE:-https://explained.homelab.lan}"
CURL=(curl -sk --max-time 15)
STAMP="$(date -u +%Y%m%d%H%M%S)-$RANDOM"
MARKER="verifymarker${STAMP//-/}"
EMAIL="verify-${STAMP}@homelab.lan"
PASSWORD="Verify-${STAMP}!aA1"

pass=0; fail=0; skip=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
no()   { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
warn() { printf '  \033[33m•\033[0m %s\n' "$*"; skip=$((skip+1)); }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# HTTP helper. Sets HTTP_CODE and HTTP_BODY rather than returning them, so a body containing
# newlines survives and callers never have to parse a combined blob.
req() {
  local method=$1 path=$2 token=${3:-} body=${4:-}
  local args=("${CURL[@]}" -X "$method" -w '\n%{http_code}')
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
  local out; out=$("${args[@]}" "$BASE$path" 2>/dev/null)
  HTTP_CODE="${out##*$'\n'}"
  HTTP_BODY="${out%$'\n'*}"
  [ "$HTTP_CODE" = "$HTTP_BODY" ] && HTTP_BODY=""
  return 0
}

# One-field JSON reader. python3 rather than jq: it is the one interpreter every machine
# that runs this already has, and a missing jq should not be the reason a check is skipped.
jget() { python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
for k in sys.argv[1].split('.'):
    if isinstance(d,list): d=d[int(k)] if d else None
    elif isinstance(d,dict): d=d.get(k)
    else: d=None
    if d is None: sys.exit(1)
print(d if not isinstance(d,(dict,list)) else json.dumps(d))
" "$1" 2>/dev/null; }

printf '\033[1mexplAIned end-to-end verification\033[0m\n%s\n' "$BASE"

# ── 1. Reachability ──────────────────────────────────────────────────────────────────────
step "1. Reachability"
req GET /healthz
if [ "$HTTP_CODE" = 200 ]; then ok "gateway answers /healthz"
else
  no "gateway unreachable (code $HTTP_CODE) — nothing below can pass"
  [ "$HTTP_CODE" = 000 ] && printf '    name did not resolve; add %s to /etc/hosts\n' "${BASE#https://}"
  exit 1
fi

# ── 2. Identity ──────────────────────────────────────────────────────────────────────────
step "2. Identity — register and log in"
req POST /user "" "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}"
case "$HTTP_CODE" in
  200|201|204) ok "registered $EMAIL" ;;
  *) no "register failed (code $HTTP_CODE): ${HTTP_BODY:0:160}"; exit 1 ;;
esac

req POST /session "" "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"rememberMe\":false}"
TOKEN=$(printf '%s' "$HTTP_BODY" | jget accessToken)
if [ -n "${TOKEN:-}" ]; then ok "logged in, access token issued"
else no "login failed (code $HTTP_CODE): ${HTTP_BODY:0:160}"; exit 1; fi

# The user id every downstream service reads out of the token. Decoded here rather than
# guessed, because `sub` is what the services key on — MapInboundClaims is off everywhere.
USER_ID=$(printf '%s' "$TOKEN" | python3 -c "
import sys,base64,json
p=sys.stdin.read().split('.')[1]
print(json.loads(base64.urlsafe_b64decode(p+'='*(-len(p)%4)))['sub'])
" 2>/dev/null)
if [ -n "${USER_ID:-}" ]; then ok "token carries sub=${USER_ID:0:12}…"
else no "token has no sub claim — downstream authorization cannot work"; fi

# ── 3. Profile ───────────────────────────────────────────────────────────────────────────
step "3. Profile — lazy creation on first read"
req GET /profiles/me "$TOKEN"
[ "$HTTP_CODE" = 200 ] && ok "GET /profiles/me created the row" \
                       || no "GET /profiles/me → $HTTP_CODE (expected 200)"

req PUT /profiles/me "$TOKEN" "{\"displayName\":\"verify $STAMP\",\"bio\":null,\"location\":null,\"websiteUrl\":null}"
case "$HTTP_CODE" in 200|204) ok "PUT /profiles/me accepted" ;; *) no "PUT /profiles/me → $HTTP_CODE" ;; esac

req GET "/profiles/$USER_ID"
[ "$HTTP_CODE" = 200 ] && ok "profile readable publicly" \
                       || no "GET /profiles/{id} → $HTTP_CODE (expected 200)"

# ── 4. Article write path, and the async pipeline behind it ──────────────────────────────
step "4. Article — write path, then outbox → Kafka → Elasticsearch"
req POST /articles "$TOKEN" \
  "{\"title\":\"verification $MARKER\",\"content\":\"$MARKER body text for search\",\"description\":\"e2e\",\"tags\":\"$MARKER\",\"accessLevel\":\"Public\"}"
# The body is {"id":"…"}, not a bare string. Stripping quotes off the whole thing yields
# `{id:…}`, which is a perfectly plausible-looking id that 404s on every subsequent call —
# so parse it, and only fall back to the bare form if there is no `id` field at all.
ARTICLE_ID=$(printf '%s' "$HTTP_BODY" | jget id)
[ -z "${ARTICLE_ID:-}" ] && ARTICLE_ID=$(printf '%s' "$HTTP_BODY" | tr -d '"{} ')
if [ "$HTTP_CODE" = 200 ] || [ "$HTTP_CODE" = 201 ]; then
  ok "created article ${ARTICLE_ID:0:12}… (status Draft — POST always creates a draft)"
else
  no "POST /articles → $HTTP_CODE: ${HTTP_BODY:0:160}"; ARTICLE_ID=""
fi

if [ -n "$ARTICLE_ID" ]; then
  req GET "/articles/$ARTICLE_ID"
  [ "$HTTP_CODE" = 200 ] && ok "readable by id (PostgreSQL, then Redis on the next hit)" \
                         || no "GET /articles/{id} → $HTTP_CODE"

  # Publishing is a separate call by design: /articles/search and /articles/recent both
  # filter on Published, so a draft is invisible to every read path that matters.
  req PUT "/articles/$ARTICLE_ID" "$TOKEN" \
    "{\"title\":\"verification $MARKER\",\"content\":\"$MARKER body text for search\",\"description\":\"e2e\",\"tags\":\"$MARKER\",\"accessLevel\":\"Public\",\"status\":\"Published\"}"
  case "$HTTP_CODE" in 200|204) ok "published" ;; *) no "PUT /articles/{id} → $HTTP_CODE: ${HTTP_BODY:0:120}" ;; esac

  # The one assertion that covers the whole asynchronous half of the architecture.
  printf '  … waiting for the indexer (outbox poll + Kafka + ES refresh)'
  found=""
  for i in $(seq 1 20); do
    req GET "/articles/search?query=$MARKER"
    if [ "$HTTP_CODE" = 200 ] && printf '%s' "$HTTP_BODY" | grep -q "$MARKER"; then found=$i; break; fi
    printf '.'; sleep 3
  done
  printf '\n'
  if [ -n "$found" ]; then
    ok "search found it after ~$((found*3))s — outbox, publisher, Kafka, indexer and Elasticsearch all work"
  else
    no "search never returned it in 60s — the async pipeline is broken somewhere"
    printf '    check: outbox rows with PublishedAt IS NULL, then consumer group article-service-indexer\n'
  fi

  req GET "/articles/recent?limit=50"
  printf '%s' "$HTTP_BODY" | grep -q "$MARKER" \
    && ok "appears in /articles/recent" \
    || no "missing from /articles/recent (PostgreSQL read path or the 30s cache)"
fi

# ── 5. Comments ──────────────────────────────────────────────────────────────────────────
step "5. Comment — write, read, and the ArticleCommented event"
COMMENT_ID=""
if [ -n "$ARTICLE_ID" ]; then
  req POST /comments "$TOKEN" "{\"articleId\":\"$ARTICLE_ID\",\"content\":\"verify $MARKER\"}"
  COMMENT_ID=$(printf '%s' "$HTTP_BODY" | jget id)
  [ -z "${COMMENT_ID:-}" ] && COMMENT_ID=$(printf '%s' "$HTTP_BODY" | tr -d '"{} ')
  case "$HTTP_CODE" in
    200|201) ok "comment created (emits ArticleCommented to user.events)" ;;
    *) no "POST /comments → $HTTP_CODE: ${HTTP_BODY:0:160}" ;;
  esac

  req GET "/comments/article/$ARTICLE_ID"
  printf '%s' "$HTTP_BODY" | grep -q "$MARKER" \
    && ok "comment readable on the article" \
    || no "comment missing from /comments/article/{id}"
fi

# ── 6. Behavioural events ────────────────────────────────────────────────────────────────
step "6. Behavioural events — fire-and-forget onto user.events"
if [ -n "$ARTICLE_ID" ]; then
  for pair in "click:202" "read:202" "like:204" "dislike:204" "share:204"; do
    ep="${pair%%:*}"; want="${pair##*:}"
    req POST "/articles/$ARTICLE_ID/$ep" "$TOKEN" '{}'
    [ "$HTTP_CODE" = "$want" ] && ok "POST /articles/{id}/$ep → $HTTP_CODE" \
                               || no "POST /articles/{id}/$ep → $HTTP_CODE (expected $want)"
  done
  printf '    note: these are emit-only and swallow Kafka failures — a 202 does not prove delivery\n'
fi

# ── 7. Feed ──────────────────────────────────────────────────────────────────────────────
step "7. Feed — the degradation ladder"
req GET /api/feed "$TOKEN"
if [ "$HTTP_CODE" = 200 ]; then
  rung=$(printf '%s' "$HTTP_BODY" | jget rung || echo "")
  src=$(printf '%s' "$HTTP_BODY" | jget source || echo "")
  ok "feed answered 200${rung:+ (rung: $rung)}${src:+, source: $src}"
  printf '    a low rung is data, not breakage: personalization needs embeddings and events first\n'
else
  no "GET /api/feed → $HTTP_CODE — this endpoint is documented never to answer 5xx"
fi

req GET /api/feed
[ "$HTTP_CODE" = 401 ] && ok "feed rejects an anonymous caller (401)" \
                       || warn "feed without a token → $HTTP_CODE (expected 401)"

# ── 8. Cross-service proxies ─────────────────────────────────────────────────────────────
step "8. Profile proxies — the never-5xx contract"
req GET "/profiles/$USER_ID/articles"
deg=$(printf '%s' "$HTTP_BODY" | jget degraded || echo "false")
if [ "$HTTP_CODE" = 200 ] && [ "$deg" != "True" ] && [ "$deg" != "true" ]; then
  ok "/profiles/{id}/articles proxied to article-service, not degraded"
elif [ "$HTTP_CODE" = 200 ]; then
  no "/profiles/{id}/articles answered but degraded=true — article-service is unreachable from profile-service"
else
  no "/profiles/{id}/articles → $HTTP_CODE (contract says it never 5xxes)"
fi

req GET "/profiles/$USER_ID/stats"
arts=$(printf '%s' "$HTTP_BODY" | jget articles || echo "null")
if [ "$HTTP_CODE" = 200 ] && [ "$arts" != "null" ]; then
  ok "/profiles/{id}/stats reports articles=$arts (null would mean an upstream is down)"
else
  no "/profiles/{id}/stats → $HTTP_CODE, articles=$arts"
fi

# ── 9. Cluster introspection (optional) ──────────────────────────────────────────────────
step "9. Cluster internals"
if [ "${SKIP_CLUSTER:-0}" = 1 ]; then
  warn "skipped (SKIP_CLUSTER=1)"
elif ! command -v kubectl >/dev/null 2>&1 || ! kubectl -n apps get deploy >/dev/null 2>&1; then
  warn "no working kubectl — HTTP checks above already cover the user-visible contract"
  printf '    for these: ssh -J supervisor@192.168.0.19 -L 6443:127.0.0.1:6443 -N supervisor@10.42.0.30\n'
else
  notready=$(kubectl -n apps get deploy -o json | python3 -c "
import sys,json
d=json.load(sys.stdin)['items']
print(' '.join(i['metadata']['name'] for i in d
      if i['status'].get('readyReplicas',0) != i['spec']['replicas']))")
  [ -z "$notready" ] && ok "every Deployment has its full replica count" \
                     || no "not ready: $notready"

  placeholder=$(kubectl -n apps get deploy,cronjob -o json | python3 -c "
import sys,json
out=set()
for i in json.load(sys.stdin)['items']:
    s=json.dumps(i['spec'])
    if ':main\"' in s or ':main '  in s: out.add(i['metadata']['name'])
print(' '.join(sorted(out)))")
  [ -z "$placeholder" ] && ok "no workload left on the :main placeholder tag" \
                        || warn "never released: $placeholder"

  unbounded=$(kubectl -n apps get cronjob -o json | python3 -c "
import sys,json
print(' '.join(i['metadata']['name'] for i in json.load(sys.stdin)['items']
      if not i['spec']['jobTemplate']['spec'].get('activeDeadlineSeconds')))")
  [ -z "$unbounded" ] && ok "every CronJob is bounded by activeDeadlineSeconds" \
                      || no "unbounded (a stuck Job wedges Forbid forever): $unbounded"

  stuck=$(kubectl -n apps get pods -o json | python3 -c "
import sys,json
bad=[]
for p in json.load(sys.stdin)['items']:
    for c in p['status'].get('containerStatuses',[]):
        r=(c.get('state',{}).get('waiting') or {}).get('reason','')
        if r in ('ImagePullBackOff','ErrImagePull','CrashLoopBackOff','CreateContainerConfigError'):
            bad.append(p['metadata']['name']+':'+r)
print(' '.join(bad))")
  [ -z "$stuck" ] && ok "no pod stuck pulling or crash-looping" || no "stuck: $stuck"
fi

# ── 10. Cleanup ──────────────────────────────────────────────────────────────────────────
step "10. Cleanup"
[ -n "$COMMENT_ID" ] && { req DELETE "/comments/$COMMENT_ID" "$TOKEN"
  case "$HTTP_CODE" in 200|204) ok "comment soft-deleted" ;; *) warn "comment delete → $HTTP_CODE" ;; esac; }
[ -n "$ARTICLE_ID" ] && { req DELETE "/articles/$ARTICLE_ID" "$TOKEN"
  case "$HTTP_CODE" in 200|204) ok "article archived" ;; *) warn "article archive → $HTTP_CODE" ;; esac; }
req DELETE /session "$TOKEN" >/dev/null 2>&1
warn "account $EMAIL stays — identity exposes no delete; prune the users database if these pile up"

# ── Verdict ──────────────────────────────────────────────────────────────────────────────
printf '\n\033[1m%d passed, %d failed, %d noted\033[0m\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1

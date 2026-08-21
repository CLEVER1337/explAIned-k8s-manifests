-- ClickHouse schema for the analytics side of explAIned.
--
-- Until now this DDL existed only on the running instance, which meant a rebuilt machine had
-- no way to recreate it and no record of what the consumer expects.
--
--   clickhouse-client --queries-file schema.sql
--
-- The HTTP interface rejects multi-statement bodies, so `curl --data-binary @schema.sql` does
-- not work. If clickhouse-client is unavailable, feed the statements one at a time:
--
--   awk 'BEGIN{RS=";"} /[^[:space:]]/ {print > ("/tmp/ch-" NR ".sql")}' schema.sql
--   for f in /tmp/ch-*.sql; do curl -s -X POST http://localhost:8123/ --data-binary @"$f"; done
--
-- Note the database is lowercase `explained`. ClickHouse identifiers are case-sensitive, and
-- the deployed instance has always been lowercase; appsettings.json used to say `explAIned`,
-- which silently prevented every insert.

CREATE DATABASE IF NOT EXISTS explained;

-- Behavioural events from the `user.events` Kafka topic.
--
-- ReplacingMergeTree on `event_id`: delivery is at-most-once, but the consumer commits Kafka
-- offsets only after the ClickHouse insert acknowledges, so a crash between the two replays
-- rows. Duplicates collapse on merge — which is why every aggregate in explAIned-ml reads
-- FINAL rather than trusting the merge scheduler's timing.
CREATE TABLE IF NOT EXISTS explained.user_events
(
    `event_id`    UUID,
    `event_type`  LowCardinality(String),
    `user_id`     String,
    `article_id`  String,
    `occurred_at` DateTime64(3, 'UTC'),
    `source`      LowCardinality(String),
    `metadata`    Map(String, String)
)
ENGINE = ReplacingMergeTree
ORDER BY (user_id, occurred_at, event_id);

-- What the feed actually served, written by ClickHouseImpressionLog in the :5056 service.
-- Columns mirror the `FeedImpression` record one for one.
--
-- `level` is the load-bearing column, not decoration: a click on a page served at `trending`
-- or below says nothing about a ranker that was not involved in choosing it. train_lightgbm.py
-- filters to personalized/partial/unranked so the model does not learn to reproduce the
-- fallback it exists to avoid.
CREATE TABLE IF NOT EXISTS explained.feed_impressions
(
    `feed_id`     String,
    `user_id`     String,
    `article_ids` Array(String),
    `level`       LowCardinality(String),
    `served_at`   DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree
ORDER BY (user_id, served_at, feed_id);

-- Rolling popularity, for dashboards and for anything that wants article stats without
-- rescanning the raw events. update_trending.py deliberately does *not* read this: it needs a
-- time-decayed score over an arbitrary window, which an hourly bucket cannot express.
CREATE MATERIALIZED VIEW IF NOT EXISTS explained.article_popularity_24h
ENGINE = SummingMergeTree
ORDER BY (article_id, hour)
AS
SELECT
    article_id,
    toStartOfHour(occurred_at)               AS hour,
    countIf(event_type = 'ArticleClicked')   AS clicks,
    countIf(event_type = 'ArticleRead')      AS reads,
    countIf(event_type = 'ArticleLiked')     AS likes,
    countIf(event_type = 'ArticleDisliked')  AS dislikes,
    countIf(event_type = 'ArticleShared')    AS shares,
    countIf(event_type = 'ArticleCommented') AS comments
FROM explained.user_events
WHERE article_id != ''
GROUP BY article_id, hour;

-- Per-user hourly activity. `uniqState` rather than `uniqExact` because a materialized view
-- sees only the inserted block: an aggregate state merges across blocks, a plain count does
-- not. Read it with `uniqMerge(distinct_articles_state)`.
CREATE MATERIALIZED VIEW IF NOT EXISTS explained.user_activity_hourly
ENGINE = AggregatingMergeTree
ORDER BY (user_id, hour)
AS
SELECT
    user_id,
    toStartOfHour(occurred_at) AS hour,
    countState()               AS events_state,
    uniqState(article_id)      AS distinct_articles_state
FROM explained.user_events
WHERE user_id != ''
GROUP BY user_id, hour;

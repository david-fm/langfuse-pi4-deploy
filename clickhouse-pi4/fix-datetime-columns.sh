#!/bin/sh
# Migrate langfuse DateTime64(3) → DateTime64(6) for all timestamp columns.
#
# Problem: langfuse worker writes microseconds (us) into DateTime64(3) (ms)
# columns. On ARMv8.0 ClickHouse, values > max DateTime64(3) are clamped
# to 9999-12-31 23:59:59.000, making traces invisible in the UI.
#
# Solution: recreate tables with DateTime64(6). Data is copied as-is.
#
# Key columns (timestamp, start_time) CANNOT be ALTERed in ClickHouse.
# We must recreate the entire table.
#
# This script:
# 1. Renames old tables to _old
# 2. Creates new tables with correct schema (DateTime64(6))
# 3. Copies data from old tables
# 4. Drops old tables
#
# Idempotent: skips if timestamp column already DateTime64(6).
# Uses POST for DDL (GET doesn't work for DDL in ClickHouse HTTP).

set -e

CLICKHOUSE_URL="${CLICKHOUSE_URL:-http://langfuse-clickhouse:8123}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-langfuse}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-langfuse_pw}"

ch_get() {
  wget -q -O- \
    --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
    --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" \
    "${CLICKHOUSE_URL}/?query=$(echo "$1" | sed 's/ /+/g')"
}

ch_post() {
  wget -q -O /dev/null \
    --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
    --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" \
    --post-data="$1" \
    "${CLICKHOUSE_URL}/"
}

echo "⏳ Waiting for ClickHouse..."
until wget -q -O /dev/null "${CLICKHOUSE_URL}/?query=SELECT%201" \
  --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
  --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null; do
  sleep 2
done
echo "✅ ClickHouse ready."

# Wait for langfuse tables
echo "⏳ Waiting for langfuse.traces..."
for i in $(seq 1 30); do
  RESULT=$(ch_get "SELECT count(*) FROM system.tables WHERE database='langfuse' AND name='traces'")
  if [ "$RESULT" = "1" ]; then break; fi
  sleep 2
done
echo "✅ langfuse.traces exists."

# Check if migration already done
CURRENT=$(ch_get "SELECT type FROM system.columns WHERE database='langfuse' AND table='traces' AND name='timestamp'")

if [ "$CURRENT" = "DateTime64(6)" ]; then
  echo "✅ Already migrated (timestamp is DateTime64(6)). Nothing to do."
  exit 0
fi

echo "🔧 Current timestamp type: ${CURRENT}"
echo "🔧 Starting table recreation..."

# ============================================================
# Step 1: Recreate traces table
# ============================================================
echo ""
echo "=== Step 1: traces table ==="

# Handle case where traces was already renamed to traces_old by manual intervention
TRACES_EXISTS=$(ch_get "SELECT count(*) FROM system.tables WHERE database='langfuse' AND name='traces'")
TRACES_OLD_EXISTS=$(ch_get "SELECT count(*) FROM system.tables WHERE database='langfuse' AND name='traces_old'")

if [ "$TRACES_EXISTS" = "0" ] && [ "$TRACES_OLD_EXISTS" = "1" ]; then
  echo "  ℹ️  traces missing, traces_old exists (manual rename). Using traces_old as source."
  ch_post "DROP TABLE IF EXISTS langfuse.traces_old_target"
  # Don't need to RENAME, just create new table and copy from traces_old
elif [ "$TRACES_EXISTS" = "1" ]; then
  ch_post "DROP TABLE IF EXISTS langfuse.traces_old"
  ch_post "RENAME TABLE langfuse.traces TO langfuse.traces_old"
  echo "  ✅ Renamed traces → traces_old"
else
  echo "  ⚠️  Neither traces nor traces_old exist. Creating fresh."
fi

ch_post "CREATE TABLE langfuse.traces (
    id String,
    timestamp DateTime64(6),
    name String,
    user_id Nullable(String),
    metadata Map(LowCardinality(String), String),
    release Nullable(String),
    version Nullable(String),
    project_id String,
    environment LowCardinality(String) DEFAULT 'default',
    public Bool,
    bookmarked Bool,
    tags Array(String),
    input Nullable(String) CODEC(ZSTD(3)),
    output Nullable(String) CODEC(ZSTD(3)),
    session_id Nullable(String),
    created_at DateTime64(6) DEFAULT now64(6),
    updated_at DateTime64(6) DEFAULT now64(6),
    event_ts DateTime64(6),
    is_deleted UInt8
) ENGINE = ReplicingMergeTree(updated_at)
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, project_id, id)
SETTINGS index_granularity = 8192"
echo "  ✅ Created new traces table (DateTime64(6))"

# Copy data from whichever source exists
if [ "$TRACES_OLD_EXISTS" = "1" ]; then
  ch_post "INSERT INTO langfuse.traces SELECT * FROM langfuse.traces_old"
  echo "  ✅ Copied data from traces_old"
  ch_post "DROP TABLE IF EXISTS langfuse.traces_old"
  echo "  ✅ Dropped traces_old"
elif [ "$TRACES_EXISTS" = "1" ]; then
  ch_post "INSERT INTO langfuse.traces SELECT * FROM langfuse.traces_old"
  echo "  ✅ Copied data from traces_old"
  ch_post "DROP TABLE IF EXISTS langfuse.traces_old"
  echo "  ✅ Dropped traces_old"
fi

# ============================================================
# Step 2: Recreate observations table
# ============================================================
echo ""
echo "=== Step 2: observations table ==="

OBS_EXISTS=$(ch_get "SELECT count(*) FROM system.tables WHERE database='langfuse' AND name='observations'")
OBS_OLD_EXISTS=$(ch_get "SELECT count(*) FROM system.tables WHERE database='langfuse' AND name='observations_old'")

if [ "$OBS_EXISTS" = "0" ] && [ "$OBS_OLD_EXISTS" = "1" ]; then
  echo "  ℹ️  observations missing, observations_old exists. Using as source."
elif [ "$OBS_EXISTS" = "1" ]; then
  ch_post "DROP TABLE IF EXISTS langfuse.observations_old"
  ch_post "RENAME TABLE langfuse.observations TO langfuse.observations_old"
  echo "  ✅ Renamed observations → observations_old"
else
  echo "  ⚠️  Neither observations nor observations_old exist. Creating fresh."
fi

ch_post "CREATE TABLE langfuse.observations (
    id String,
    trace_id String,
    project_id String,
    environment LowCardinality(String) DEFAULT 'default',
    type LowCardinality(String),
    parent_observation_id Nullable(String),
    start_time DateTime64(6),
    end_time Nullable(DateTime64(6)),
    name String,
    metadata Map(LowCardinality(String), String),
    level LowCardinality(String),
    status_message Nullable(String),
    version Nullable(String),
    input Nullable(String) CODEC(ZSTD(3)),
    output Nullable(String) CODEC(ZSTD(3)),
    provided_model_name Nullable(String),
    internal_model_id Nullable(String),
    model_parameters Nullable(String),
    provided_usage_details Map(LowCardinality(String), UInt64),
    usage_details Map(LowCardinality(String), UInt64),
    provided_cost_details Map(LowCardinality(String), Decimal(18, 12)),
    cost_details Map(LowCardinality(String), Decimal(18, 12)),
    total_cost Nullable(Decimal(18, 12)),
    completion_start_time Nullable(DateTime64(6)),
    prompt_id Nullable(String),
    created_at DateTime64(6) DEFAULT now64(6),
    updated_at DateTime64(6) DEFAULT now64(6),
    event_ts DateTime64(6),
    is_deleted UInt8
) ENGINE = ReplicingMergeTree(updated_at)
PARTITION BY toYYYYMM(start_time)
ORDER BY (project_id, trace_id, start_time, id)
SETTINGS index_granularity = 8192"
echo "  ✅ Created new observations table (DateTime64(6))"

if [ "$OBS_OLD_EXISTS" = "1" ] || [ "$OBS_EXISTS" = "1" ]; then
  SOURCE_TABLE="observations_old"
  if [ "$OBS_OLD_EXISTS" = "0" ]; then SOURCE_TABLE="observations_old"; fi
  ch_post "INSERT INTO langfuse.observations SELECT * FROM langfuse.${SOURCE_TABLE}"
  echo "  ✅ Copied data from ${SOURCE_TABLE}"
  ch_post "DROP TABLE IF EXISTS langfuse.observations_old"
  echo "  ✅ Dropped observations_old"
fi

# ============================================================
# Step 3: Recreate scores table
# ============================================================
echo ""
echo "=== Step 3: scores table ==="

SCORES_EXISTS=$(ch_get "SELECT count(*) FROM system.tables WHERE database='langfuse' AND name='scores'")
SCORES_OLD_EXISTS=$(ch_get "SELECT count(*) FROM system.tables WHERE database='langfuse' AND name='scores_old'")

if [ "$SCORES_EXISTS" = "0" ] && [ "$SCORES_OLD_EXISTS" = "1" ]; then
  echo "  ℹ️  scores missing, scores_old exists. Using as source."
elif [ "$SCORES_EXISTS" = "1" ]; then
  ch_post "DROP TABLE IF EXISTS langfuse.scores_old"
  ch_post "RENAME TABLE langfuse.scores TO langfuse.scores_old"
  echo "  ✅ Renamed scores → scores_old"
else
  echo "  ⚠️  Neither scores nor scores_old exist. Creating fresh."
fi

ch_post "CREATE TABLE langfuse.scores (
    id String,
    project_id String,
    timestamp DateTime64(6),
    name String,
    value Float64,
    source Nullable(String),
    comment Nullable(String),
    trace_id Nullable(String),
    observation_id Nullable(String),
    config_id Nullable(String),
    data_type LowCardinality(String),
    environment LowCardinality(String) DEFAULT 'default',
    session_id Nullable(String),
    dataset_run_id Nullable(String),
    created_at DateTime64(6) DEFAULT now64(6),
    updated_at DateTime64(6) DEFAULT now64(6),
    event_ts DateTime64(6),
    is_deleted UInt8
) ENGINE = ReplicingMergeTree(updated_at)
PARTITION BY toYYYYMM(timestamp)
ORDER BY (project_id, trace_id, name, id)
SETTINGS index_granularity = 8192"
echo "  ✅ Created new scores table (DateTime64(6))"

if [ "$SCORES_OLD_EXISTS" = "1" ] || [ "$SCORES_EXISTS" = "1" ]; then
  SOURCE_TABLE="scores_old"
  if [ "$SCORES_OLD_EXISTS" = "0" ]; then SOURCE_TABLE="scores_old"; fi
  ch_post "INSERT INTO langfuse.scores SELECT * FROM langfuse.${SOURCE_TABLE}"
  echo "  ✅ Copied data from ${SOURCE_TABLE}"
  ch_post "DROP TABLE IF EXISTS langfuse.scores_old"
  echo "  ✅ Dropped scores_old"
fi

# ============================================================
# Verify
# ============================================================
echo ""
echo "=== Verification ==="
for t in traces observations scores; do
  TYPE=$(ch_get "SELECT type FROM system.columns WHERE database='langfuse' AND table='${t}' AND name IN ('timestamp','start_time') LIMIT 1")
  COUNT=$(ch_get "SELECT count(*) FROM langfuse.${t}")
  echo "  ${t}: type=${TYPE} rows=${COUNT}"
done

echo ""
echo "✅ Migration complete. All DateTime64 columns now use precision 6 (microseconds)."

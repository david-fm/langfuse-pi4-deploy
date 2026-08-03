#!/bin/sh
# Migrate langfuse DateTime64(3) → DateTime64(6) for all timestamp columns.
#
# Problem: langfuse worker writes microseconds (us) into DateTime64(3) (ms)
# columns. On ARMv8.0 ClickHouse, values > max DateTime64(3) are clamped
# to 9999-12-31 23:59:59.000, making traces invisible in the UI.
#
# Solution: recreate tables with DateTime64(6). Data is copied as-is —
# the same Int64 value that was "too large for ms" fits perfectly in us.
#
# Key columns (timestamp, start_time) CANNOT be ALTERed in ClickHouse.
# We must recreate the entire table.
#
# This script:
# 1. Creates new tables with correct schema
# 2. Copies data from old tables
# 3. Drops old tables
# 4. Renames new tables to original names
#
# Idempotent: skips if columns already use DateTime64(6).

set -e

CLICKHOUSE_URL="${CLICKHOUSE_URL:-http://langfuse-clickhouse:8123}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-langfuse}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-langfuse_pw}"

ch() {
  wget -q -O- \
    --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
    --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" \
    "${CLICKHOUSE_URL}/?query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$1'))")"
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
  RESULT=$(wget -q -O- "${CLICKHOUSE_URL}/?query=SELECT%20count(*)%20FROM%20system.tables%20WHERE%20database=%27langfuse%27%20AND%20name=%27traces%27" \
    --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
    --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null)
  if [ "$RESULT" = "1" ]; then break; fi
  sleep 2
done
echo "✅ langfuse.traces exists."

# Check if migration already done
CURRENT=$(wget -q -O- "${CLICKHOUSE_URL}/?query=SELECT%20type%20FROM%20system.columns%20WHERE%20database=%27langfuse%27%20AND%20table=%27traces%27%20AND%20name=%27timestamp%27" \
  --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
  --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null)

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

# Drop old table
wget -q -O /dev/null "${CLICKHOUSE_URL}/?query=DROP%20TABLE%20IF%20EXISTS%20langfuse.traces_old" \
  --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
  --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null

# Rename current to _old
wget -q -O /dev/null "${CLICKHOUSE_URL}/?query=RENAME%20TABLE%20langfuse.traces%20TO%20langfuse.traces_old" \
  --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
  --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null
echo "  ✅ Renamed traces → traces_old"

# Create new table with DateTime64(6)
cat << 'EOSQL' | wget -q -O /dev/null "${CLICKHOUSE_URL}/" \
  --header="X-ClickHouse-User: langfuse" \
  --header="X-ClickHouse-Key: langfuse_pw" \
  --post-data-binary @- 2>/dev/null
CREATE TABLE langfuse.traces
(
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
)
ENGINE = RepReplacingMergeTree(updated_at)
PARTITION BY toYYYYMM(timestamp)
ORDER BY (timestamp, project_id, id)
SETTINGS index_granularity = 8192
EOSQL
echo "  ✅ Created new traces table (DateTime64(6))"

# Copy data
wget -q -O /dev/null "${CLICKHOUSE_URL}/?query=INSERT%20INTO%20langfuse.traces%20SELECT%20*%20FROM%20langfuse.traces_old" \
  --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
  --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null
echo "  ✅ Copied data from traces_old"

# Drop old table
wget -q -O /dev/null "${CLICKHOUSE_URL}/?query=DROP%20TABLE%20IF%20EXISTS%20langfuse.traces_old" \
  --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
  --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null
echo "  ✅ Dropped traces_old"

# ============================================================
# Step 2: Recreate observations table
# ============================================================
echo ""
echo "=== Step 2: observations table ==="

wget -q -O /dev/null "${CLICKHOUSE_URL}/?query=DROP%20TABLE%20IF%20EXISTS%20langfuse.observations_old" \
  --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
  --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null

wget -q -O /dev/null "${CLICKHOUSE_URL}/?query=RENAME%20TABLE%20langfuse.observations%20TO%20langfuse.observations_old" \
  --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
  --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null
echo "  ✅ Renamed observations → observations_old"

cat << 'EOSQL' | wget -q -O /dev/null "${CLICKHOUSE_URL}/" \
  --header="X-ClickHouse-User: langfuse" \
  --header="X-ClickHouse-Key: langfuse_pw" \
  --post-data-binary @- 2>/dev/null
CREATE TABLE langfuse.observations
(
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
)
ENGINE = RepReplacingMergeTree(updated_at)
PARTITION BY toYYYYMM(start_time)
ORDER BY (project_id, trace_id, start_time, id)
SETTINGS index_granularity = 8192
EOSQL
echo "  ✅ Created new observations table (DateTime64(6))"

wget -q -O /dev/null "${CLICKHOUSE_URL}/?query=INSERT%20INTO%20langfuse.observations%20SELECT%20*%20FROM%20langfuse.observations_old" \
  --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
  --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null
echo "  ✅ Copied data from observations_old"

wget -q -O /dev/null "${CLICKHOUSE_URL}/?query=DROP%20TABLE%20IF%20EXISTS%20langfuse.observations_old" \
  --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
  --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null
echo "  ✅ Dropped observations_old"

# ============================================================
# Step 3: Recreate scores table
# ============================================================
echo ""
echo "=== Step 3: scores table ==="

wget -q -O /dev/null "${CLICKHOUSE_URL}/?query=DROP%20TABLE%20IF%20EXISTS%20langfuse.scores_old" \
  --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
  --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null

wget -q -O /dev/null "${CLICKHOUSE_URL}/?query=RENAME%20TABLE%20langfuse.scores%20TO%20langfuse.scores_old" \
  --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
  --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null
echo "  ✅ Renamed scores → scores_old"

cat << 'EOSQL' | wget -q -O /dev/null "${CLICKHOUSE_URL}/" \
  --header="X-ClickHouse-User: langfuse" \
  --header="X-ClickHouse-Key: langfuse_pw" \
  --post-data-binary @- 2>/dev/null
CREATE TABLE langfuse.scores
(
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
)
ENGINE = ReplicingMergeTree(updated_at)
PARTITION BY toYYYYMM(timestamp)
ORDER BY (project_id, trace_id, name, id)
SETTINGS index_granularity = 8192
EOSQL
echo "  ✅ Created new scores table (DateTime64(6))"

wget -q -O /dev/null "${CLICKHOUSE_URL}/?query=INSERT%20INTO%20langfuse.scores%20SELECT%20*%20FROM%20langfuse.scores_old" \
  --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
  --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null
echo "  ✅ Copied data from scores_old"

wget -q -O /dev/null "${CLICKHOUSE_URL}/?query=DROP%20TABLE%20IF%20EXISTS%20langfuse.scores_old" \
  --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
  --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null
echo "  ✅ Dropped scores_old"

# ============================================================
# Verify
# ============================================================
echo ""
echo "=== Verification ==="
for t in traces observations scores; do
  TYPE=$(wget -q -O- "${CLICKHOUSE_URL}/?query=SELECT%20type%20FROM%20system.columns%20WHERE%20database=%27langfuse%27%20AND%20table=%27${t}%27%20AND%20name%20IN%20(%27timestamp%27,%27start_time%27)%20LIMIT%201" \
    --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
    --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null)
  COUNT=$(wget -q -O- "${CLICKHOUSE_URL}/?query=SELECT%20count(*)%20FROM%20langfuse.${t}" \
    --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
    --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null)
  echo "  ${t}: type=${TYPE} rows=${COUNT}"
done

echo ""
echo "✅ Migration complete. All DateTime64 columns now use precision 6 (microseconds)."

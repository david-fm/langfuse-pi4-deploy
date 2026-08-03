#!/bin/sh
# Fix DateTime64 precision mismatch for langfuse on ARMv8.0 ClickHouse.
#
# The langfuse worker writes timestamps in microseconds (via
# getMicrosecondTimestamp) but the langfuse v3 schema declares
# DateTime64(3) (milliseconds). On ARM ClickHouse, this mismatch
# causes ClickHouse to clamp values to 9999-12-31 23:59:59.000.
#
# This script widens the columns to DateTime64(6) (microseconds)
# so the worker's microsecond values display correctly.
#
# Safe to run multiple times (idempotent).

set -e

CLICKHOUSE_URL="${CLICKHOUSE_URL:-http://langfuse-clickhouse:8123}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-langfuse}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-langfuse_pw}"

echo "⏳ Waiting for ClickHouse to be ready..."
until wget -q -O /dev/null "${CLICKHOUSE_URL}/?query=SELECT%201" \
  --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
  --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null; do
  sleep 2
done
echo "✅ ClickHouse ready."

# Wait for langfuse tables to exist (created by langfuse migrations)
echo "⏳ Waiting for langfuse.traces table..."
for i in $(seq 1 30); do
  RESULT=$(wget -q -O- "${CLICKHOUSE_URL}/?query=SELECT%20count(*)%20FROM%20system.tables%20WHERE%20database='langfuse'%20AND%20name='traces'" \
    --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
    --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null)
  if [ "$RESULT" = "1" ]; then
    break
  fi
  sleep 2
done
echo "✅ langfuse.traces exists."

# Check if columns already use DateTime64(6)
CURRENT_TYPE=$(wget -q -O- "${CLICKHOUSE_URL}/?query=SELECT%20type%20FROM%20system.columns%20WHERE%20database='langfuse'%20AND%20table='traces'%20AND%20name='timestamp'" \
  --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
  --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null)

if [ "$CURRENT_TYPE" = "DateTime64(6)" ]; then
  echo "✅ Columns already DateTime64(6). Nothing to do."
  exit 0
fi

echo "🔧 Current type: ${CURRENT_TYPE}. Altering to DateTime64(6)..."

# Alter traces table
for col in timestamp created_at updated_at event_ts; do
  wget -q -O /dev/null "${CLICKHOUSE_URL}/?query=ALTER%20TABLE%20langfuse.traces%20MODIFY%20COLUMN%20${col}%20DateTime64(6)" \
    --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
    --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null && \
    echo "  ✅ traces.${col} → DateTime64(6)" || \
    echo "  ⚠️  traces.${col} failed (may not exist yet)"
done

# Alter observations table (if it exists)
for col in start_time end_time created_at updated_at completion_start_time; do
  wget -q -O /dev/null "${CLICKHOUSE_URL}/?query=ALTER%20TABLE%20langfuse.observations%20MODIFY%20COLUMN%20${col}%20DateTime64(6)" \
    --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
    --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null && \
    echo "  ✅ observations.${col} → DateTime64(6)" || \
    echo "  ⚠️  observations.${col} skipped (table may not exist)"
done

# Alter scores table (if it exists)
for col in timestamp created_at; do
  wget -q -O /dev/null "${CLICKHOUSE_URL}/?query=ALTER%20TABLE%20langfuse.scores%20MODIFY%20COLUMN%20${col}%20DateTime64(6)" \
    --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
    --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" 2>/dev/null && \
    echo "  ✅ scores.${col} → DateTime64(6)" || \
    echo "  ⚠️  scores.${col} skipped (table may not exist)"
done

echo ""
echo "✅ All DateTime64 columns widened to precision 6 (microseconds)."
echo "   Langfuse worker timestamps will now display correctly."

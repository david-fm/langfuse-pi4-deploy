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
# Strategy: dump current schema via SHOW CREATE TABLE, sed-substitute
# DateTime64(3)→DateTime64(6), then CREATE new + INSERT FROM old.
#
# This is idempotent: if DateTime64(6) is already in place, exits 0.
# Handles three cases: normal, manual-rename-to-_old, fresh.

set -e

CLICKHOUSE_URL="${CLICKHOUSE_URL:-http://langfuse-clickhouse:8123}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-langfuse}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-langfuse_pw}"

ch_get() {
  wget -q -O- \
    --header="X-ClickHouse-User: ${CLICKHOUSE_USER}" \
    --header="X-ClickHouse-Key: ${CLICKHOUSE_PASSWORD}" \
    "${CLICKHOUSE_URL}/?query=$(echo "$1" | sed 's/ /+/g; s/(/%28/g; s/)/%29/g')"
}

ch_post() {
  wget -q -O- \
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

# Wait for langfuse database and at least one of our target tables
echo "⏳ Waiting for langfuse tables..."
for i in $(seq 1 60); do
  RESULT=$(ch_get "SELECT count(*) FROM system.tables WHERE database='langfuse' AND name IN ('traces','observations','scores')")
  if [ "$RESULT" != "0" ]; then break; fi
  sleep 2
done
echo "✅ langfuse tables exist (count: $RESULT)."

# Migrate one table: name -> partition column
migrate_table() {
  local TABLE="$1"
  local PARTITION_COL="$2"

  echo ""
  echo "=== ${TABLE} ==="

  # Check current type
  local CURRENT_TYPE=$(ch_get "SELECT type FROM system.columns WHERE database='langfuse' AND table='${TABLE}' AND name='${PARTITION_COL}'")
  echo "  current ${PARTITION_COL} type: ${CURRENT_TYPE}"

  if [ "${CURRENT_TYPE}" = "DateTime64(6)" ]; then
    echo "  ✅ Already migrated."
    return 0
  fi

  # Check if table exists
  local TABLE_EXISTS=$(ch_get "SELECT count(*) FROM system.tables WHERE database='langfuse' AND name='${TABLE}'")
  local TABLE_OLD_EXISTS=$(ch_get "SELECT count(*) FROM system.tables WHERE database='langfuse' AND name='${TABLE}_old'")

  if [ "${TABLE_EXISTS}" = "0" ] && [ "${TABLE_OLD_EXISTS}" = "0" ]; then
    echo "  ⚠️  Neither ${TABLE} nor ${TABLE}_old exist. Will create fresh from SHOW CREATE."
    # Use SHOW CREATE on a known reference? We can't - we have no schema.
    # Skip - langfuse migrations will recreate these.
    return 0
  fi

  if [ "${TABLE_EXISTS}" = "0" ] && [ "${TABLE_OLD_EXISTS}" = "1" ]; then
    # Manual rename case: source is _old
    echo "  ℹ️  ${TABLE} missing, ${TABLE}_old exists (manual rename)."
  elif [ "${TABLE_EXISTS}" = "1" ] && [ "${TABLE_OLD_EXISTS}" = "0" ]; then
    # Normal case: rename to _old
    ch_post "DROP TABLE IF EXISTS langfuse.${TABLE}_old" >/dev/null
    ch_post "RENAME TABLE langfuse.${TABLE} TO langfuse.${TABLE}_old" >/dev/null
    echo "  ✅ Renamed ${TABLE} → ${TABLE}_old"
  else
    # Both exist: drop _old and rename current to _old
    ch_post "DROP TABLE IF EXISTS langfuse.${TABLE}_old" >/dev/null
    ch_post "RENAME TABLE langfuse.${TABLE} TO langfuse.${TABLE}_old" >/dev/null
    echo "  ✅ Renamed ${TABLE} → ${TABLE}_old (had orphan)"
  fi

  # Get schema from _old
  echo "  ⏳ Dumping schema for ${TABLE}_old..."
  local SCHEMA=$(ch_post "SHOW CREATE TABLE langfuse.${TABLE}_old FORMAT Raw")
  if [ -z "$SCHEMA" ]; then
    echo "  ❌ Failed to dump schema for ${TABLE}_old"
    return 1
  fi

  # Substitute DateTime64(3) → DateTime64(6)
  local NEW_SCHEMA=$(echo "$SCHEMA" | sed 's/DateTime64(3)/DateTime64(6)/g; s/DateTime64(6,6)/DateTime64(6)/g')

  # Replace table name
  NEW_SCHEMA=$(echo "$NEW_SCHEMA" | sed "s/${TABLE}_old/${TABLE}/g")

  echo "  ⏳ Creating new ${TABLE} with DateTime64(6)..."
  # Echo the CREATE statement (truncated) for visibility
  echo "    $(echo "$NEW_SCHEMA" | head -1)"

  # Execute CREATE - capture errors
  local CREATE_RESULT=$(ch_post "$NEW_SCHEMA")
  if echo "$CREATE_RESULT" | grep -qi "error\|exception"; then
    echo "  ❌ CREATE TABLE failed: $CREATE_RESULT"
    return 1
  fi
  echo "  ✅ Created new ${TABLE}"

  # Copy data
  echo "  ⏳ Copying data..."
  local INSERT_RESULT=$(ch_post "INSERT INTO langfuse.${TABLE} SELECT * FROM langfuse.${TABLE}_old")
  if echo "$INSERT_RESULT" | grep -qi "error\|exception"; then
    echo "  ❌ INSERT failed: $INSERT_RESULT"
    return 1
  fi
  echo "  ✅ Copied data"

  # Drop old
  ch_post "DROP TABLE langfuse.${TABLE}_old" >/dev/null
  echo "  ✅ Dropped ${TABLE}_old"
}

# Migrate each table
migrate_table "traces" "timestamp"
migrate_table "observations" "start_time"
migrate_table "scores" "timestamp"

# Verify
echo ""
echo "=== Verification ==="
for t_col in "traces:timestamp" "observations:start_time" "scores:timestamp"; do
  T="${t_col%%:*}"
  C="${t_col##*:}"
  TYPE=$(ch_get "SELECT type FROM system.columns WHERE database='langfuse' AND table='${T}' AND name='${C}'")
  COUNT=$(ch_get "SELECT count(*) FROM langfuse.${T}")
  echo "  ${T}.${C}: type=${TYPE} rows=${COUNT}"
done

echo ""
echo "✅ Migration complete."

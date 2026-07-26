#!/usr/bin/env bash
# Backup-before-migrate helper for the Leo Academy Supabase project.
# Snapshots the current schema, then applies a migration .sql via the
# Management API — so a bad migration can always be compared/rolled back.
#
# Usage:  scripts/migrate.sh path/to/change.sql
# Needs:  ~/.supabase/access-token (PAT) and, for the schema snapshot,
#         either SUPABASE_DB_URL env or a reachable pg_dump connection.
set -euo pipefail

PROJECT_REF="ugsklcipzyiogxynshnh"
TOKEN_FILE="$HOME/.supabase/access-token"
SQL_FILE="${1:-}"

if [ -z "$SQL_FILE" ] || [ ! -f "$SQL_FILE" ]; then
  echo "usage: scripts/migrate.sh <file.sql>"; exit 1
fi
if [ ! -f "$TOKEN_FILE" ]; then
  echo "missing $TOKEN_FILE (Supabase personal access token)"; exit 1
fi

STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="$(cd "$(dirname "$0")/.." && pwd)/.migrate-backups"
mkdir -p "$BACKUP_DIR"

# 1) schema snapshot before touching anything
if [ -n "${SUPABASE_DB_URL:-}" ] && command -v pg_dump >/dev/null 2>&1; then
  echo "→ snapshotting schema to $BACKUP_DIR/schema-$STAMP.sql"
  pg_dump "$SUPABASE_DB_URL" --schema-only --no-owner --no-privileges \
    -f "$BACKUP_DIR/schema-$STAMP.sql"
else
  echo "!! SUPABASE_DB_URL/pg_dump not available — skipping schema snapshot."
  echo "   Strongly recommended: export SUPABASE_DB_URL and re-run, or take a"
  echo "   PITR checkpoint in the dashboard before applying."
  read -r -p "   Continue without a local snapshot? [y/N] " ok
  [ "$ok" = "y" ] || { echo "aborted."; exit 1; }
fi

# 2) apply the migration (wrap in a transaction so failure rolls back clean)
echo "→ applying $SQL_FILE"
SQL_CONTENT="$(printf 'begin;\n%s\ncommit;' "$(cat "$SQL_FILE")")"
RESP="$(python3 - "$SQL_CONTENT" <<'PY'
import json, sys, subprocess
sql = sys.argv[1]
tok = open(f"{__import__('os').path.expanduser('~')}/.supabase/access-token").read().strip()
r = subprocess.run(["curl","-s","-X","POST",
  "https://api.supabase.com/v1/projects/ugsklcipzyiogxynshnh/database/query",
  "-H", f"Authorization: Bearer {tok}", "-H","Content-Type: application/json",
  "--data-binary", json.dumps({"query": sql})], capture_output=True, text=True)
print(r.stdout or r.stderr)
PY
)"
echo "   response: $RESP"

case "$RESP" in
  *error*|*ERROR*) echo "✗ migration failed — check the response above (rolled back)."; exit 1 ;;
  *) echo "✓ applied. Remember to append it to supabase/schema.sql with a -- migration N header." ;;
esac

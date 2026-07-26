#!/usr/bin/env bash
# Validate a migration against the REAL schema without persisting anything.
# Wraps the file in begin; … rollback; so Postgres type-checks every
# statement against live tables, then throws the whole thing away.
#
# Usage: scripts/dry-run.sh supabase/migration-raj.sql
set -euo pipefail

PROJECT_REF="${PROJECT_REF:-ugsklcipzyiogxynshnh}"
SQL_FILE="${1:-}"
[ -f "$SQL_FILE" ] || { echo "usage: scripts/dry-run.sh <file.sql>"; exit 1; }

python3 - "$SQL_FILE" "$PROJECT_REF" <<'PY'
import json, os, subprocess, sys
sql_file, ref = sys.argv[1], sys.argv[2]
body = open(sql_file).read()
sql = "begin;\n" + body + "\nrollback;"
tok = open(os.path.expanduser("~/.supabase/access-token")).read().strip()
r = subprocess.run(["curl", "-s", "-X", "POST",
    f"https://api.supabase.com/v1/projects/{ref}/database/query",
    "-H", f"Authorization: Bearer {tok}",
    "-H", "Content-Type: application/json",
    "--data-binary", json.dumps({"query": sql})],
    capture_output=True, text=True)
out = (r.stdout or r.stderr).strip()
try:
    parsed = json.loads(out)
except Exception:
    print(out); sys.exit(1)
if isinstance(parsed, dict) and parsed.get("message"):
    print("✗ FAILED (rolled back)\n")
    print(json.dumps(parsed, indent=2))
    sys.exit(1)
print("✓ migration is valid against the live schema (rolled back, nothing persisted)")
PY

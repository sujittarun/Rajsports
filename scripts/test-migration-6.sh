#!/usr/bin/env bash
# Validate attendance migration and behavior against live schema, then roll back.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import json, os, subprocess, sys
mig = open("supabase/migration-raj-6.sql").read()
test = open("supabase/test-migration-6.sql").read()
sql = "begin;\n" + mig + "\n" + test + "\nrollback;"
tok = open(os.path.expanduser("~/.supabase/access-token")).read().strip()
r = subprocess.run([
    "curl", "-s", "-X", "POST",
    "https://api.supabase.com/v1/projects/ugsklcipzyiogxynshnh/database/query",
    "-H", f"Authorization: Bearer {tok}",
    "-H", "Content-Type: application/json",
    "--data-binary", json.dumps({"query": sql})
], capture_output=True, text=True)
out = (r.stdout or r.stderr).strip()
try:
    parsed = json.loads(out)
except Exception:
    print(out)
    sys.exit(1)
if isinstance(parsed, dict) and parsed.get("message"):
    print("✗ ATTENDANCE TESTS FAILED (everything rolled back)\n")
    print(parsed.get("message"))
    sys.exit(1)
print("✓ attendance migration + tests passed (rolled back, nothing persisted)")
if isinstance(parsed, list) and parsed:
    for key, value in parsed[0].items():
        print(f"   {key:<14} {value}")
PY

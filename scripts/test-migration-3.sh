#!/usr/bin/env bash
# Run migration-raj-3.sql + test-migration-3.sql in ONE transaction against the
# live schema, then roll everything back. Proves behaviour without persisting.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import json, os, subprocess, sys, re
mig  = open("supabase/migration-raj-3.sql").read()
test = open("supabase/test-migration-3.sql").read()
sql  = "begin;\n" + mig + "\n" + test + "\nrollback;"
tok  = open(os.path.expanduser("~/.supabase/access-token")).read().strip()
r = subprocess.run(["curl", "-s", "-X", "POST",
    "https://api.supabase.com/v1/projects/ugsklcipzyiogxynshnh/database/query",
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
    print("✗ TESTS FAILED (everything rolled back)\n")
    print(parsed.get("message"))
    sys.exit(1)
print("✓ migration 3 + tests passed (rolled back, nothing persisted)")
if isinstance(parsed, list) and parsed:
    for k, v in parsed[0].items():
        print(f"   {k:<14} {v}")
PY

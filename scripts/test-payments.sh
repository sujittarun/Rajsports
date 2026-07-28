#!/usr/bin/env bash
# Payment-path QA against the live schema, inside a rolled-back transaction.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import json, os, subprocess, sys
sql = ("begin;\n" + open("supabase/migration-raj-8.sql").read()
       + "\n" + open("supabase/test-payments.sql").read() + "\nrollback;")
tok = open(os.path.expanduser("~/.supabase/access-token")).read().strip()
r = subprocess.run(["curl","-s","-X","POST",
    "https://api.supabase.com/v1/projects/ugsklcipzyiogxynshnh/database/query",
    "-H", f"Authorization: Bearer {tok}", "-H", "Content-Type: application/json",
    "--data-binary", json.dumps({"query": sql})], capture_output=True, text=True)
out = (r.stdout or r.stderr).strip()
try: parsed = json.loads(out)
except Exception: print(out); sys.exit(1)
if isinstance(parsed, dict) and parsed.get("message"):
    print("✗ FAILED (rolled back)\n"); print(parsed["message"]); sys.exit(1)
print("✓ payment tests passed (rolled back)")
PY

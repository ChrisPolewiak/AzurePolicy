import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(os.environ.get("ASSIGNMENT_TEST_SCRIPTS", Path(__file__).resolve().parents[1] / "scripts"))
SCRIPT = (SCRIPTS / "update-assignments.sh").read_text(encoding="utf-8")
BASH = r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt" else shutil.which("bash")


@unittest.skipUnless(BASH and Path(BASH).is_file(), "Bash is required")
class AssignmentSummaryTests(unittest.TestCase):
    def run_assignments(self, deploy, failures, identity="system"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "generated").mkdir()
            names = ["failone", "failtwo", "uamifail", "rbacfail", "ok"] if failures else ["ok"]
            assignments = [{
                "name": name, "displayName": name,
                "scope": {"type": "managementgroup", "id": "root"},
            } for name in names]
            (root / "generated" / "assignments.json").write_text(json.dumps(assignments), encoding="utf-8")
            helper = SCRIPT.split("record_error() {", 1)[1].split("get_identity_config_entry() {", 1)[0]
            loop = SCRIPT.split("# --- Step 2: Deploy each assignment individually ---", 1)[1]
            setup = f"""#!/usr/bin/env bash
set -euo pipefail
export PYTHONUTF8=1
python3() {{ {shlex.quote(sys.executable)} "$@"; }}
SCRIPT_DIR={shlex.quote(str(SCRIPTS))}
TMP_ERRORS=errors.jsonl
TMP_COMMAND_LOG=command.log
TMP_ASSIGNMENT=assignment.json
TMP_PARAMETERSET=parameters.json
: > "$TMP_ERRORS"
ASSIGNMENT_COUNT={len(names)}
TARGET_ASSIGNMENT=""
DEPLOY={str(deploy).lower()}
LOCATION=test
MANAGEMENT_GROUP=root
get_identity_config_entry() {{
  case "$1" in uamifail|rbacfail) echo '{{}}';; *) echo null;; esac
}}
ensure_user_assigned_identity_entry() {{
  if [[ "$2" == uamifail ]]; then echo 'Identity denied' >&2; return 1; fi
  if [[ "{identity}" == system ]]; then echo '{{}}'; else
    echo '{{"identity":{{"userAssignedIdentityResourceIds":["/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/test"]}}}}'
  fi
}}
inject_identity_into_assignment() {{ echo "$1"; }}
get_role_assignments_json() {{ echo '[{{}}]'; }}
iter_role_bindings() {{ printf 'Contributor\\t/scope\\n'; }}
resolve_assignment_principal_id() {{ echo 'SYSTEM PRINCIPAL LOOKUP' >&2; echo principal; }}
az() {{
  if [[ "$1" == identity ]]; then
    echo 'DIRECT UAMI LOOKUP' >&2
    if [[ "{identity}" == missing ]]; then echo 'Identity access denied' >&2; return 4; fi
    echo principal
    return 0
  fi
  if [[ "$1" == role ]]; then echo 'RBAC denied' >&2; return 3; fi
  if [[ "$*" == *assign-fail* ]]; then
    echo 'ERROR: PolicyParameterValueNotAllowed | false]' >&2
    echo 'second error line' >&2
    return 2
  fi
  echo 'Operation succeeded'
}}
"""
            (root / "run.sh").write_text(
                setup + "record_error() {" + helper + loop, encoding="utf-8",
            )
            env = dict(os.environ, TF_BUILD="True", AGENT_TEMPDIRECTORY=str(root), PYTHONUTF8="1")
            result = subprocess.run(
                [str(BASH), "run.sh"], cwd=root, env=env, capture_output=True, encoding="utf-8",
            )
            summaries = list(root.glob("azurepolicy-assignments-*.md"))
            self.assertEqual(len(summaries), 1, result.stdout + result.stderr)
            summary = summaries[0].read_text(encoding="utf-8")
            return result, summary

    def test_deployment_collects_all_failures_and_keeps_processing(self):
        result, summary = self.run_assignments(deploy=True, failures=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for name in ("failone", "failtwo", "uamifail", "rbacfail"):
            self.assertIn(f"| {name} |", summary)
        self.assertIn("Errors: **4**", summary)
        self.assertIn("Identity denied", summary)
        self.assertIn("RBAC denied", summary)
        self.assertIn("second error line", summary)
        self.assertIn("&#124;", summary)
        self.assertIn("##vso[task.uploadsummary]", result.stdout)
        self.assertEqual(result.stdout.count("##vso[task.logissue type=error;]"), 4)
        self.assertIn("%5D%0A", result.stdout)
        self.assertIn("ok: ok", result.stdout)
        self.assertIn("SYSTEM PRINCIPAL LOOKUP", result.stderr)
        self.assertNotIn("TIME ", result.stdout + result.stderr)

    def test_uami_principal_is_resolved_directly_without_assignment_polling(self):
        result, summary = self.run_assignments(deploy=True, failures=True, identity="uami")
        self.assertIn("DIRECT UAMI LOOKUP", result.stderr)
        self.assertNotIn("SYSTEM PRINCIPAL LOOKUP", result.stderr)
        self.assertIn("RBAC denied", summary)

    def test_uami_lookup_failure_is_reported_without_assignment_fallback(self):
        result, summary = self.run_assignments(deploy=True, failures=True, identity="missing")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("SYSTEM PRINCIPAL LOOKUP", result.stderr)
        self.assertIn("Identity access denied", summary)

    def test_what_if_errors_fail_and_publish_summary(self):
        result, summary = self.run_assignments(deploy=False, failures=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("| what-if |", summary)
        self.assertIn("Some what-if operations failed", result.stdout)

    def test_success_publishes_empty_error_summary(self):
        result, summary = self.run_assignments(deploy=True, failures=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Errors: **0**", summary)
        self.assertIn("No assignment errors.", summary)
        self.assertNotIn("##vso[task.logissue", result.stdout)


if __name__ == "__main__":
    unittest.main()

import contextlib
import csv
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch
from urllib.error import HTTPError, URLError
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import validate_rebuild as validator


class RebuildValidationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.table = self.root / "configuration" / "policy-assignments.tsv"
        self.table.parent.mkdir()
        self.url = "https://www.azadvertizer.net/azpolicyinitiativesadvertizer/Deny-PublicPaaSEndpoints.html"
        self.check_link = validator.check_link
        link_check = patch.object(validator, "check_link", return_value=("", ""))
        self.link_check = link_check.start()
        self.addCleanup(link_check.stop)

    def write_rows(self, rows, delimiter="\t"):
        with self.table.open("w", encoding="utf-8-sig", newline="") as stream:
            writer = csv.writer(stream, delimiter=delimiter)
            writer.writerow(["ID", "Deploy", "DefinitionType", "Type2", "AzAdvertizer Link"])
            writer.writerows(rows)

    def definition(self, name, directory="policySetDefinitions", origin="EnterpriseALZ"):
        source = self.root / "source" / origin / directory / f"{name}.json"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(json.dumps({"name": name}), encoding="utf-8")
        template = self.root / "bicep" / directory / f"{name}.json"
        template.parent.mkdir(parents=True, exist_ok=True)
        template.write_text(json.dumps({"resources": [{
            "type": f"Microsoft.Authorization/{directory}", "name": name,
        }]}), encoding="utf-8")
        return template

    def test_policy_initiative_mismatch_reports_line_and_missing_template(self):
        self.definition("Deny-PublicPaaSEndpoints")
        self.write_rows([["Deny-PublicPaaSEndpoints", "TRUE", "Policy", "Custom", ""]])
        _, findings, checked = validator.validate(self.root, {})
        self.assertEqual(checked, 1)
        self.assertTrue(any("set DefinitionType to initiative" in f.message for f in findings))
        self.assertTrue(any("Generated template missing" in f.message for f in findings))
        self.assertTrue(all(f.line == 2 for f in findings))

    def test_corrected_initiative_passes_and_duplicate_urls_are_checked_once(self):
        self.definition("Deny-PublicPaaSEndpoints")
        self.write_rows([["Deny-PublicPaaSEndpoints", "TRUE", "Initiative", "Custom", self.url]] * 2)
        with patch.object(validator, "check_link", return_value=("", "")) as check:
            _, findings, checked = validator.validate(self.root, {})
        self.assertEqual((findings, checked), ([], 2))
        check.assert_called_once_with(self.url)

    def test_missing_source_is_not_hidden_by_stale_template(self):
        self.definition("Missing")
        (self.root / "source" / "EnterpriseALZ" / "policySetDefinitions" / "Missing.json").unlink()
        self.write_rows([["Missing", "TRUE", "Initiative", "Custom", ""]])
        _, findings, _ = validator.validate(self.root, {})
        self.assertTrue(any("Source policySetDefinitions/Missing.json not found" in f.message for f in findings))

    def test_wrong_resource_type_in_template_fails(self):
        template = self.definition("Wrong")
        template.write_text('{"resources": []}', encoding="utf-8")
        self.write_rows([["Wrong", "TRUE", "Initiative", "Custom", ""]])
        _, findings, _ = validator.validate(self.root, {})
        self.assertTrue(any("Template does not contain" in f.message for f in findings))

    def test_own_policy_and_builtin_without_local_template_pass(self):
        self.definition("Own", "policyDefinitions", "own")
        self.write_rows([
            ["Own", "TRUE", "Policy", "Own", ""],
            ["builtin-id", "TRUE", "Policy", "Built-in", ""],
            ["Missing", "FALSE", "Policy", "Custom", self.url],
        ])
        with patch.object(validator, "check_link", return_value=("", "")) as check:
            _, findings, checked = validator.validate(self.root, {})
        self.assertEqual(checked, 2)
        self.assertEqual(findings, [])
        check.assert_called_once_with("https://www.azadvertizer.net/azpolicyadvertizer/builtin-id.html")

    def test_semicolon_csv_fallback(self):
        self.table = self.table.with_suffix(".csv")
        self.write_rows([["builtin-id", "TRUE", "Policy", "Built-in", ""]], delimiter=";")
        table, findings, checked = validator.validate(self.root, {})
        self.assertEqual((table, checked), (self.table, 1))
        self.assertEqual(findings, [])

    def test_tsv_link_is_ignored_in_favor_of_generated_url(self):
        self.definition("Deny-PublicPaaSEndpoints")
        url = self.url.replace("azpolicyinitiativesadvertizer", "azpolicyadvertizer")
        self.write_rows([["Deny-PublicPaaSEndpoints", "TRUE", "Initiative", "Custom", url]])
        with patch.object(validator, "check_link", return_value=("", "")) as check:
            _, findings, _ = validator.validate(self.root, {})
        self.assertEqual(findings, [])
        check.assert_called_once_with(self.url)

    def test_link_column_is_not_required_and_builtin_arm_ids_are_normalized(self):
        with self.table.open("w", encoding="utf-8", newline="") as stream:
            writer = csv.writer(stream, delimiter="\t")
            writer.writerow(["ID", "Deploy", "DefinitionType", "Type2"])
            writer.writerows([
                ["/providers/Microsoft.Authorization/policyDefinitions/policy-id", "TRUE", "Policy", "Built-in"],
                ["/providers/Microsoft.Authorization/policySetDefinitions/set-id", "TRUE", "Initiative", "Built-in"],
            ])
        _, findings, checked = validator.validate(self.root, {})
        self.assertEqual((findings, checked), ([], 2))
        self.assertEqual({call.args[0] for call in self.link_check.call_args_list}, {
            "https://www.azadvertizer.net/azpolicyadvertizer/policy-id.html",
            "https://www.azadvertizer.net/azpolicyinitiativesadvertizer/set-id.html",
        })

    def test_own_definition_never_checks_advertizer_even_with_link(self):
        self.definition("Own", "policyDefinitions", "own")
        self.write_rows([["Own", "TRUE", "Policy", "Own", self.url]])
        _, findings, _ = validator.validate(self.root, {})
        self.assertEqual(findings, [])
        self.link_check.assert_not_called()

    def test_link_errors_are_attached_to_table_row(self):
        self.write_rows([["builtin-id", "TRUE", "Policy", "Built-in",
                          "https://www.azadvertizer.net/azpolicyadvertizer/builtin-id.html"]])
        with patch.object(validator, "check_link", return_value=("error", "HTTP 404")):
            _, findings, _ = validator.validate(self.root, {})
        self.assertIn(validator.Finding("error", 2, "builtin-id", "HTTP 404"), findings)

    def test_required_parameters_without_defaults_are_errors(self):
        findings = validator.validate_parameters(2, "Policy", "policy", {}, {}, {
            "workspaceId": {"type": "String"},
            "effect": {"type": "String", "defaultValue": "Audit"},
            "optionalList": {"type": "Array", "defaultValue": []},
        })
        self.assertEqual(len(findings), 1)
        self.assertIn("Missing required parameter 'workspaceId'", findings[0].message)

    def test_parameter_target_merging_and_explicit_empty_allowed_value(self):
        findings = validator.validate_parameters(
            2, "Policy", "policy", {"Parameter Set": "Set"},
            {"Set": {"both": {"shared": {"value": "common"}},
                     "policy": {"number": {"value": 0}, "empty": {"value": ""}},
                     "initiative": {"unrelated": {"value": "ignored"}}}},
            {"shared": {}, "number": {}, "empty": {"allowedValues": [""]}},
        )
        self.assertEqual(findings, [])

    def test_missing_parameter_set_or_wrong_target_is_an_error(self):
        for sets in ({}, {"Set": {"initiative": {"value": {"value": "data"}}}}):
            with self.subTest(sets=sets):
                findings = validator.validate_parameters(
                    2, "Policy", "policy", {"Parameter Set": "Set"}, sets, {},
                )
                self.assertEqual(len(findings), 1)
                self.assertIn("missing or has no parameters for policy", findings[0].message)

    def test_builtin_without_schema_still_validates_parameter_set(self):
        for kind in ("policy", "initiative"):
            with self.subTest(kind=kind):
                self.assertEqual(
                    validator.validate_parameters(2, "Builtin", kind, {}, {}, None), [],
                )
                findings = validator.validate_parameters(
                    2, "Builtin", kind, {"Parameter Set": "Missing"}, {}, None,
                )
                self.assertEqual(len(findings), 1)
                self.assertEqual(findings[0].severity, "error")
                self.assertIn("Parameter Set 'Missing'", findings[0].message)

    def test_required_parameter_blank_or_null_is_an_error(self):
        for value in ("", None):
            findings = validator.validate_parameters(
                2, "Policy", "policy", {"Parameter Set": "Set"},
                {"Set": {"both": {"workspaceId": {"value": value}}}},
                {"workspaceId": {"type": "String"}},
            )
            self.assertEqual(len(findings), 1)
            self.assertIn("Missing required parameter", findings[0].message)

    def test_missing_parameter_headers_are_an_error(self):
        self.write_rows([["builtin-id", "TRUE", "Policy", "Built-in", ""]])
        (self.table.parent / "policy-parameters.tsv").write_text(
            "Set\tpolicy\tworkspaceId\tvalue\n", encoding="utf-8",
        )
        _, findings, _ = validator.validate(self.root, {})
        self.assertTrue(any("Missing parameter table headers" in f.message for f in findings))

    def test_required_parameters_are_checked_from_source_schema(self):
        self.definition("Policy", "policyDefinitions")
        source = self.root / "source" / "EnterpriseALZ" / "policyDefinitions" / "Policy.json"
        source.write_text(json.dumps({
            "name": "Policy", "properties": {"parameters": {"workspaceId": {"type": "String"}}},
        }), encoding="utf-8")
        self.write_rows([["Policy", "TRUE", "Policy", "Custom", ""]])
        _, findings, _ = validator.validate(self.root, {})
        self.assertTrue(any("Missing required parameter 'workspaceId'" in f.message for f in findings))

    def test_http_404_410_and_403_are_errors_without_retries(self):
        for status in (404, 410, 403):
            with self.subTest(status=status):
                with patch.object(validator, "build_opener") as build:
                    build.return_value.open.side_effect = HTTPError(self.url, status, "Missing", {}, None)
                    severity, message = self.check_link(self.url)
                    self.assertEqual(severity, "error")
                    self.assertIn(str(status), message)
                    self.assertEqual(build.return_value.open.call_count, 1)

    def test_transient_http_and_network_failures_warn_after_three_attempts(self):
        for failure in (HTTPError(self.url, 429, "Rate limit", {}, None),
                        HTTPError(self.url, 503, "Unavailable", {}, None),
                        TimeoutError("timeout"), URLError("DNS unavailable")):
            with self.subTest(failure=str(failure)):
                with patch.object(validator, "build_opener") as build, patch.object(validator.time, "sleep"):
                    build.return_value.open.side_effect = failure
                    severity, message = self.check_link(self.url)
                    self.assertEqual(severity, "warning")
                    self.assertIn("after 3 attempts", message)
                    self.assertEqual(build.return_value.open.call_count, 3)

    def test_retry_can_recover(self):
        response = MagicMock()
        response.__enter__.return_value.status = 200
        with patch.object(validator, "build_opener") as build, patch.object(validator.time, "sleep"):
            build.return_value.open.side_effect = [TimeoutError(), response]
            self.assertEqual(self.check_link(self.url), ("", ""))
            self.assertEqual(build.return_value.open.call_count, 2)

    def test_non_public_url_and_redirect_are_rejected(self):
        with patch.object(validator, "build_opener") as build:
            self.assertEqual(self.check_link("http://localhost/private")[0], "error")
            build.assert_not_called()
        with self.assertRaises(ValueError):
            validator.PublicRedirect().redirect_request(None, None, 302, "", {}, "http://localhost/private")

    def test_pipeline_summary_and_issues_survive_validation_failure(self):
        output = io.StringIO()
        with patch.dict(os.environ, {"TF_BUILD": "True", "AGENT_TEMPDIRECTORY": str(self.root)}):
            with contextlib.redirect_stdout(output):
                result = validator.report(self.table, [
                    validator.Finding("error", 2, "Bad", "missing]\n##vso[unexpected]"),
                    validator.Finding("warning", 3, "Slow", "HTTP 503"),
                ], 2)
        self.assertEqual(result, 1)
        self.assertIn("##vso[task.logissue type=error;", output.getvalue())
        self.assertIn("linenumber=2;", output.getvalue())
        self.assertIn("%5D%0A", output.getvalue())
        summary = next(self.root.glob("azurepolicy-validation-*.md"))
        self.assertIn(f"##vso[task.uploadsummary]{summary}", output.getvalue())
        self.assertIn("no new `policy-generated` artifact", summary.read_text(encoding="utf-8"))

    def test_warnings_do_not_fail_validation(self):
        with patch.dict(os.environ, {"TF_BUILD": "false"}), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(validator.report(self.table, [
                validator.Finding("warning", 2, "Slow", "HTTP 429"),
            ], 1), 0)

    def test_rebuild_stops_before_config_generation_on_validation_failure(self):
        script = Path(validator.__file__).with_name("rebuild-configuration.sh").read_text(encoding="utf-8")
        self.assertIn("set -euo pipefail", script)
        self.assertLess(script.index('python3 "$SCRIPT_DIR/validate_rebuild.py"'),
                        script.index('python3 "$SCRIPT_DIR/generate_config_from_table.py"'))
        root = Path(validator.__file__).resolve().parents[1]
        for pipeline in (root / ".pipelines").glob("rebuild-configuration*.yml"):
            content = pipeline.read_text(encoding="utf-8")
            self.assertIn("displayName: 'Stage generated files for artifact'\n  condition: succeeded()", content)
            self.assertIn("displayName: 'Publish artifact: policy-generated'\n  condition: succeeded()", content)


if __name__ == "__main__":
    unittest.main()

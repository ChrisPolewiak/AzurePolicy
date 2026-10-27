import csv
import json
from pathlib import Path
import tempfile
import unittest
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from generate_config_from_table import parse_parameter_value, read_params_source, write_json


class ParameterValueTests(unittest.TestCase):
    def test_string_casing_is_preserved(self):
        for value in ("true", "false", "True", "False", "TRUE", "FALSE", "Audit", "dEpLoY"):
            for hint in ("", "string", "String"):
                with self.subTest(value=value, hint=hint):
                    self.assertEqual(parse_parameter_value(value, hint), value)

    def test_acsb_tsv_to_json_preserves_lowercase_string(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "parameters.tsv"
            output = Path(directory) / "parameters.json"
            with source.open("w", encoding="utf-8", newline="") as stream:
                writer = csv.writer(stream, delimiter="\t")
                writer.writerow(["Parameter Set", "Applies To", "Key", "Value", "Type"])
                writer.writerow(["param_Enforce-ACSB", "initiative", "includeArcMachines", "false", "string"])
            write_json(output, read_params_source(source))
            value = json.loads(output.read_text(encoding="utf-8"))[
                "param_Enforce-ACSB"
            ]["initiative"]["includeArcMachines"]["value"]
            self.assertEqual(value, "false")
            self.assertIsInstance(value, str)

    def test_existing_integer_and_array_parsing_is_preserved(self):
        self.assertEqual(parse_parameter_value("42", "integer"), 42)
        self.assertEqual(parse_parameter_value('["false", "TRUE"]', ""), ["false", "TRUE"])
        self.assertEqual(parse_parameter_value("false,\nTRUE", "array"), ["false", "TRUE"])


if __name__ == "__main__":
    unittest.main()

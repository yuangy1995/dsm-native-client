"""脱敏 Fixture 严格校验测试。"""

from __future__ import annotations

import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


TOOLS_DIRECTORY = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


def load_module():
    specification = importlib.util.spec_from_file_location(
        "fixture_validator_test",
        TOOLS_DIRECTORY / "validate_fixtures.py",
    )
    if specification is None or specification.loader is None:
        raise RuntimeError("无法加载 Fixture 校验工具")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


validator = load_module()


class FixtureValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture_directory = (
            REPOSITORY_ROOT
            / "contracts/fixtures-redacted/file-station/list-folder"
            / "synthetic-string-numbers"
        )
        cls.metadata = validator.load_json(cls.fixture_directory / "metadata.json")
        cls.response = validator.load_json(cls.fixture_directory / "response.json")

    def test_repository_fixtures_pass_validation(self) -> None:
        directories = validator.validate_all()
        self.assertGreaterEqual(len(directories), 3)

    def test_repository_private_api_document_refs_pass_validation(self) -> None:
        self.assertGreater(validator.validate_private_api_compatibility(), 0)

    def test_rejects_missing_private_api_document(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            value = {
                "endpoints": [
                    {
                        "id": "new-internal-endpoint",
                        "classification": "internal",
                        "documentRef": "docs/api/discovery/endpoints/missing.md",
                    }
                ]
            }
            with self.assertRaisesRegex(validator.ValidationError, "文件不存在"):
                validator.validate_private_api_document_refs(value, root)

    def test_rejects_new_private_api_pointing_only_to_summary_index(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            index = root / validator.DISCOVERY_ENDPOINT_INDEX_REF
            index.parent.mkdir(parents=True)
            index.write_text("### `new-internal-endpoint`\n", encoding="utf-8")
            value = {
                "endpoints": [
                    {
                        "id": "new-internal-endpoint",
                        "classification": "internal",
                        "documentRef": validator.DISCOVERY_ENDPOINT_INDEX_REF,
                    }
                ]
            }
            with self.assertRaisesRegex(validator.ValidationError, "接口正文"):
                validator.validate_private_api_document_refs(value, root)

    def test_migrated_endpoint_cannot_revert_to_summary_index(self) -> None:
        endpoint_id = "quickconnect-relay-control"
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            index = root / validator.DISCOVERY_ENDPOINT_INDEX_REF
            index.parent.mkdir(parents=True)
            index.write_text(f"### `{endpoint_id}`\n", encoding="utf-8")
            value = {
                "endpoints": [
                    {
                        "id": endpoint_id,
                        "classification": "internal",
                        "documentRef": validator.DISCOVERY_ENDPOINT_INDEX_REF,
                    }
                ]
            }
            with self.assertRaisesRegex(validator.ValidationError, "接口正文"):
                validator.validate_private_api_document_refs(value, root)

    def test_rejects_standalone_document_without_matching_endpoint_id(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            document_ref = "docs/api/discovery/endpoints/standalone.md"
            document = root / document_ref
            document.parent.mkdir(parents=True)
            document.write_text("# 独立记录\n", encoding="utf-8")
            value = {
                "endpoints": [
                    {
                        "id": "standalone-internal-endpoint",
                        "classification": "internal",
                        "documentRef": document_ref,
                    }
                ]
            }
            with self.assertRaisesRegex(validator.ValidationError, "对应端点标识"):
                validator.validate_private_api_document_refs(value, root)

    def test_accepts_standalone_document_with_matching_endpoint_id(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            document_ref = "docs/api/discovery/endpoints/standalone.md"
            document = root / document_ref
            document.parent.mkdir(parents=True)
            document.write_text(
                "| 端点或端点组标识 | `standalone-internal-endpoint` |\n",
                encoding="utf-8",
            )
            value = {
                "endpoints": [
                    {
                        "id": "standalone-internal-endpoint",
                        "classification": "internal",
                        "documentRef": document_ref,
                    }
                ]
            }
            self.assertEqual(validator.validate_private_api_document_refs(value, root), 1)

    def test_rejects_real_fixture_without_stable_lab_alias(self) -> None:
        metadata = copy.deepcopy(self.metadata)
        metadata["sourceKind"] = "real-redacted"
        metadata["environment"]["alias"] = "my-nas"
        with self.assertRaisesRegex(validator.ValidationError, "稳定环境别名"):
            validator.validate_metadata(metadata, self.fixture_directory / "metadata.json")

    def test_accepts_official_lower_camel_case_method(self) -> None:
        metadata = copy.deepcopy(self.metadata)
        metadata["api"]["method"] = "getCategory"

        validator.validate_metadata(metadata, self.fixture_directory / "metadata.json")

    def test_rejects_method_starting_with_uppercase(self) -> None:
        metadata = copy.deepcopy(self.metadata)
        metadata["api"]["method"] = "GetCategory"

        with self.assertRaises(validator.ValidationError):
            validator.validate_metadata(metadata, self.fixture_directory / "metadata.json")

    def test_rejects_unredacted_session_field(self) -> None:
        response = copy.deepcopy(self.response)
        response["sid"] = "real-session"
        with self.assertRaisesRegex(validator.ValidationError, "脱敏占位符"):
            validator.scan_privacy(response)

    def test_rejects_private_values(self) -> None:
        for value in (
            "https://nas.example.test/webapi",
            "192.168.1.20",
            "00:11:22:33:44:55",
            "user@example.test",
            "/volume1/private/a.txt",
        ):
            with self.subTest(value=value):
                with self.assertRaises(validator.ValidationError):
                    validator.scan_privacy({"value": value})

    def test_rejects_orphan_response(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            orphan = root / "module/endpoint/orphan"
            orphan.mkdir(parents=True)
            (orphan / "response.json").write_text(
                json.dumps({"success": True}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(validator.ValidationError, "metadata"):
                validator.validate_all(root)


if __name__ == "__main__":
    unittest.main()

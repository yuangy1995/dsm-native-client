from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


MODULE_PATH = Path(__file__).parents[1] / "check_android_page_state_matrix.py"
MODULE_SPEC = importlib.util.spec_from_file_location("check_android_page_state_matrix", MODULE_PATH)
if MODULE_SPEC is None or MODULE_SPEC.loader is None:
    raise RuntimeError("无法加载 Android 页面五态矩阵检查器")

page_state_matrix = importlib.util.module_from_spec(MODULE_SPEC)
sys.modules[MODULE_SPEC.name] = page_state_matrix
MODULE_SPEC.loader.exec_module(page_state_matrix)


class AndroidPageStateMatrixTests(unittest.TestCase):
    def write_fixture(self, root: Path, state: str = "覆盖", automation: str = "完整") -> Path:
        (root / "ExampleScreen.kt").write_text("@Composable fun ExampleScreen() = Unit", encoding="utf-8")
        baseline = {
            "schemaVersion": 1, "lastReviewed": "2026-10-16",
            "writeOperations": [], "touchTargets": {}, "motion": {}, "structureDebt": {},
            "pageStates": [{
                "file": "ExampleScreen.kt", "automation": automation, "evidence": "测试",
                "states": {"loading": state, "empty": "不适用", "filteredEmpty": "不适用",
                           "error": "覆盖", "content": "覆盖"},
            }],
        }
        path = root / "baseline.json"
        path.write_text(json.dumps(baseline, ensure_ascii=False), encoding="utf-8")
        return path

    def validate_fixture(self, state: str = "覆盖", automation: str = "完整"):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            return page_state_matrix.validate(root, self.write_fixture(root, state, automation))

    def test_complete_matrix_is_accepted_without_plan_document(self) -> None:
        errors, gaps, automation_gaps = self.validate_fixture()
        self.assertEqual(errors, [])
        self.assertEqual((gaps, automation_gaps), (0, 0))

    def test_state_gap_is_rejected(self) -> None:
        errors, gaps, _ = self.validate_fixture(state="缺口")
        self.assertEqual(gaps, 1)
        self.assertTrue(any("完整基线出现回退" in error for error in errors))

    def test_partial_automation_is_rejected(self) -> None:
        errors, _, automation_gaps = self.validate_fixture(automation="局部")
        self.assertEqual(automation_gaps, 1)
        self.assertTrue(any("完整基线出现回退" in error for error in errors))

    def test_unknown_state_value_is_rejected(self) -> None:
        errors, _, _ = self.validate_fixture(state="也许")
        self.assertTrue(any("非法状态值" in error for error in errors))

    def test_new_surface_file_requires_audit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            baseline = self.write_fixture(root)
            (root / "NewDialog.kt").write_text("@Composable fun NewDialog() = Unit", encoding="utf-8")
            errors, _, _ = page_state_matrix.validate(root, baseline)
            self.assertTrue(any("遗漏生产页面" in error for error in errors))
            self.assertTrue(any("页面文件清单已变化" in error for error in errors))

    def test_removed_surface_file_requires_audit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            baseline = self.write_fixture(root)
            (root / "ExampleScreen.kt").unlink()
            errors, _, _ = page_state_matrix.validate(root, baseline)
            self.assertTrue(any("包含不存在" in error for error in errors))

    def test_missing_evidence_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            path = self.write_fixture(root)
            baseline = json.loads(path.read_text(encoding="utf-8"))
            baseline["pageStates"][0]["evidence"] = ""
            path.write_text(json.dumps(baseline), encoding="utf-8")
            errors, _, _ = page_state_matrix.validate(root, path)
            self.assertTrue(any("缺少代码与测试依据" in error for error in errors))


if __name__ == "__main__":
    unittest.main()

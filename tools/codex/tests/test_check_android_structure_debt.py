from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


MODULE_PATH = Path(__file__).parents[1] / "check_android_structure_debt.py"
MODULE_SPEC = importlib.util.spec_from_file_location("check_android_structure_debt", MODULE_PATH)
if MODULE_SPEC is None or MODULE_SPEC.loader is None:
    raise RuntimeError("无法加载 Android 结构债务检查器")

structure_debt = importlib.util.module_from_spec(MODULE_SPEC)
sys.modules[MODULE_SPEC.name] = structure_debt
MODULE_SPEC.loader.exec_module(structure_debt)


class AndroidStructureDebtTests(unittest.TestCase):
    def write_source(self, root: Path, relative: str, lines: int) -> None:
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("\n".join("val item = 1" for _ in range(lines)), encoding="utf-8")

    def test_existing_large_file_cannot_grow(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "AppViewModel.kt", 1002)
            errors = structure_debt.validate(
                root,
                {
                    "newProductionFileLineLimit": 1000,
                    "existingLargeFiles": [{"file": "AppViewModel.kt", "maxLines": 1001}],
                    "exceptions": [],
                },
            )
            self.assertTrue(any("不得增长" in error for error in errors))

    def test_new_large_file_needs_explicit_reason(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "NewRepository.kt", 1001)
            errors = structure_debt.validate(
                root,
                {"newProductionFileLineLimit": 1000, "existingLargeFiles": [], "exceptions": []},
            )
            self.assertTrue(any("没有明确例外理由" in error for error in errors))

    def test_explicit_reason_allows_large_new_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "NewRepository.kt", 1001)
            errors = structure_debt.validate(
                root,
                {
                    "newProductionFileLineLimit": 1000,
                    "existingLargeFiles": [],
                    "exceptions": [{"file": "NewRepository.kt", "reason": "生成代码待后续拆分"}],
                },
            )
            self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()

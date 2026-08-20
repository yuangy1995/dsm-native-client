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

    def debt(
        self,
        max_lines: int | None = None,
        target_lines: int = 1000,
        relative: str = "AppViewModel.kt",
    ) -> dict[str, object]:
        entries: list[dict[str, object]] = []
        if max_lines is not None:
            entries.append(
                {"file": relative, "maxLines": max_lines, "targetLines": target_lines},
            )
        return {
            "newProductionFileLineLimit": 1000,
            "existingLargeFiles": entries,
            "exceptions": [],
        }

    def test_existing_large_file_cannot_grow(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "AppViewModel.kt", 1002)

            errors = structure_debt.validate(root, self.debt(max_lines=1001))

            self.assertTrue(any("不得增长" in error for error in errors))

    def test_shortened_large_file_requires_current_ratchet_to_tighten(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "AppViewModel.kt", 1001)

            errors = structure_debt.validate(root, self.debt(max_lines=1002))

            self.assertTrue(any("必须收紧" in error for error in errors))

    def test_downward_ratchet_update_passes_against_previous_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "AppViewModel.kt", 1001)

            errors = structure_debt.validate(
                root,
                self.debt(max_lines=1001),
                previous_structure_debt=self.debt(max_lines=1002),
            )

            self.assertEqual(errors, [])

    def test_matching_current_file_still_rejects_raised_max_lines_from_previous_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "AppViewModel.kt", 1002)

            errors = structure_debt.validate(
                root,
                self.debt(max_lines=1002),
                previous_structure_debt=self.debt(max_lines=1001),
            )

            self.assertTrue(any("当前 ratchet 不得上调" in error for error in errors))

    def test_file_at_threshold_requires_old_large_file_entry_to_be_removed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "AppViewModel.kt", 1000)

            errors = structure_debt.validate(root, self.debt(max_lines=1001))

            self.assertTrue(any("降至 1000 行以内" in error for error in errors))

    def test_raised_target_lines_is_rejected_against_previous_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "AppViewModel.kt", 1001)

            errors = structure_debt.validate(
                root,
                self.debt(max_lines=1001, target_lines=1000),
                previous_structure_debt=self.debt(max_lines=1001, target_lines=999),
            )

            self.assertTrue(any("非阻断目标不得上调" in error for error in errors))

    def test_legacy_previous_baseline_uses_the_default_target_for_comparison(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "AppViewModel.kt", 1001)
            previous = self.debt(max_lines=1002)
            previous["existingLargeFiles"] = [{"file": "AppViewModel.kt", "maxLines": 1002}]

            errors = structure_debt.validate(
                root,
                self.debt(max_lines=1001),
                previous_structure_debt=previous,
            )

            self.assertEqual(errors, [])

    def test_new_large_file_without_reason_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "NewRepository.kt", 1001)

            errors = structure_debt.validate(root, self.debt())

            self.assertTrue(any("没有明确例外理由" in error for error in errors))

    def test_explicit_reason_allows_large_new_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "NewRepository.kt", 1001)
            debt = self.debt()
            debt["exceptions"] = [{"file": "NewRepository.kt", "reason": "生成代码待后续拆分"}]

            errors = structure_debt.validate(root, debt)

            self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()

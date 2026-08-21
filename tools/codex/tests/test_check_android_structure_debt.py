from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


TOOLS_PATH = Path(__file__).parents[1]
MODULE_PATH = TOOLS_PATH / "check_android_structure_debt.py"
MODULE_SPEC = importlib.util.spec_from_file_location("check_android_structure_debt", MODULE_PATH)
if MODULE_SPEC is None or MODULE_SPEC.loader is None:
    raise RuntimeError("无法加载 Android 结构债务检查器")

structure_debt = importlib.util.module_from_spec(MODULE_SPEC)
sys.modules[MODULE_SPEC.name] = structure_debt
MODULE_SPEC.loader.exec_module(structure_debt)

GENERATOR_PATH = TOOLS_PATH / "generate_android_quality_baseline.py"
GENERATOR_SPEC = importlib.util.spec_from_file_location("generate_android_quality_baseline", GENERATOR_PATH)
if GENERATOR_SPEC is None or GENERATOR_SPEC.loader is None:
    raise RuntimeError("无法加载 Android 质量基线生成器")

quality_baseline = importlib.util.module_from_spec(GENERATOR_SPEC)
sys.modules[GENERATOR_SPEC.name] = quality_baseline
GENERATOR_SPEC.loader.exec_module(quality_baseline)


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
        stable_id: str = "android-app-view-model",
        limit: int = 1000,
        exceptions: list[dict[str, str]] | None = None,
        identity_transitions: list[dict[str, object]] | None = None,
    ) -> dict[str, object]:
        entries: list[dict[str, object]] = []
        if max_lines is not None:
            entries.append(
                {
                    "id": stable_id,
                    "file": relative,
                    "maxLines": max_lines,
                    "targetLines": target_lines,
                },
            )
        normalized_exceptions = []
        for index, exception in enumerate(exceptions or []):
            normalized = dict(exception)
            normalized.setdefault("id", f"android-exception-{index + 1}")
            normalized_exceptions.append(normalized)
        return {
            "newProductionFileLineLimit": limit,
            "existingLargeFiles": entries,
            "exceptions": normalized_exceptions,
            "identityTransitions": [dict(item) for item in identity_transitions or []],
        }

    def transition(
        self,
        stable_id: str = "android-app-view-model",
        from_path: str = "AppViewModel.kt",
        to_path: str | None = "LegacyAppViewModel.kt",
        kind: str = "migration",
    ) -> dict[str, object]:
        return {
            "id": stable_id,
            "kind": kind,
            "from": from_path,
            "to": to_path,
            "reason": "低相似度移动后的稳定身份连续性验证",
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

    def test_legacy_previous_baseline_migrates_by_same_path_once(self) -> None:
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

    def test_new_production_file_limit_cannot_increase(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "AppViewModel.kt", 1004)

            errors = structure_debt.validate(
                root,
                self.debt(max_lines=1004, target_lines=1000, limit=1003),
                previous_structure_debt=self.debt(max_lines=1002, target_lines=1000, limit=1000),
            )

            self.assertTrue(any("newProductionFileLineLimit 不得上调" in error for error in errors))
            self.assertFalse(any("上一基线无效" in error for error in errors))

    def test_existing_debt_cannot_move_to_exception(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "AppViewModel.kt", 1002)
            previous = self.debt(max_lines=1002)
            current = self.debt(
                exceptions=[
                    {
                        "id": "android-app-view-model",
                        "file": "AppViewModel.kt",
                        "reason": "不允许转移历史债务",
                    },
                ],
            )

            errors = structure_debt.validate(
                root,
                current,
                previous_structure_debt=previous,
                rename_map={"AppViewModel.kt": "LegacyAppViewModel.kt"},
            )

            self.assertTrue(any("不得转入 exceptions" in error for error in errors))

    def test_existing_debt_must_remain_tracked_while_above_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "AppViewModel.kt", 1002)

            errors = structure_debt.validate(
                root,
                self.debt(),
                previous_structure_debt=self.debt(max_lines=1002),
            )

            self.assertTrue(any("必须继续登记" in error for error in errors))

    def test_deleted_debt_requires_explicit_deletion_but_lowered_debt_can_be_removed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            previous = self.debt(max_lines=1002)
            root = Path(temporary_directory)

            deleted_errors = structure_debt.validate(
                root,
                self.debt(),
                previous_structure_debt=previous,
            )
            self.assertTrue(any("删除声明" in error for error in deleted_errors))

            self.write_source(root, "AppViewModel.kt", 1000)
            reduced_errors = structure_debt.validate(
                root,
                self.debt(),
                previous_structure_debt=previous,
            )
            self.assertEqual(reduced_errors, [])

    def test_debt_moved_out_of_current_production_root_requires_explicit_deletion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory) / "production"
            root.mkdir()
            (Path(temporary_directory) / "moved-out-of-production.kt").write_text(
                "val item = 1\n" * 1002,
                encoding="utf-8",
            )

            errors = structure_debt.validate(
                root,
                self.debt(),
                previous_structure_debt=self.debt(max_lines=1002),
            )

            self.assertTrue(any("删除声明" in error for error in errors))

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
            debt = self.debt(
                exceptions=[{"file": "NewRepository.kt", "reason": "生成代码待后续拆分"}],
            )

            errors = structure_debt.validate(root, debt)

            self.assertEqual(errors, [])

    def test_git_detected_rename_keeps_ratchet(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "LegacyAppViewModel.kt", 1001)
            previous = self.debt(max_lines=1002, target_lines=1000)
            current = self.debt(
                max_lines=1001,
                target_lines=1000,
                relative="LegacyAppViewModel.kt",
            )

            errors = structure_debt.validate(
                root,
                current,
                previous_structure_debt=previous,
                rename_map={"AppViewModel.kt": "LegacyAppViewModel.kt"},
            )

            self.assertEqual(errors, [])

    def test_renamed_existing_debt_cannot_raise_ratchet_or_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "LegacyAppViewModel.kt", 1002)
            previous = self.debt(max_lines=1001, target_lines=999)
            current = self.debt(
                max_lines=1002,
                target_lines=1000,
                relative="LegacyAppViewModel.kt",
            )

            errors = structure_debt.validate(
                root,
                current,
                previous_structure_debt=previous,
                rename_map={"AppViewModel.kt": "LegacyAppViewModel.kt"},
            )

            self.assertTrue(any("当前 ratchet 不得上调" in error for error in errors))
            self.assertTrue(any("非阻断目标不得上调" in error for error in errors))

    def test_renamed_existing_debt_cannot_become_exception(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "LegacyAppViewModel.kt", 1002)
            previous = self.debt(max_lines=1002)
            current = self.debt(
                exceptions=[
                    {
                        "id": "android-app-view-model",
                        "file": "LegacyAppViewModel.kt",
                        "reason": "改名后仍应继续拆分",
                    },
                ],
            )

            errors = structure_debt.validate(
                root,
                current,
                previous_structure_debt=previous,
                rename_map={"AppViewModel.kt": "LegacyAppViewModel.kt"},
            )

            self.assertTrue(any("不得转入 exceptions" in error for error in errors))

    def test_renamed_changed_id_exception_is_rejected_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "LegacyAppViewModel.kt", 1002)
            previous = self.debt(max_lines=1002)
            current = self.debt(
                exceptions=[
                    {
                        "id": "android-legacy-app-view-model",
                        "file": "LegacyAppViewModel.kt",
                        "reason": "不得通过改名绕过历史债务",
                    },
                ],
            )

            errors = structure_debt.validate(
                root,
                current,
                previous_structure_debt=previous,
                rename_map={"AppViewModel.kt": "LegacyAppViewModel.kt"},
            )

            self.assertTrue(any("稳定 id 不得改换" in error for error in errors))

    def test_existing_id_cannot_change_at_same_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "AppViewModel.kt", 1001)
            previous = self.debt(max_lines=1001)
            current = self.debt(max_lines=1001, stable_id="android-app-view-model-renamed")

            errors = structure_debt.validate(root, current, previous_structure_debt=previous)

            self.assertTrue(any("稳定 id 不得改换" in error for error in errors))

    def test_duplicate_id_and_cross_list_path_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "AppViewModel.kt", 1001)
            current = self.debt(
                max_lines=1001,
                exceptions=[
                    {
                        "id": "android-app-view-model",
                        "file": "AppViewModel.kt",
                        "reason": "用于验证重复身份",
                    },
                ],
            )

            errors = structure_debt.validate(root, current)

            self.assertTrue(any("id 不得同时登记" in error for error in errors))
            self.assertTrue(any("路径不得同时登记" in error for error in errors))

    def test_duplicate_ids_and_paths_inside_each_list_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "AppViewModel.kt", 1001)
            self.write_source(root, "Second.kt", 1001)
            self.write_source(root, "Third.kt", 1001)
            self.write_source(root, "Fourth.kt", 1001)
            current = self.debt(max_lines=1001)
            current["existingLargeFiles"].append(
                {
                    "id": "android-app-view-model",
                    "file": "Second.kt",
                    "maxLines": 1001,
                    "targetLines": 1000,
                },
            )
            current["existingLargeFiles"].append(
                {
                    "id": "android-second",
                    "file": "AppViewModel.kt",
                    "maxLines": 1001,
                    "targetLines": 1000,
                },
            )
            current["exceptions"] = [
                {"id": "android-exception", "file": "Third.kt", "reason": "重复 ID 测试"},
                {"id": "android-exception", "file": "Fourth.kt", "reason": "重复 ID 测试"},
            ]

            errors = structure_debt.validate(root, current)

            self.assertTrue(any("既有大文件稳定 id 重复" in error for error in errors))
            self.assertTrue(any("既有大文件重复登记" in error for error in errors))
            self.assertTrue(any("超大文件例外稳定 id 重复" in error for error in errors))

    def test_current_entries_require_stable_ids(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "AppViewModel.kt", 1001)
            current = self.debt(max_lines=1001)
            current["existingLargeFiles"][0].pop("id")

            errors = structure_debt.validate(root, current)

            self.assertTrue(any("缺少有效、稳定的 id" in error for error in errors))

    def test_current_exceptions_require_stable_ids(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "NewRepository.kt", 1001)
            current = self.debt()
            current["exceptions"] = [
                {"file": "NewRepository.kt", "reason": "用于验证例外身份"},
            ]

            errors = structure_debt.validate(root, current)

            self.assertTrue(any("exceptions 缺少有效、稳定的 id" in error for error in errors))

    def test_unrelated_large_file_cannot_inherit_stable_id(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "UnrelatedRepository.kt", 1001)
            previous = self.debt(max_lines=1001)
            current = self.debt(
                max_lines=1001,
                relative="UnrelatedRepository.kt",
            )

            errors = structure_debt.validate(root, current, previous_structure_debt=previous)

            self.assertTrue(any("路径变更缺少 Git rename 证据" in error for error in errors))

    def test_unverified_path_change_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "LegacyAppViewModel.kt", 1001)
            previous = self.debt(max_lines=1001)
            current = self.debt(
                max_lines=1001,
                relative="LegacyAppViewModel.kt",
            )

            errors = structure_debt.validate(root, current, previous_structure_debt=previous)

            self.assertTrue(any("路径变更缺少 Git rename 证据" in error for error in errors))

    def test_rename_map_only_accepts_exact_git_rename_records(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "rename-map.txt"
            prefix = structure_debt.PRODUCTION_PREFIX
            path.write_text(
                "M\tTracked.kt\n"
                "C100\tOld.kt\tCopy.kt\n"
                "A\tAdded.kt\n"
                "D\tDeleted.kt\n"
                f"R090\t{prefix}/AppViewModel.kt\t{prefix}/LegacyAppViewModel.kt\n",
                encoding="utf-8",
            )

            self.assertEqual(
                structure_debt.load_rename_map(path),
                {"AppViewModel.kt": "LegacyAppViewModel.kt"},
            )

            path.write_text(f"R100\t{prefix}/AppViewModel.kt\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "有效的 Rnnn"):
                structure_debt.load_rename_map(path)

    def test_github_actions_rename_map_normalizes_repository_relative_production_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "rename-map.txt"
            prefix = structure_debt.PRODUCTION_PREFIX
            path.write_text(
                "R100\t"
                f"{prefix}/io/github/qwertyuiop1995/dsmnativeclient/AppViewModel.kt\t"
                f"{prefix}/io/github/qwertyuiop1995/dsmnativeclient/LegacyAppViewModel.kt\n",
                encoding="utf-8",
            )

            self.assertEqual(
                structure_debt.load_rename_map(path),
                {
                    "io/github/qwertyuiop1995/dsmnativeclient/AppViewModel.kt":
                        "io/github/qwertyuiop1995/dsmnativeclient/LegacyAppViewModel.kt",
                },
            )

    def test_github_actions_tracked_rename_keeps_ratchet(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "LegacyAppViewModel.kt", 1001)
            rename_path = root / "rename-map.txt"
            prefix = structure_debt.PRODUCTION_PREFIX
            rename_path.write_text(
                f"R100\t{prefix}/AppViewModel.kt\t{prefix}/LegacyAppViewModel.kt\n",
                encoding="utf-8",
            )

            errors = structure_debt.validate(
                root,
                self.debt(max_lines=1001, relative="LegacyAppViewModel.kt"),
                previous_structure_debt=self.debt(max_lines=1002),
                rename_map=structure_debt.load_rename_map(rename_path),
            )

            self.assertEqual(errors, [])

    def test_github_actions_tracked_rename_cannot_become_new_id_exception(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "LegacyAppViewModel.kt", 1002)
            rename_path = root / "rename-map.txt"
            prefix = structure_debt.PRODUCTION_PREFIX
            rename_path.write_text(
                f"R100\t{prefix}/AppViewModel.kt\t{prefix}/LegacyAppViewModel.kt\n",
                encoding="utf-8",
            )
            current = self.debt(
                exceptions=[
                    {
                        "id": "android-legacy-app-view-model",
                        "file": "LegacyAppViewModel.kt",
                        "reason": "改名不能绕过历史 tracked 身份",
                    },
                ],
            )

            errors = structure_debt.validate(
                root,
                current,
                previous_structure_debt=self.debt(max_lines=1002),
                rename_map=structure_debt.load_rename_map(rename_path),
            )

            self.assertTrue(any("稳定 id 不得改换" in error for error in errors))

    def test_github_actions_previous_exception_rename_cannot_change_id(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "RenamedLegacy.kt", 1001)
            rename_path = root / "rename-map.txt"
            prefix = structure_debt.PRODUCTION_PREFIX
            rename_path.write_text(
                f"R100\t{prefix}/Legacy.kt\t{prefix}/RenamedLegacy.kt\n",
                encoding="utf-8",
            )
            previous = self.debt(
                exceptions=[
                    {"id": "android-legacy", "file": "Legacy.kt", "reason": "历史例外"},
                ],
            )
            current = self.debt(
                exceptions=[
                    {
                        "id": "android-renamed-legacy",
                        "file": "RenamedLegacy.kt",
                        "reason": "不得通过改名换例外身份",
                    },
                ],
            )

            errors = structure_debt.validate(
                root,
                current,
                previous_structure_debt=previous,
                rename_map=structure_debt.load_rename_map(rename_path),
            )

            self.assertTrue(any("exception 稳定 id 不得改换" in error for error in errors))

    def test_rename_outside_to_production_does_not_inherit_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "rename-map.txt"
            prefix = structure_debt.PRODUCTION_PREFIX
            path.write_text(
                f"R100\tdocs/Legacy.kt\t{prefix}/Legacy.kt\n",
                encoding="utf-8",
            )

            self.assertEqual(structure_debt.load_rename_map(path), {})

    def test_rename_production_to_outside_requires_explicit_deletion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            path = root / "rename-map.txt"
            prefix = structure_debt.PRODUCTION_PREFIX
            path.write_text(
                f"R100\t{prefix}/AppViewModel.kt\tdocs/Legacy.kt\n",
                encoding="utf-8",
            )

            self.assertEqual(structure_debt.load_rename_map(path), {})
            errors = structure_debt.validate(
                root,
                self.debt(),
                previous_structure_debt=self.debt(max_lines=1002),
                rename_map=structure_debt.load_rename_map(path),
            )
            self.assertTrue(any("删除声明" in error for error in errors))

    def test_rename_map_rejects_abnormal_mixed_and_ambiguous_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "rename-map.txt"
            prefix = structure_debt.PRODUCTION_PREFIX
            invalid_records = [
                f"R99\t{prefix}/AppViewModel.kt\t{prefix}/Legacy.kt\n",
                f"R000\t{prefix}/AppViewModel.kt\t{prefix}/Legacy.kt\n",
                f"R100\t/{prefix}/AppViewModel.kt\t{prefix}/Legacy.kt\n",
                f"R100\t{prefix}/../AppViewModel.kt\t{prefix}/Legacy.kt\n",
                f"R100\t{prefix}/\t{prefix}/Legacy.kt\n",
                f"R100\tio/github/qwertyuiop1995/dsmnativeclient/AppViewModel.kt\t{prefix}/Legacy.kt\n",
                (
                    f"R100\t{prefix}/AppViewModel.kt\t{prefix}/Legacy.kt\n"
                    f"R100\t{prefix}/AppViewModel.kt\t{prefix}/AnotherLegacy.kt\n"
                ),
            ]

            for record in invalid_records:
                path.write_text(record, encoding="utf-8")
                with self.assertRaises(ValueError):
                    structure_debt.load_rename_map(path)

    def test_previous_exception_same_path_continues(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "Legacy.kt", 1001)
            previous = self.debt(
                exceptions=[
                    {"id": "android-legacy", "file": "Legacy.kt", "reason": "历史例外"},
                ],
            )
            current = self.debt(
                exceptions=[
                    {"id": "android-legacy", "file": "Legacy.kt", "reason": "继续追踪"},
                ],
            )

            errors = structure_debt.validate(root, current, previous_structure_debt=previous)

            self.assertEqual(errors, [])

    def test_previous_exception_verified_rename_continues(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "RenamedLegacy.kt", 1001)
            previous = self.debt(
                exceptions=[
                    {"id": "android-legacy", "file": "Legacy.kt", "reason": "历史例外"},
                ],
            )
            current = self.debt(
                exceptions=[
                    {
                        "id": "android-legacy",
                        "file": "RenamedLegacy.kt",
                        "reason": "重命名后继续追踪",
                    },
                ],
            )

            errors = structure_debt.validate(
                root,
                current,
                previous_structure_debt=previous,
                rename_map={"Legacy.kt": "RenamedLegacy.kt"},
            )

            self.assertEqual(errors, [])

    def test_previous_exception_can_tighten_to_tracked(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "Legacy.kt", 1001)
            previous = self.debt(
                exceptions=[
                    {"id": "android-legacy", "file": "Legacy.kt", "reason": "历史例外"},
                ],
            )
            current = self.debt(
                max_lines=1001,
                target_lines=900,
                relative="Legacy.kt",
                stable_id="android-legacy",
            )

            errors = structure_debt.validate(root, current, previous_structure_debt=previous)

            self.assertEqual(errors, [])

    def test_previous_exception_cannot_lend_id(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "UnrelatedRepository.kt", 1001)
            previous = self.debt(
                exceptions=[
                    {"id": "android-legacy", "file": "Legacy.kt", "reason": "历史例外"},
                ],
            )
            current = self.debt(
                max_lines=1001,
                relative="UnrelatedRepository.kt",
                stable_id="android-legacy",
            )

            errors = structure_debt.validate(root, current, previous_structure_debt=previous)

            self.assertTrue(any("路径变更缺少 Git rename 证据" in error for error in errors))

    def test_previous_exception_removal_requires_delete_move_or_below_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "Legacy.kt", 1001)
            previous = self.debt(
                exceptions=[
                    {"id": "android-legacy", "file": "Legacy.kt", "reason": "历史例外"},
                ],
            )

            errors = structure_debt.validate(root, self.debt(), previous_structure_debt=previous)

            self.assertTrue(any("exception 仍超过" in error for error in errors))

            self.write_source(root, "Legacy.kt", 1000)
            lowered_errors = structure_debt.validate(root, self.debt(), previous_structure_debt=previous)

            self.assertEqual(lowered_errors, [])

    def test_low_similarity_deleted_tracked_to_new_exception_fails_closed_without_transition(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "RewrittenAppViewModel.kt", 1002)
            previous = self.debt(max_lines=1002)
            current = self.debt(
                exceptions=[
                    {
                        "id": "android-rewritten-app-view-model",
                        "file": "RewrittenAppViewModel.kt",
                        "reason": "低相似度改写不能洗白既有债务",
                    },
                ],
            )

            errors = structure_debt.validate(
                root,
                current,
                previous_structure_debt=previous,
                rename_map={},
            )

            self.assertTrue(any("D+A" in error for error in errors))

    def test_low_similarity_deleted_exception_to_new_exception_fails_closed_without_transition(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "RewrittenLegacy.kt", 1001)
            previous = self.debt(
                exceptions=[
                    {"id": "android-legacy", "file": "Legacy.kt", "reason": "历史例外"},
                ],
            )
            current = self.debt(
                exceptions=[
                    {
                        "id": "android-rewritten-legacy",
                        "file": "RewrittenLegacy.kt",
                        "reason": "低相似度改写不能重置例外身份",
                    },
                ],
            )

            errors = structure_debt.validate(
                root,
                current,
                previous_structure_debt=previous,
                rename_map={},
            )

            self.assertTrue(any("D+A" in error for error in errors))

    def test_same_stable_id_low_similarity_migration_passes_with_explicit_transition(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "RewrittenAppViewModel.kt", 1001)
            previous = self.debt(max_lines=1002, target_lines=1000)
            current = self.debt(
                max_lines=1001,
                target_lines=1000,
                relative="RewrittenAppViewModel.kt",
                identity_transitions=[
                    self.transition(to_path="RewrittenAppViewModel.kt"),
                ],
            )

            errors = structure_debt.validate(
                root,
                current,
                previous_structure_debt=previous,
                rename_map={},
            )

            self.assertEqual(errors, [])

    def test_explicit_migration_cannot_raise_max_or_target_ratchet(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "RewrittenAppViewModel.kt", 1002)
            previous = self.debt(max_lines=1001, target_lines=999)
            current = self.debt(
                max_lines=1002,
                target_lines=1000,
                relative="RewrittenAppViewModel.kt",
                identity_transitions=[
                    self.transition(to_path="RewrittenAppViewModel.kt"),
                ],
            )

            errors = structure_debt.validate(
                root,
                current,
                previous_structure_debt=previous,
                rename_map={},
            )

            self.assertTrue(any("当前 ratchet 不得上调" in error for error in errors))
            self.assertTrue(any("非阻断目标不得上调" in error for error in errors))

    def test_tracked_debt_cannot_move_to_exception_even_with_explicit_transition(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "RewrittenAppViewModel.kt", 1002)
            previous = self.debt(max_lines=1002)
            current = self.debt(
                exceptions=[
                    {
                        "id": "android-app-view-model",
                        "file": "RewrittenAppViewModel.kt",
                        "reason": "tracked 债务不得降级为例外",
                    },
                ],
                identity_transitions=[
                    self.transition(to_path="RewrittenAppViewModel.kt"),
                ],
            )

            errors = structure_debt.validate(
                root,
                current,
                previous_structure_debt=previous,
                rename_map={},
            )

            self.assertTrue(any("不得转入 exceptions" in error for error in errors))

    def test_explicit_true_deletion_passes_but_missing_declaration_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            previous = self.debt(max_lines=1002)
            declared = self.debt(
                identity_transitions=[
                    self.transition(to_path=None, kind="deletion"),
                ],
            )

            declared_errors = structure_debt.validate(
                root,
                declared,
                previous_structure_debt=previous,
                rename_map={},
            )
            missing_errors = structure_debt.validate(
                root,
                self.debt(),
                previous_structure_debt=previous,
                rename_map={},
            )

            self.assertEqual(declared_errors, [])
            self.assertTrue(any("删除声明" in error for error in missing_errors))

    def test_stale_redundant_duplicate_and_conflicting_transitions_fail(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "AppViewModel.kt", 1001)
            previous = self.debt(max_lines=1001)
            stale = self.debt(
                max_lines=1001,
                identity_transitions=[self.transition(to_path="LegacyAppViewModel.kt")],
            )

            stale_errors = structure_debt.validate(
                root,
                stale,
                previous_structure_debt=previous,
                rename_map={},
            )
            redundant = self.debt(
                max_lines=1001,
                identity_transitions=[self.transition(to_path="AppViewModel.kt")],
            )
            redundant_errors = structure_debt.validate(
                root,
                redundant,
                previous_structure_debt=previous,
                rename_map={},
            )

            self.write_source(root, "RewrittenAppViewModel.kt", 1001)
            migrated = self.debt(
                max_lines=1001,
                relative="RewrittenAppViewModel.kt",
                identity_transitions=[
                    self.transition(to_path="RewrittenAppViewModel.kt"),
                    self.transition(to_path="RewrittenAppViewModel.kt"),
                ],
            )
            duplicate_errors = structure_debt.validate(
                root,
                migrated,
                previous_structure_debt=previous,
                rename_map={},
            )
            conflict_root = root / "conflict"
            conflict_root.mkdir()
            self.write_source(conflict_root, "RewrittenAppViewModel.kt", 1001)
            conflicting_errors = structure_debt.validate(
                conflict_root,
                self.debt(
                    max_lines=1001,
                    relative="RewrittenAppViewModel.kt",
                    identity_transitions=[self.transition(to_path="RewrittenAppViewModel.kt")],
                ),
                previous_structure_debt=previous,
                rename_map={"AppViewModel.kt": "GitRenamedAppViewModel.kt"},
            )

            self.assertTrue(any("当前目标" in error for error in stale_errors))
            self.assertTrue(any("from 与 to 不得相同" in error for error in redundant_errors))
            self.assertTrue(any("重复" in error for error in duplicate_errors))
            self.assertTrue(any("Git rename" in error for error in conflicting_errors))

    def test_consumed_transition_and_unsafe_transition_schema_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "RewrittenAppViewModel.kt", 1001)
            previous = self.debt(
                max_lines=1001,
                relative="RewrittenAppViewModel.kt",
            )
            stale_current = self.debt(
                max_lines=1001,
                relative="RewrittenAppViewModel.kt",
                identity_transitions=[self.transition(to_path="RewrittenAppViewModel.kt")],
            )
            unsafe_current = self.debt(
                max_lines=1001,
                relative="RewrittenAppViewModel.kt",
                identity_transitions=[
                    self.transition(from_path="../AppViewModel.kt", to_path="RewrittenAppViewModel.kt"),
                ],
            )
            missing_schema = self.debt(max_lines=1001, relative="RewrittenAppViewModel.kt")
            missing_schema.pop("identityTransitions")

            stale_errors = structure_debt.validate(
                root,
                stale_current,
                previous_structure_debt=previous,
                rename_map={},
            )
            unsafe_errors = structure_debt.validate(
                root,
                unsafe_current,
                previous_structure_debt=previous,
                rename_map={},
            )
            missing_schema_errors = structure_debt.validate(root, missing_schema)

            self.assertTrue(any("source 路径必须精确" in error for error in stale_errors))
            self.assertTrue(any("路径遍历" in error for error in unsafe_errors))
            self.assertTrue(any("缺少 identityTransitions" in error for error in missing_schema_errors))

    def test_r100_and_r090_rename_evidence_remain_valid(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "LegacyAppViewModel.kt", 1001)
            previous = self.debt(max_lines=1002)
            current = self.debt(max_lines=1001, relative="LegacyAppViewModel.kt")
            prefix = structure_debt.PRODUCTION_PREFIX

            for status in ("R100", "R090"):
                with self.subTest(status=status):
                    rename_path = root / f"{status}-rename-map.txt"
                    rename_path.write_text(
                        f"{status}\t{prefix}/AppViewModel.kt\t{prefix}/LegacyAppViewModel.kt\n",
                        encoding="utf-8",
                    )
                    errors = structure_debt.validate(
                        root,
                        current,
                        previous_structure_debt=previous,
                        rename_map=structure_debt.load_rename_map(rename_path),
                    )
                    self.assertEqual(errors, [])

    def test_generator_preserves_id_and_target_while_only_tightening_max(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write_source(root, "AppViewModel.kt", 1001)
            baseline = {"structureDebt": self.debt(max_lines=1002, target_lines=999)}

            updated = quality_baseline.tighten_structure_debt_ratchet(
                baseline,
                production_root=root,
            )

            self.assertEqual(
                updated["structureDebt"]["existingLargeFiles"],
                [
                    {
                        "id": "android-app-view-model",
                        "file": "AppViewModel.kt",
                        "maxLines": 1001,
                        "targetLines": 999,
                    },
                ],
            )


if __name__ == "__main__":
    unittest.main()

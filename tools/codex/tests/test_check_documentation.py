from __future__ import annotations

from datetime import date
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


MODULE_PATH = Path(__file__).parents[1] / "check_documentation.py"
MODULE_SPEC = importlib.util.spec_from_file_location("check_documentation", MODULE_PATH)
if MODULE_SPEC is None or MODULE_SPEC.loader is None:
    raise RuntimeError("无法加载文档检查器")

documentation = importlib.util.module_from_spec(MODULE_SPEC)
sys.modules[MODULE_SPEC.name] = documentation
MODULE_SPEC.loader.exec_module(documentation)


class DocumentationCheckTests(unittest.TestCase):
    def write(self, root: Path, relative: str, text: str) -> Path:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def metadata(self, role: str, reviewed: str = "2026-08-20") -> str:
        return f"<!-- doc-role: {role} -->\n<!-- last-reviewed: {reviewed} -->\n\n"

    def test_resolves_relative_link_and_heading_anchor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self.write(root, "docs/source.md", "[目标](target.md#中文标题)\n")
            target = self.write(root, "docs/target.md", "# 中文标题\n")
            self.assertEqual(documentation.validate_links([source, target]), [])

    def test_rejects_missing_file_and_anchor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self.write(root, "docs/source.md", "[缺失](none.md)\n[错误](target.md#不存在)\n")
            target = self.write(root, "docs/target.md", "# 存在\n")
            errors = documentation.validate_links([source, target])
            self.assertTrue(any("断链" in error for error in errors))
            self.assertTrue(any("标题锚点不存在" in error for error in errors))

    def test_requires_role_and_review_date(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write(root, "docs/progress/STATUS.md", "# 状态\n")
            errors = documentation.validate_active_metadata(
                root,
                {"docs/progress/STATUS.md": "status"},
                today=date(2026, 8, 20),
            )
            self.assertTrue(any("doc-role" in error for error in errors))
            self.assertTrue(any("last-reviewed" in error for error in errors))

    def test_strict_release_enforces_status_and_matrix_freshness(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write(root, "docs/progress/STATUS.md", self.metadata("status", "2026-06-01") + "# 状态\n")
            errors = documentation.validate_active_metadata(
                root,
                {"docs/progress/STATUS.md": "status"},
                strict_release=True,
                today=date(2026, 8, 20),
            )
            self.assertTrue(any("时效超限" in error for error in errors))

    def test_rejects_ci_run_and_manual_test_count_in_active_document(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.write(
                root,
                "docs/progress/ROADMAP.md",
                self.metadata("roadmap") + "GitHub Build 123456\n测试 12/12 通过\n",
            )
            errors = documentation.validate_active_metadata(
                root,
                {"docs/progress/ROADMAP.md": "roadmap"},
                today=date(2026, 8, 20),
            )
            self.assertTrue(any("CI Run ID" in error for error in errors))
            self.assertTrue(any("测试数量" in error for error in errors))

    def test_rejects_full_commit_sha_only_in_status_prose(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            sha = "0123456789abcdef0123456789abcdef01234567"
            self.write(
                root,
                "docs/progress/STATUS.md",
                self.metadata("status") + f"当前状态引用 {sha}\n",
            )
            errors = documentation.validate_active_metadata(
                root,
                {"docs/progress/STATUS.md": "status"},
                today=date(2026, 8, 20),
            )
            self.assertTrue(any("完整提交 SHA" in error for error in errors))

            self.write(
                root,
                "docs/progress/STATUS.md",
                self.metadata("status") + f"```text\n{sha}\n```\n",
            )
            code_errors = documentation.validate_active_metadata(
                root,
                {"docs/progress/STATUS.md": "status"},
                today=date(2026, 8, 20),
            )
            self.assertFalse(any("完整提交 SHA" in error for error in code_errors))

    def test_status_line_count_range(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "STATUS.md"
            path.write_text("\n".join("状态" for _ in range(149)), encoding="utf-8")
            self.assertTrue(documentation.validate_status_line_count(path))
            path.write_text("\n".join("状态" for _ in range(150)), encoding="utf-8")
            self.assertEqual(documentation.validate_status_line_count(path), [])


if __name__ == "__main__":
    unittest.main()

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "check_android_write_test_matrix.py"
SPEC = importlib.util.spec_from_file_location("check_android_write_test_matrix", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class AndroidWriteTestMatrixCheckTest(unittest.TestCase):
    def test_supplemental_recovery_evidence_cannot_reference_a_missing_test(self):
        row = self.row("example", state="readonly", success="na", readback="na", cancel="na",
                       recovery="MissingRecoveryTest.kt::must exist")
        errors = MODULE.validate(calls={"example"}, rows=[row])
        self.assertTrue(any("MissingRecoveryTest.kt" in error for error in errors))

    def test_result_property_is_not_a_write_but_calls_and_references_remain(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = """
class Owner {
    fun render() = state.uploadResult?.status
    fun send() = repo.uploadResult(source)
    fun callback() = repo.uploadResult { checkpoint() }
    fun reference() = submit(repo::uploadResult)
}
"""
            (root / "Upload.kt").write_text(source, encoding="utf-8")
            sites = MODULE.discover_result_call_sites({"uploadResult"}, root)
            self.assertEqual([site["owner"] for site in sites], ["send", "callback", "reference"])
            self.assertEqual(len(list(MODULE.DIRECT_RESULT_CALL_PATTERN.finditer(source))), 3)

    def test_qualified_checkpoint_entry_does_not_capture_unrelated_methods(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Connections.kt").write_text("""
class Owner {
    fun confirm() = repo.nasConnections.disconnect(target) { saveCheckpoint(it) }
    fun unrelated() = socket.disconnect()
    fun renamed() = repo.nasConnections.disconnectLater(target)
}
""", encoding="utf-8")
            sites = MODULE.discover_result_call_sites({"nasConnections.disconnect"}, root)
            self.assertEqual([(site["owner"], site["resultMethod"]) for site in sites],
                             [("confirm", "nasConnections.disconnect")])

    def test_registered_feature_repository_entry_keeps_exact_call_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Chat.kt").write_text("""
class ChatOwner {
    fun send() = repository.executeAction()
    fun continueGroup() = repository.continueGroupAction()
    fun unrelated() = repository.executeActionLater()
}
internal suspend fun ChatRepository.executeAction() = Unit
""", encoding="utf-8")
            sites = MODULE.discover_result_call_sites({"executeAction", "continueGroupAction"}, root)
            self.assertEqual([(site["owner"], site["resultMethod"]) for site in sites],
                             [("send", "executeAction"), ("continueGroup", "continueGroupAction")])

    def row(self, methods, state="open", multi=False, **fields):
        values = {
            "methods": methods,
            "state": state,
            "multi": "yes" if multi else "no",
            **fields,
        }
        return MODULE.MatrixRow(
            methods=tuple(methods.split(",")),
            state=state,
            multi=multi,
            fields=values,
        )

    def test_extracts_unique_production_result_calls(self):
        source = "repo.moveResult(); repository.deleteResult(1); repo.moveResult()"
        self.assertEqual(
            MODULE.production_result_calls(source),
            {"moveResult", "deleteResult"},
        )

    def test_rejects_legacy_flat_action_coordinator(self):
        source = """
class AppViewModel {
    fun deleteFile() = action { repo -> repo.deleteResult(listOf("/demo")) }
    private fun action(block: suspend (DsmRepository) -> MutationResult) = Unit
}
internal fun containerWriteActionsEnabled(): Boolean = false
"""
        repository = """
class DsmRepository {
    suspend fun deleteResult(paths: List<String>): MutationResult = TODO()
}
"""
        errors = MODULE.validate_workspace_routing(source, repository, "")
        self.assertTrue(any("必须人工复核" in error for error in errors))

    def test_rejects_legacy_flat_nas_settings_coordinator(self):
        source = """
class AppViewModel {
    fun save() = nasSettingsMutation { repo -> repo.saveResult() }
    private fun nasSettingsMutation(block: suspend (DsmRepository) -> MutationResult) = Unit
}
"""
        repository = """
class DsmRepository {
    suspend fun saveResult(): MutationResult = TODO()
}
"""
        errors = MODULE.validate_workspace_routing(source, repository, "")
        self.assertTrue(any("必须人工复核" in error for error in errors))

    def test_rejects_legacy_non_result_server_write(self):
        source = """
class AppViewModel {
    fun deleteFile() {
        _workspace.update { it?.copy(fileStationMutationResult = null) }
        repo.delete(listOf("/demo"))
    }
}
"""
        repository = """
class DsmRepository {
    suspend fun delete(paths: List<String>) = Unit
    suspend fun deleteResult(paths: List<String>): MutationResult = TODO()
}
"""
        errors = MODULE.validate_workspace_routing(source, repository, "")
        self.assertTrue(any("必须改用 deleteResult" in error for error in errors))

    def test_rejects_result_call_that_bypasses_workspace_coordinator(self):
        source = """
class AppViewModel {
    fun deleteFile() {
        repo.deleteResult(listOf("/demo"))
    }
}
"""
        repository = """
class DsmRepository {
    suspend fun deleteResult(paths: List<String>): MutationResult = TODO()
}
"""
        errors = MODULE.validate_workspace_routing(source, repository, "")
        self.assertTrue(any("必须人工复核" in error for error in errors))

    def test_expression_and_block_returns_require_audited_fingerprint(self):
        repository = """
class DsmRepository {
    suspend fun deleteResult(): MutationResult = TODO()
}
"""
        for source in (
            "class AppViewModel { fun unsafe(repo: DsmRepository) = repo.deleteResult() }",
            """
class AppViewModel {
    fun unsafe(repo: DsmRepository): MutationResult {
        return repo.deleteResult()
    }
}
""",
        ):
            errors = MODULE.validate_workspace_routing(source, repository, "")
            self.assertTrue(any("必须人工复核" in error for error in errors))

    def test_await_without_persistent_result_requires_audited_fingerprint(self):
        source = """
class AppViewModel {
    fun unsafe(repo: DsmRepository) {
        val result = async { repo.deleteResult() }
        result.await()
    }
}
"""
        repository = """
class DsmRepository {
    suspend fun deleteResult(): MutationResult = TODO()
}
"""
        errors = MODULE.validate_workspace_routing(source, repository, "")
        self.assertTrue(any("必须人工复核" in error for error in errors))

    def test_inline_method_reference_requires_audited_fingerprint(self):
        source = "class AppViewModel { fun unsafe(repo: DsmRepository) = runWrite(repo::deleteResult) }"
        repository = """
class DsmRepository {
    suspend fun deleteResult(): MutationResult = TODO()
}
"""
        errors = MODULE.validate_workspace_routing(source, repository, "")
        self.assertTrue(any("必须人工复核" in error for error in errors))

    def test_new_worker_result_call_requires_audited_fingerprint(self):
        worker = "class NewWorker { fun run(repo: DsmRepository) = repo.deleteResult() }"
        repository = """
class DsmRepository {
    suspend fun deleteResult(): MutationResult = TODO()
}
"""
        errors = MODULE.validate_workspace_routing(
            "class AppViewModel {}",
            repository,
            "",
            additional_sources=(worker,),
        )
        self.assertTrue(any("必须人工复核" in error for error in errors))

    def test_internal_result_declaration_cannot_bypass_audit(self):
        source = "class AppViewModel { fun run(repo: DsmRepository) = repo.newWriteResult() }"
        repository = """
class DsmRepository {
    internal suspend fun newWriteResult(): MutationResult = TODO()
}
"""
        errors = MODULE.validate_workspace_routing(source, repository, "")
        self.assertTrue(any("必须人工复核" in error for error in errors))

    def test_same_named_local_call_is_reported_as_suspicious_not_server_fact(self):
        source = "class AppViewModel { fun parse(parser: LocalParser) = parser.deleteResult() }"
        repository = """
class DsmRepository {
    suspend fun deleteResult(): MutationResult = TODO()
}
"""
        errors = MODULE.validate_workspace_routing(source, repository, "")
        self.assertTrue(any("必须人工复核" in error for error in errors))
        self.assertFalse(any("服务端" in error for error in errors))

    def test_unrelated_persistent_state_does_not_consume_result(self):
        source = """
class AppViewModel {
    fun deleteFile(repo: DsmRepository) {
        val ignored = repo.deleteResult(listOf("/demo"))
        _workspace.update {
            it?.copy(fileStationMutationResult = previousResult)
        }
    }
}
"""
        repository = """
class DsmRepository {
    suspend fun deleteResult(paths: List<String>): MutationResult = TODO()
}
"""
        errors = MODULE.validate_workspace_routing(source, repository, "")
        self.assertTrue(any("必须人工复核" in error for error in errors))

    def test_repository_alias_and_method_reference_must_reach_result_sink(self):
        source = """
class AppViewModel {
    fun deleteFile(backend: DsmRepository) {
        val writer = backend::deleteResult
        val result = writer(listOf("/demo"))
        _workspace.update {
            it?.copy(fileStationMutationResult = result)
        }
    }
}
"""
        repository = """
class DsmRepository {
    suspend fun deleteResult(paths: List<String>): MutationResult = TODO()
}
"""
        self.assertTrue(
            any("必须人工复核" in error for error in
                MODULE.validate_workspace_routing(source, repository, ""))
        )

    def test_cross_nas_result_pipeline_is_scanned(self):
        source = """
class AppViewModel {
    fun copy() = fileStationMutation { repo -> repo.copyResult() }
}
"""
        cross_nas = """
class CrossNasTransferCoordinator {
    private suspend fun transferItem(target: CrossNasTransferEndpoint): MutationResult {
        val created = target.createFolderResult()
        if (created.status != MutationResultStatus.CONFIRMED_SUCCESS) return created
        return created
    }
}
"""
        repository = """
class DsmRepository {
    suspend fun copyResult(): MutationResult = TODO()
    suspend fun createFolderResult(): MutationResult = TODO()
}
"""
        self.assertTrue(any(
            "必须人工复核" in error
            for error in MODULE.validate_workspace_routing(
                source,
                repository,
                "",
                additional_sources=(cross_nas,),
            )
        ))

    def test_cross_nas_discarded_result_is_rejected(self):
        source = "class AppViewModel {}"
        cross_nas = """
class CrossNasTransferCoordinator {
    private suspend fun transferItem(target: CrossNasTransferEndpoint): MutationResult {
        target.createFolderResult()
        return fallbackResult()
    }
}
"""
        repository = """
class DsmRepository {
    suspend fun createFolderResult(): MutationResult = TODO()
}
"""
        errors = MODULE.validate_workspace_routing(
            source,
            repository,
            "",
            additional_sources=(cross_nas,),
        )
        self.assertTrue(any("必须人工复核" in error for error in errors))

    def test_same_named_endpoint_declaration_is_not_a_repository_call(self):
        source = """
class AppViewModel {
    override suspend fun uploadResult(source: UploadSource): MutationResult = result(source)
}
"""
        repository = """
class DsmRepository {
    suspend fun uploadResult(source: UploadSource): MutationResult = TODO()
}
"""
        self.assertEqual(MODULE.validate_workspace_routing(source, repository, ""), [])

    def test_current_production_workspace_routing_passes(self):
        self.assertEqual(MODULE.validate_workspace_routing(), [])

    def test_allows_fixed_closed_container_without_ui_entry(self):
        source = """
class AppViewModel {
    fun deleteContainer(id: String) = containerMutation { repo ->
        repo.deleteContainerResult(id)
    }
    private fun containerMutation(block: suspend (DsmRepository) -> MutationResult) {
        if (!containerWriteActionsEnabled()) return
        val repo = repository ?: return
    }
}
internal fun containerWriteActionsEnabled(): Boolean = false
"""
        repository = """
class DsmRepository {
    suspend fun deleteContainerResult(id: String): MutationResult = TODO()
}
"""
        self.assertEqual(
            MODULE.validate_workspace_routing(source, repository, ""),
            [],
        )

    def test_container_ui_entry_revokes_fixed_closed_exception(self):
        source = """
class AppViewModel {
    fun deleteContainer(id: String) = containerMutation { repo ->
        repo.deleteContainerResult(id)
    }
    private fun containerMutation(block: suspend (DsmRepository) -> MutationResult) {
        if (!containerWriteActionsEnabled()) return
        val repo = repository ?: return
    }
}
internal fun containerWriteActionsEnabled(): Boolean = false
"""
        repository = """
class DsmRepository {
    suspend fun deleteContainerResult(id: String): MutationResult = TODO()
}
"""
        errors = MODULE.validate_workspace_routing(
            source,
            repository,
            "Button(onClick = { model.deleteContainer(id) })",
        )
        self.assertTrue(any("必须人工复核" in error for error in errors))

    def test_unregistered_result_still_fails_matrix(self):
        row = self.row("saveResult", state="closed", zero="gap")
        errors = MODULE.validate({"saveResult", "deleteResult"}, [row])
        self.assertTrue(any("生产写入口未进入矩阵：deleteResult" == error for error in errors))

    def test_unregistered_method_reference_still_fails_matrix(self):
        calls = MODULE.production_result_calls("val writer = repository::deleteResult")
        self.assertEqual(calls, {"deleteResult"})
        errors = MODULE.validate(calls, [])
        self.assertIn("生产写入口未进入矩阵：deleteResult", errors)

    def test_rejects_unlisted_and_duplicate_calls(self):
        rows = [
            self.row("saveResult", state="closed", zero="gap"),
            self.row("saveResult", state="closed", zero="gap"),
        ]
        errors = MODULE.validate({"saveResult", "deleteResult"}, rows)
        self.assertTrue(any("deleteResult" in error for error in errors))
        self.assertTrue(any("当前 2 次" in error for error in errors))

    def test_open_multi_operation_requires_partial_success(self):
        row = self.row(
            "saveResult",
            multi=True,
            pre="gap",
            success="gap",
            disconnect="gap",
            readback="gap",
            cancel="gap",
            partial="gap",
        )
        errors = MODULE.validate({"saveResult"}, [row])
        self.assertTrue(any("partial" in error for error in errors))

    def test_pending_row_reports_exact_missing_scenarios(self):
        row = self.row(
            "saveResult",
            state="pending",
            pre="gap",
            success="na",
            disconnect="gap",
            readback="na",
            cancel="gap",
        )
        errors = MODULE.validate({"saveResult"}, [row])
        self.assertIn(
            "待补测试：saveResult -> pre,disconnect,cancel",
            errors,
        )

    def test_evidence_must_point_to_existing_test_name(self):
        with tempfile.TemporaryDirectory() as directory:
            original = MODULE.TEST_ROOT
            try:
                MODULE.TEST_ROOT = Path(directory)
                path = Path(directory) / "SampleTest.kt"
                path.write_text("fun `可复验场景`() {}", encoding="utf-8")
                self.assertIsNone(MODULE._validate_evidence("SampleTest.kt::可复验场景"))
                self.assertIn(
                    "测试证据名称不存在",
                    MODULE._validate_evidence("SampleTest.kt::不存在"),
                )
            finally:
                MODULE.TEST_ROOT = original


if __name__ == "__main__":
    unittest.main()

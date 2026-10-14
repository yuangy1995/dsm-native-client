package io.github.qwertyuiop1995.dsmnativeclient

import androidx.compose.runtime.mutableStateOf
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.*

/** 页面测试只注入合成领域状态，使用产品的同一 Content 与表单，不启动网络或根模型。 */
internal class NasServiceUiFixture(snapshot: NasSettingsSnapshot, drafts: List<NasServiceValue> = emptyList()) {
    val states = mutableStateOf(NasServiceKind.entries.associateWith { kind ->
        val current = when (kind) {
            NasServiceKind.FILES -> snapshot.fileServiceSettings?.let(NasServiceValue::Files)
            NasServiceKind.TERMINAL -> snapshot.terminalSettings?.let(NasServiceValue::Terminal)
            NasServiceKind.PROXY -> snapshot.proxySettings?.let(NasServiceValue::Proxy)
            else -> null
        }
        NasServiceEditorState(current = current, loaded = true, original = current, draft = drafts.singleOrNull { it.kind == kind })
    })
    fun begin(value: NasServiceValue): Boolean {
        val old = states.value.getValue(value.kind)
        if (old.blocked) return false
        states.value = states.value + (value.kind to old.copy(original = value, draft = old.draft ?: value)); return true
    }
    fun draft(kind: NasServiceKind, value: NasServiceValue?) {
        states.value = states.value + (kind to states.value.getValue(kind).copy(draft = value))
    }
}
internal class NasRegionUiFixture(current: NasRegionSettings?, draft: NasRegionSettings?) {
    val state = mutableStateOf(NasRegionEditorState(current = current, original = current, draft = draft))
    fun begin(): Boolean {
        val value = state.value
        if (value.blocked || value.current == null) return false
        state.value = value.copy(original = value.current, draft = value.draft ?: value.current); return true
    }
    fun draft(value: NasRegionSettings?) { state.value = state.value.copy(draft = value) }
}

package io.github.qwertyuiop1995.dsmnativeclient.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import io.github.qwertyuiop1995.dsmnativeclient.FileStationMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.FileStationMutationTarget
import io.github.qwertyuiop1995.dsmnativeclient.FileStationMutationVerification
import io.github.qwertyuiop1995.dsmnativeclient.FileStationMutationWorkspaceState
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.canContinueEditingFileStationMutation
import io.github.qwertyuiop1995.dsmnativeclient.destructiveServiceMutationRequiresRefreshBeforeDismiss
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.fileCopyMoveMessageResource
import io.github.qwertyuiop1995.dsmnativeclient.fileEntryMutationMessageResource
import io.github.qwertyuiop1995.dsmnativeclient.fileRestoreMessageResource
import io.github.qwertyuiop1995.dsmnativeclient.fileStationFavoriteBatchMessageResource
import io.github.qwertyuiop1995.dsmnativeclient.fileStationFavoriteMessageResource
import io.github.qwertyuiop1995.dsmnativeclient.localization.localize
import io.github.qwertyuiop1995.dsmnativeclient.shareLinkDeleteMessageResource
import io.github.qwertyuiop1995.dsmnativeclient.shareLinkMutationMessageResource
import io.github.qwertyuiop1995.dsmnativeclient.textSaveMutationMessageResource

internal data class FileStationMutationFeedbackPolicy(
    @StringRes val title: Int,
    val assertive: Boolean,
)

internal fun fileStationMutationFeedbackPolicy(
    result: MutationResult,
): FileStationMutationFeedbackPolicy = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> FileStationMutationFeedbackPolicy(
        R.string.file_mutation_feedback_confirmed_title,
        false,
    )
    MutationResultStatus.PARTIAL_SUCCESS -> FileStationMutationFeedbackPolicy(
        R.string.file_mutation_feedback_partial_title,
        true,
    )
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> FileStationMutationFeedbackPolicy(R.string.file_mutation_feedback_check_title, true)
    MutationResultStatus.PERMISSION_DENIED -> FileStationMutationFeedbackPolicy(
        R.string.file_mutation_feedback_permission_title,
        true,
    )
    MutationResultStatus.UNSUPPORTED -> FileStationMutationFeedbackPolicy(
        R.string.file_mutation_feedback_unavailable_title,
        true,
    )
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> FileStationMutationFeedbackPolicy(
        R.string.file_mutation_feedback_cancelled_title,
        true,
    )
    MutationResultStatus.CONFIRMED_FAILURE -> FileStationMutationFeedbackPolicy(
        if (result.errorCategory == MutationErrorCategory.CONFLICT) {
            R.string.file_mutation_feedback_conflict_title
        } else R.string.file_mutation_feedback_failed_title,
        true,
    )
}

internal fun fileStationMutationRequiresRefresh(
    state: FileStationMutationWorkspaceState,
): Boolean = state.mutationFailure != null || state.mutationRefreshFailure != null ||
    state.mutationResult?.let(::destructiveServiceMutationRequiresRefreshBeforeDismiss) == true

internal fun canDismissFileStationMutationFeedback(
    state: FileStationMutationWorkspaceState,
): Boolean = state.target != null && !state.mutationInProgress &&
    !state.mutationRefreshInProgress &&
    (!fileStationMutationRequiresRefresh(state) || state.mutationRefreshCompleted)

internal fun canContinueEditingFileStationMutationFeedback(
    state: FileStationMutationWorkspaceState,
): Boolean = state.target?.operation in setOf(
    FileStationMutationOperation.TEXT_SAVE,
    FileStationMutationOperation.CREATE_FOLDER,
    FileStationMutationOperation.RENAME,
    FileStationMutationOperation.COPY,
    FileStationMutationOperation.MOVE,
    FileStationMutationOperation.DELETE,
) && canContinueEditingFileStationMutation(state)

@Composable
internal fun FileStationNameEditorDialog(
    state: FileStationMutationWorkspaceState,
    onDraftChange: (String) -> Boolean,
    onConfirm: () -> Boolean,
    onDismiss: () -> Boolean,
) {
    val source = state.editorSourceBaseline
    val createFolder = source == null
    val cleanName = state.nameDraft.trim()
    val invalidCharacters = cleanName in setOf(".", "..") ||
        cleanName.any { it == '/' || it == '\\' || it.isISOControl() }
    val unchanged = source != null && cleanName == source.name
    val error = when {
        cleanName.isEmpty() -> if (createFolder) R.string.folder_name_required else R.string.file_name_required
        invalidCharacters -> if (createFolder) R.string.folder_name_invalid else R.string.file_name_invalid
        unchanged -> R.string.file_name_unchanged
        else -> null
    }
    AlertDialog(
        modifier = Modifier.imePadding(),
        onDismissRequest = { onDismiss() },
        title = {
            Text(stringResource(if (createFolder) R.string.new_folder else R.string.rename))
        },
        text = {
            Column(
                Modifier
                    .fillMaxWidth()
                    .heightIn(max = 420.dp)
                    .verticalScroll(rememberScrollState()),
            ) {
                OutlinedTextField(
                    value = state.nameDraft,
                    onValueChange = { onDraftChange(it) },
                    singleLine = true,
                    isError = error != null,
                    label = {
                        Text(stringResource(if (createFolder) R.string.folder_name else R.string.new_name))
                    },
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(
                        onDone = { if (error == null) onConfirm() },
                    ),
                    supportingText = error?.let { message ->
                        {
                            Text(
                                stringResource(message),
                                modifier = Modifier.semantics {
                                    liveRegion = LiveRegionMode.Assertive
                                },
                            )
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm() },
                enabled = error == null,
                modifier = Modifier.heightIn(min = 48.dp).semantics { role = Role.Button },
            ) {
                Text(stringResource(if (createFolder) R.string.create else R.string.save))
            }
        },
        dismissButton = {
            TextButton(
                onClick = { onDismiss() },
                modifier = Modifier.heightIn(min = 48.dp).semantics { role = Role.Button },
            ) { Text(stringResource(R.string.cancel)) }
        },
    )
}

@Composable
internal fun FileStationMutationConfirmationDialog(
    target: FileStationMutationTarget,
    onConfirm: () -> Boolean,
    onDismiss: () -> Boolean,
) {
    val sourceName = target.sourceBaselines.singleOrNull()?.name.orEmpty()
    val destinationName = target.destinationPath?.substringAfterLast('/')?.ifBlank {
        stringResource(R.string.shared_folders)
    }.orEmpty()
    val title = when (target.operation) {
        FileStationMutationOperation.TEXT_SAVE -> stringResource(R.string.save_text_changes_title)
        FileStationMutationOperation.COPY -> stringResource(R.string.confirm_copy_files)
        FileStationMutationOperation.MOVE -> stringResource(
            if (target.module == Module.PHOTOS) R.string.confirm_move_photo
            else R.string.confirm_move_files,
        )
        FileStationMutationOperation.DELETE -> if (
            target.module == Module.FILES && target.sourceBaselines.size > 1
        ) {
            stringResource(R.string.delete_selected_items)
        } else {
            stringResource(R.string.delete_named_item, sourceName)
        }
        FileStationMutationOperation.RESTORE -> stringResource(R.string.restore_from_recycle_bin)
        FileStationMutationOperation.SHARE_CREATE -> stringResource(R.string.create_share_link)
        FileStationMutationOperation.SHARE_DELETE -> stringResource(R.string.delete_share_link)
        else -> return
    }
    val message = when (target.operation) {
        FileStationMutationOperation.TEXT_SAVE -> stringResource(R.string.save_text_changes_message)
        FileStationMutationOperation.COPY -> stringResource(
            R.string.confirm_copy_files_message,
            target.sourceBaselines.size,
            destinationName,
        )
        FileStationMutationOperation.MOVE -> if (target.module == Module.PHOTOS) {
            stringResource(R.string.confirm_move_photo_message, sourceName, destinationName)
        } else {
            stringResource(
                R.string.confirm_move_files_message,
                target.sourceBaselines.size,
                destinationName,
            )
        }
        FileStationMutationOperation.DELETE -> when {
            target.module == Module.FILES && target.sourceBaselines.size > 1 -> stringResource(
                R.string.delete_selected_items_message,
                target.sourceBaselines.size,
            )
            target.module == Module.FILES &&
                target.sourceBaselines.single().path.split('/').contains("#recycle") ->
                stringResource(R.string.delete_permanently_note)
            else -> stringResource(R.string.delete_recycle_note)
        }
        FileStationMutationOperation.RESTORE -> stringResource(R.string.restore_file_message, sourceName)
        FileStationMutationOperation.SHARE_CREATE ->
            stringResource(R.string.create_share_link_message, sourceName)
        FileStationMutationOperation.SHARE_DELETE -> {
            val link = target.shareLinkBaselines.first()
            if (target.shareLinkBaselines.size > 1) stringResource(R.string.file_share_delete_many_confirmation,
                target.shareLinkBaselines.size, target.shareLinkBaselines.joinToString("\n") { it.name })
            else stringResource(
                R.string.delete_share_link_confirmation,
                link.name.ifBlank { stringResource(R.string.share_link_unnamed) },
            )
        }
        else -> return
    }
    val confirm = when (target.operation) {
        FileStationMutationOperation.TEXT_SAVE -> R.string.replace_existing
        FileStationMutationOperation.COPY -> R.string.copy_action
        FileStationMutationOperation.MOVE -> R.string.move_action
        FileStationMutationOperation.DELETE -> R.string.delete
        FileStationMutationOperation.RESTORE -> R.string.restore_from_recycle_bin
        FileStationMutationOperation.SHARE_CREATE -> R.string.create_share_link
        FileStationMutationOperation.SHARE_DELETE -> R.string.delete_share_link
        else -> return
    }
    AlertDialog(
        onDismissRequest = { onDismiss() },
        title = { Text(title) },
        text = {
            Text(
                message,
                modifier = Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState()),
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm() },
                colors = if (
                    target.operation in setOf(
                        FileStationMutationOperation.DELETE,
                        FileStationMutationOperation.SHARE_DELETE,
                    )
                ) {
                    ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
                } else {
                    ButtonDefaults.textButtonColors()
                },
                modifier = Modifier.heightIn(min = 48.dp).semantics { role = Role.Button },
            ) { Text(stringResource(confirm)) }
        },
        dismissButton = {
            TextButton(
                onClick = { onDismiss() },
                modifier = Modifier.heightIn(min = 48.dp).semantics { role = Role.Button },
            ) { Text(stringResource(R.string.cancel)) }
        },
    )
}

@Composable
internal fun FileStationMutationFeedbackDialog(
    state: FileStationMutationWorkspaceState,
    onRefresh: () -> Boolean,
    onContinueEditing: () -> Boolean,
    onDismiss: () -> Boolean,
) {
    val canDismiss = canDismissFileStationMutationFeedback(state)
    val canContinue = canContinueEditingFileStationMutationFeedback(state)
    AlertDialog(
        onDismissRequest = { if (canDismiss) onDismiss() },
        title = {
            Text(
                stringResource(
                    when {
                        state.mutationInProgress -> R.string.file_mutation_in_progress_title
                        state.mutationFailure != null -> R.string.file_mutation_feedback_failed_title
                        else -> fileStationMutationFeedbackPolicy(checkNotNull(state.mutationResult)).title
                    },
                ),
            )
        },
        text = { FileStationMutationFeedbackCard(state) },
        dismissButton = {
            Column {
                if (canContinue) TextButton(
                    onClick = { onContinueEditing() },
                    modifier = Modifier.heightIn(min = 48.dp).semantics { role = Role.Button },
                ) { Text(stringResource(R.string.continue_editing_file_mutation)) }
                if (fileStationMutationRequiresRefresh(state) && !canDismiss) TextButton(
                    onClick = { onRefresh() },
                    enabled = !state.mutationInProgress && !state.mutationRefreshInProgress,
                    modifier = Modifier.heightIn(min = 48.dp).semantics { role = Role.Button },
                ) { Text(stringResource(R.string.refresh_and_check_files)) }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onDismiss() },
                enabled = canDismiss,
                modifier = Modifier.heightIn(min = 48.dp).semantics { role = Role.Button },
            ) {
                Text(
                    stringResource(
                        if (fileStationMutationRequiresRefresh(state)) {
                            R.string.close_checked_file_mutation
                        } else R.string.close,
                    ),
                )
            }
        },
    )
}

@Composable
internal fun FileStationMutationFeedbackCard(state: FileStationMutationWorkspaceState) {
    val policy = state.mutationResult?.let(::fileStationMutationFeedbackPolicy)
    val assertiveVerification = state.mutationVerification != null &&
        state.mutationVerification != FileStationMutationVerification.MATCHES
    val liveRegionMode = if (
        state.mutationFailure != null || state.mutationRefreshFailure != null ||
        policy?.assertive == true || assertiveVerification
    ) LiveRegionMode.Assertive else LiveRegionMode.Polite
    Card(Modifier.fillMaxWidth().semantics { liveRegion = liveRegionMode }) {
        Column(
            Modifier
                .fillMaxWidth()
                .heightIn(max = 360.dp)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            when {
                state.mutationInProgress -> {
                    Text(stringResource(R.string.file_mutation_in_progress_message))
                    LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 12.dp))
                }
                state.mutationFailure != null -> Text(
                    state.mutationFailure.localize(LocalContext.current).combined,
                )
                state.mutationResult != null && state.target != null -> Text(
                    fileStationMutationMessage(state.target, state.mutationResult),
                )
            }
            state.mutationResult?.counts?.let { counts ->
                Text(
                    stringResource(
                        R.string.file_mutation_counts,
                        counts.succeeded,
                        counts.failed,
                        counts.unknown,
                    ),
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
            if (state.mutationRefreshInProgress) {
                Text(stringResource(R.string.file_mutation_refreshing), Modifier.padding(top = 12.dp))
                LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 8.dp))
            }
            state.mutationRefreshFailure?.let { failure ->
                Text(failure.localize(LocalContext.current).combined, Modifier.padding(top = 12.dp))
            }
            state.mutationVerification?.let { verification ->
                Text(stringResource(verification.messageResource()), Modifier.padding(top = 12.dp))
            }
        }
    }
}

@Composable
private fun fileStationMutationMessage(
    target: FileStationMutationTarget,
    result: MutationResult,
): String = when {
    target.operation == FileStationMutationOperation.DELETE &&
        target.module == Module.FILES &&
        result.status == MutationResultStatus.CONFIRMED_SUCCESS -> stringResource(
            R.string.file_delete_confirmed,
            result.counts.succeeded,
        )
    target.operation == FileStationMutationOperation.DELETE &&
        target.module == Module.FILES &&
        result.status == MutationResultStatus.PARTIAL_SUCCESS -> stringResource(
            R.string.file_delete_partial,
            result.counts.succeeded,
            result.counts.failed + result.counts.unknown,
        )
    target.operation == FileStationMutationOperation.DELETE &&
        target.module == Module.PHOTOS &&
        result.status == MutationResultStatus.PARTIAL_SUCCESS -> stringResource(
            R.string.photo_delete_partial,
            result.counts.succeeded,
            result.counts.failed + result.counts.unknown,
        )
    else -> stringResource(fileStationMutationMessageResource(target, result))
}

@StringRes
private fun fileStationMutationMessageResource(
    target: FileStationMutationTarget,
    result: MutationResult,
): Int = when (target.operation) {
    FileStationMutationOperation.TEXT_SAVE -> textSaveMutationMessageResource(result)
    FileStationMutationOperation.CREATE_FOLDER,
    FileStationMutationOperation.RENAME,
    -> fileEntryMutationMessageResource(result)
    FileStationMutationOperation.FAVORITE_ADD_BATCH -> fileStationFavoriteBatchMessageResource(result)
    FileStationMutationOperation.FAVORITE_ADD -> fileStationFavoriteMessageResource(result)
    FileStationMutationOperation.FAVORITE_REMOVE -> favoriteRemoveMessageResource(result)
    FileStationMutationOperation.COPY,
    FileStationMutationOperation.MOVE,
    -> fileCopyMoveMessageResource(result)
    FileStationMutationOperation.DELETE -> if (target.module == Module.PHOTOS) {
        photoDeleteMessageResource(result)
    } else {
        fileDeleteMessageResource(result)
    }
    FileStationMutationOperation.RESTORE -> fileRestoreMessageResource(result)
    FileStationMutationOperation.SHARE_CREATE -> shareLinkMutationMessageResource(result)
    FileStationMutationOperation.SHARE_DELETE -> shareLinkDeleteMessageResource(result)
}

@StringRes
private fun photoDeleteMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.photo_deleted
    MutationResultStatus.PARTIAL_SUCCESS -> R.string.photo_delete_partial
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.photo_delete_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.photo_delete_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.photo_delete_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.photo_delete_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.photo_delete_in_progress
    } else {
        R.string.photo_delete_failed
    }
}

@StringRes
private fun fileDeleteMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.file_delete_confirmed
    MutationResultStatus.PARTIAL_SUCCESS -> R.string.file_delete_partial
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.file_delete_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.file_delete_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.file_delete_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.file_delete_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) {
        R.string.file_delete_in_progress
    } else {
        R.string.file_delete_failed
    }
}

@StringRes
private fun favoriteRemoveMessageResource(result: MutationResult): Int = when (result.status) {
    MutationResultStatus.CONFIRMED_SUCCESS -> R.string.favorite_removed
    MutationResultStatus.PARTIAL_SUCCESS,
    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
    -> R.string.favorite_remove_unverified
    MutationResultStatus.PERMISSION_DENIED -> R.string.favorite_remove_permission_denied
    MutationResultStatus.UNSUPPORTED -> R.string.favorite_remove_unsupported
    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> R.string.favorite_remove_cancelled
    MutationResultStatus.CONFIRMED_FAILURE -> if (
        result.errorCategory == MutationErrorCategory.CONFLICT
    ) R.string.favorite_remove_conflict else R.string.favorite_remove_failed
}

@StringRes
private fun FileStationMutationVerification.messageResource(): Int = when (this) {
    FileStationMutationVerification.MATCHES -> R.string.file_mutation_refresh_matches
    FileStationMutationVerification.DIFFERS -> R.string.file_mutation_refresh_differs
    FileStationMutationVerification.DISAPPEARED -> R.string.file_mutation_refresh_disappeared
    FileStationMutationVerification.UNAVAILABLE -> R.string.file_mutation_refresh_unavailable
}

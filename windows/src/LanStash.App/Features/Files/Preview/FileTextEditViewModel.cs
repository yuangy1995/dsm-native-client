using System.IO;
using System.Text;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Preview;

public sealed class FileTextEditViewModel : ObservableObject, IDisposable
{
    private IFilePreviewRepository? _repository;
    private string _originalText = string.Empty;
    private FileTextContentSnapshot? _originalSnapshot;
    private string _editableText = string.Empty;
    private string _filePath = string.Empty;
    private string _itemName = string.Empty;
    private long _itemSize;
    private bool _canEdit;
    private TextFormatKind? _formatKind;
    private bool _busy;
    private bool _disposed;
    private int _generation;
    private string _saveMessage = string.Empty;
    private FileTextEditState _state = FileTextEditState.Viewing;

    public FileTextEditState State => _state;
    public int Generation => _generation;
    public string ItemName => _itemName;
    public string SaveMessage => _saveMessage;
    public bool CanEdit => _canEdit && !_busy;
    public bool CanFormat => _formatKind is not null && CanChangeText;
    public bool CanChangeText => !_busy && State is FileTextEditState.Editing or FileTextEditState.SaveFailed;
    public bool HasUnsavedChanges => _originalSnapshot is not null &&
        !string.Equals(_editableText, _originalText, StringComparison.Ordinal);
    public bool IsViewing => State is FileTextEditState.Viewing or FileTextEditState.SaveCompleted;
    public bool IsEditing => !IsViewing;
    public bool IsBusy => _busy;
    public bool IsSavingIndicator => State == FileTextEditState.Saving;
    public bool IsSaveCompleted => State == FileTextEditState.SaveCompleted;
    public bool IsSaveNeedsReview => State == FileTextEditState.SaveNeedsReview;
    public bool IsSaveFailed => State == FileTextEditState.SaveFailed;
    public bool CanSubmitSave => CanChangeText && HasUnsavedChanges;
    public bool CanReview => IsSaveNeedsReview && !_busy;
    public bool ShowSaveStatus => _saveMessage.Length != 0 || !IsViewing;
    public string? SavedText { get; private set; }
    public string EditableText
    {
        get => _editableText;
        set
        {
            if (!CanChangeText || value == _editableText) return;
            _editableText = value ?? string.Empty;
            if (IsSaveFailed) _state = FileTextEditState.Editing;
            _saveMessage = string.Empty;
            Notify();
        }
    }

    public void Attach(IFilePreviewRepository repository, FileItem item, bool editableLocation = true)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(item);
        _generation++;
        _repository = repository;
        _filePath = item.Path;
        _itemName = item.Name;
        _itemSize = item.Size;
        var extension = Path.GetExtension(item.Name).TrimStart('.');
        var availability = repository.GetTextEditAvailability();
        // 列表 write 标记不等同于覆盖权限；保存时由目录权限探测和上传拒绝共同判定。
        _canEdit = availability.CanEdit && editableLocation && !item.IsDirectory && item.Size >= 0 && item.Size <= 5L * 1024 * 1024 &&
            FileTextEditClassification.CanEditSelectedText(extension);
        _formatKind = availability.CanFormat && FileTextEditClassification.CanFormatSelectedText(extension)
            ? FileTextEditClassification.FormatKindForExtension(extension) : null;
        _originalSnapshot = null;
        _originalText = _editableText = _saveMessage = string.Empty;
        SavedText = null;
        _busy = false;
        _state = FileTextEditState.Viewing;
        Notify();
    }

    public async Task<bool> EnterEditModeAsync(CancellationToken cancellationToken = default)
    {
        if (_disposed || !CanEdit || !IsViewing || _repository is not { } repository) return false;
        var generation = _generation;
        var path = _filePath;
        _busy = true;
        _saveMessage = string.Empty;
        Notify();
        try
        {
            var snapshot = await repository.DownloadTextContentSnapshotAsync(path, _itemSize,
                5L * 1024 * 1024, cancellationToken);
            var pending = await repository.ReviewTextContentSaveAsync(path, cancellationToken);
            if (!Current(generation)) return false;
            _originalSnapshot = snapshot;
            _originalText = _editableText = snapshot.Text;
            SavedText = snapshot.Text;
            _state = pending?.Submitted == true && pending.Status != MutationResultStatus.ConfirmedSuccess
                ? FileTextEditState.SaveNeedsReview : FileTextEditState.Editing;
            return true;
        }
        catch
        {
            if (Current(generation)) _saveMessage = "FileTextEdit_OpenFailed";
            return false;
        }
        finally { if (Current(generation)) { _busy = false; Notify(); } }
    }

    public void CancelEdit()
    {
        if (_disposed || _busy) return;
        _generation++;
        _editableText = _originalText;
        _state = FileTextEditState.Viewing;
        _saveMessage = string.Empty;
        Notify();
    }

    public async Task SaveAsync(CancellationToken cancellationToken = default)
    {
        if (_disposed || !CanSubmitSave || _repository is not { } repository || _originalSnapshot is not { } original) return;
        var generation = _generation;
        var path = _filePath;
        var content = _editableText;
        _busy = true;
        _state = FileTextEditState.Saving;
        _saveMessage = string.Empty;
        Notify();
        try
        {
            var result = await repository.SaveTextContentAsync(path, content, original, cancellationToken);
            if (Current(generation)) ApplySaveResult(result, content);
        }
        catch
        {
            // 调用已开始，意外异常不能使重复覆盖重新开放。
            if (Current(generation)) _state = FileTextEditState.SaveNeedsReview;
        }
        finally { if (Current(generation)) { _busy = false; Notify(); } }
    }

    public async Task ReviewAsync(CancellationToken cancellationToken = default)
    {
        if (_disposed || !CanReview || _repository is not { } repository) return;
        var generation = _generation;
        var content = _editableText;
        _busy = true;
        Notify();
        try
        {
            var result = await repository.ReviewTextContentSaveAsync(_filePath, cancellationToken);
            if (Current(generation) && result is not null) ApplySaveResult(result, content);
        }
        catch { /* 查询失败保留草稿及防重状态。 */ }
        finally { if (Current(generation)) { _busy = false; Notify(); } }
    }

    private void ApplySaveResult(MutationResult result, string content)
    {
        if (result.Status == MutationResultStatus.ConfirmedSuccess)
        {
            _originalText = _editableText = content;
            _itemSize = Encoding.UTF8.GetByteCount(content);
            SavedText = content;
            _originalSnapshot = null;
            _state = FileTextEditState.SaveCompleted;
            _saveMessage = string.Empty;
        }
        else if (result.Status is MutationResultStatus.SubmittedButUnverified or
            MutationResultStatus.CancellationRequestedAfterSubmission)
            _state = FileTextEditState.SaveNeedsReview;
        else
        {
            _state = FileTextEditState.SaveFailed;
            _saveMessage = result.ErrorCategory switch
            {
                MutationErrorCategory.Permission => "FileTextEdit_PermissionFailed",
                MutationErrorCategory.Conflict => "FileTextEdit_ConflictMessage",
                MutationErrorCategory.Validation => "FileTextEdit_TooLargeMessage",
                _ => "FileTextEdit_SaveFailedMessage",
            };
        }
    }

    public async Task FormatAsync()
    {
        if (_disposed || !CanFormat || _repository is not { } repository || _formatKind is not { } kind) return;
        var generation = _generation;
        var content = _editableText;
        _busy = true;
        Notify();
        try
        {
            var formatted = await repository.FormatTextContentAsync(content, kind);
            if (!Current(generation)) return;
            _editableText = formatted;
            _state = FileTextEditState.Editing;
            _saveMessage = string.Empty;
        }
        catch { if (Current(generation)) _saveMessage = "FileTextEdit_FormatFailed"; }
        finally { if (Current(generation)) { _busy = false; Notify(); } }
    }

    public bool RequestClose() => !_busy && !HasUnsavedChanges;
    private bool Current(int generation) => !_disposed && generation == _generation;
    private void Notify() => RaisePropertyChanged(string.Empty);
    public void Dispose() { _generation++; _disposed = true; _repository = null; }
}

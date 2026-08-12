using System.IO;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Preview;

public sealed class FileTextEditViewModel : ObservableObject, IDisposable
{
    private IFilePreviewRepository? _repository;
    private string _originalText = string.Empty;
    private FileTextContentSnapshot? _originalSnapshot;
    private string _editableText = string.Empty;
    private FileTextEditState _state = FileTextEditState.Viewing;
    private string _filePath = string.Empty;
    private string _extension = string.Empty;
    private bool _canEdit;
    private bool _canFormat;
    private TextFormatKind? _formatKind;
    private string _saveMessage = string.Empty;
    private bool _isSaving;
    private string _itemName = string.Empty;
    private long _itemSize;
    private bool _disposed;

    public FileTextEditState State
    {
        get => _state;
        private set
        {
            if (SetProperty(ref _state, value))
            {
                RaisePropertyChanged(nameof(IsViewing));
                RaisePropertyChanged(nameof(IsEditing));
                RaisePropertyChanged(nameof(IsSavingIndicator));
                RaisePropertyChanged(nameof(IsSaveCompleted));
                RaisePropertyChanged(nameof(IsSaveNeedsReview));
                RaisePropertyChanged(nameof(IsSaveFailed));
                RaisePropertyChanged(nameof(CanSubmitSave));
                RaisePropertyChanged(nameof(ShowSaveStatus));
            }
        }
    }

    public string EditableText
    {
        get => _editableText;
        set
        {
            if (SetProperty(ref _editableText, value ?? string.Empty))
            {
                RaisePropertyChanged(nameof(HasUnsavedChanges));
                RaisePropertyChanged(nameof(CanSubmitSave));
            }
        }
    }

    public string SaveMessage
    {
        get => _saveMessage;
        private set => SetProperty(ref _saveMessage, value ?? string.Empty);
    }

    public string ItemName
    {
        get => _itemName;
        private set => SetProperty(ref _itemName, value ?? string.Empty);
    }

    public bool CanEdit => _canEdit;
    public bool CanFormat => _canFormat && _formatKind is not null;
    public bool HasUnsavedChanges =>
        (State is FileTextEditState.Editing or FileTextEditState.SaveNeedsReview) &&
        !string.Equals(_editableText, _originalText, StringComparison.Ordinal);

    public bool IsViewing => State == FileTextEditState.Viewing;
    public bool IsEditing => State is FileTextEditState.Editing or FileTextEditState.SaveNeedsReview;
    public bool IsSavingIndicator => State == FileTextEditState.Saving || _isSaving;
    public bool IsSaveCompleted => State == FileTextEditState.SaveCompleted;
    public bool IsSaveNeedsReview => State == FileTextEditState.SaveNeedsReview;
    public bool CanSubmitSave => State == FileTextEditState.Editing && HasUnsavedChanges;
    public bool IsSaveFailed => State == FileTextEditState.SaveFailed;
    public bool ShowSaveStatus =>
        State is FileTextEditState.SaveCompleted or FileTextEditState.SaveNeedsReview or
            FileTextEditState.SaveFailed;

    public void Attach(IFilePreviewRepository repository, FileItem item)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(item);

        Reset();
        _repository = repository;

        var extension = Path.GetExtension(item.Name).TrimStart('.');
        var availability = repository.GetTextEditAvailability();
        _extension = extension;
        _canEdit = availability.CanEdit &&
            FileTextEditClassification.CanEditSelectedText(extension);
        _canFormat = availability.CanFormat &&
            FileTextEditClassification.CanFormatSelectedText(extension);
        _formatKind = FileTextEditClassification.FormatKindForExtension(extension);
        _filePath = item.Path;
        _itemName = item.Name;
        _itemSize = item.Size;

        RaisePropertyChanged(nameof(CanEdit));
        RaisePropertyChanged(nameof(CanFormat));
    }

    public async Task<bool> EnterEditModeAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        if (_repository is null || !_canEdit || string.IsNullOrEmpty(_filePath))
        {
            return false;
        }

        try
        {
            const long maxBytes = 5L * 1024 * 1024;
            var snapshot = await _repository.DownloadTextContentSnapshotAsync(
                _filePath,
                _itemSize,
                maxBytes,
                cancellationToken).ConfigureAwait(true);

            _originalSnapshot = snapshot;
            _originalText = snapshot.Text;
            _editableText = snapshot.Text;
            State = FileTextEditState.Editing;
            RaisePropertyChanged(nameof(EditableText));
            RaisePropertyChanged(nameof(HasUnsavedChanges));
            return true;
        }
        catch
        {
            return false;
        }
    }

    public void CancelEdit()
    {
        ThrowIfDisposed();
        Reset();
    }

    public async Task SaveAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        if (_repository is null ||
            State != FileTextEditState.Editing ||
            string.IsNullOrEmpty(_filePath) ||
            _originalSnapshot is null)
        {
            return;
        }

        _isSaving = true;
        State = FileTextEditState.Saving;
        RaisePropertyChanged(nameof(IsSavingIndicator));

        try
        {
            var result = await _repository.SaveTextContentAsync(
                _filePath,
                _editableText,
                _originalSnapshot,
                cancellationToken).ConfigureAwait(true);

            _isSaving = false;

            if (result.Status == MutationResultStatus.ConfirmedSuccess)
            {
                _originalText = _editableText;
                State = FileTextEditState.SaveCompleted;
                SaveMessage = string.Empty;
            }
            else if (result.Status == MutationResultStatus.SubmittedButUnverified ||
                result.Status == MutationResultStatus.CancellationRequestedAfterSubmission)
            {
                State = FileTextEditState.SaveNeedsReview;
                SaveMessage = result.DiagnosticTag ?? string.Empty;
            }
            else
            {
                State = FileTextEditState.SaveFailed;
                SaveMessage = string.Empty;
            }
        }
        catch
        {
            _isSaving = false;
            State = FileTextEditState.SaveFailed;
            SaveMessage = string.Empty;
        }
    }

    public async Task FormatAsync()
    {
        ThrowIfDisposed();
        if (_repository is null ||
            !CanFormat ||
            _formatKind is null ||
            State != FileTextEditState.Editing)
        {
            return;
        }

        try
        {
            var formatted = await _repository.FormatTextContentAsync(
                _editableText,
                _formatKind.Value)
                .ConfigureAwait(true);
            EditableText = formatted;
        }
        catch
        {
            // 格式化失败时保留原文。
        }
    }

    public bool RequestClose()
    {
        if (HasUnsavedChanges)
        {
            return false;
        }
        Reset();
        return true;
    }

    private void Reset()
    {
        State = FileTextEditState.Viewing;
        _originalText = string.Empty;
        _originalSnapshot = null;
        _editableText = string.Empty;
        _saveMessage = string.Empty;
        _filePath = string.Empty;
        _isSaving = false;
        _itemName = string.Empty;
        _itemSize = 0;
        RaisePropertyChanged(nameof(EditableText));
        RaisePropertyChanged(nameof(HasUnsavedChanges));
        RaisePropertyChanged(nameof(IsSavingIndicator));
        RaisePropertyChanged(nameof(ShowSaveStatus));
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        Reset();
    }

}

import DsmCore
import DsmLocalization
import SwiftUI

struct MobileScheduledTasksScreen: View {
    @Bindable var model: MobileScheduledTasksModel
    @State private var query = ""
    @State private var filter = MobileTaskFilter.all
    @State private var sheet: MobileTaskSheet?
    @State private var opening = false
    @State private var openError: MobileScheduledTasksModel.Failure?
    private var filtered: [NasScheduledTask] {
        (model.tasks.value ?? []).filter { filter.includes($0) && MobileNasReadFormatting.matches(query, values: [$0.name, $0.owner ?? "", $0.type ?? ""]) }
    }
    var body: some View {
        List {
            Section {
                Button(L10n.string("mobile.nas.task.create"), systemImage: "plus") {
                    opening = true; openError = nil
                    let token = model.activation
                    Task {
                        defer { opening = false }
                        do {
                            let draft = try await model.newDraft()
                            guard token == model.activation else { return }
                            sheet = .editor(.init(task: nil, draft: draft, activation: token))
                        }
                        catch { if !(error is CancellationError) { openError = MobileScheduledTasksModel.failure(error) } }
                    }
                }.disabled(!model.canCreate || opening).accessibilityIdentifier("mobile.nas.task.create")
                TextField(L10n.string("mobile.nas.task.search"), text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).accessibilityIdentifier("mobile.nas.task.search")
                Picker(L10n.string("mobile.nas.task.filter"), selection: $filter) {
                    ForEach(MobileTaskFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("mobile.nas.task.filter")
            }
            if let error = openError ?? model.error, ![.error, .unavailable].contains(model.tasks.phase) { Section { Text(error.message).accessibilityIdentifier("mobile.nas.task.error") } }
            Section {
                switch model.tasks.phase {
                case .idle, .loading: ProgressView(L10n.string("mobile.nas.task.loading"))
                case .error, .unavailable:
                    ContentUnavailableView(L10n.string("mobile.nas.task.unavailable"), systemImage: "exclamationmark.triangle", description: Text((model.error ?? .read).message))
                    Button(L10n.string("mobile.nas-health.action.retry")) { Task { await model.refresh() } }.accessibilityIdentifier("mobile.nas.task.retry")
                case .empty: ContentUnavailableView(L10n.string("mobile.nas.task.empty"), systemImage: "calendar", description: Text(L10n.string("mobile.nas.task.emptyHint")))
                case .content:
                    if filtered.isEmpty { ContentUnavailableView(L10n.string("mobile.nas.filter.empty"), systemImage: "magnifyingglass", description: Text(L10n.string("mobile.nas.filter.retry"))).accessibilityIdentifier("mobile.nas.task.filteredEmpty") }
                    ForEach(filtered) { task in
                        Button { sheet = .details(task, model.activation) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(task.name).font(.headline).foregroundStyle(.primary)
                                Text(task.enabledLabel).foregroundStyle(.secondary)
                                if let owner = task.owner { Text(L10n.string("mobile.nas.task.ownerValue", owner)).foregroundStyle(.secondary) }
                                if let next = task.nextTriggerDescription, !next.isEmpty { Text(next).font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect)
                        }.buttonStyle(.plain).accessibilityIdentifier("mobile.nas.task.row.\(task.id)")
                    }
                }
            }
            if !model.entries.isEmpty {
                Section(L10n.string("mobile.nas.service.activity")) {
                    ForEach(model.entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.action.title).font(.headline)
                            Text(model.recovery.isExecuting(entry.id) ? L10n.string("mobile.nas.service.working") : entry.message)
                                .accessibilityIdentifier("mobile.nas.task.activity.\(entry.phase.rawValue)")
                            Text(entry.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))).font(.caption).foregroundStyle(.secondary)
                            if entry.isUnfinished {
                                Button(L10n.string("mobile.nas.service.refresh")) { Task { await model.refresh() } }.disabled(model.isOperating).accessibilityIdentifier("mobile.nas.task.recover")
                            } else {
                                Button(L10n.string("mobile.nas.service.removeRecord")) { model.removeRecord(entry.id) }.disabled(model.recovery.isExecuting(entry.id))
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("mobile.nas.task.directory")
        .navigationTitle(L10n.string("mobile.nas-details.section.scheduled-tasks"))
        .navigationBarTitleDisplayMode(.inline).listStyle(.insetGrouped)
        .refreshable { await model.refresh() }.task { await model.loadIfNeeded() }
        .onChange(of: model.activation) { _, _ in sheet = nil; openError = nil; query = "" }
        .onDisappear { model.cancelRead() }
        .sheet(item: $sheet) { source in
            NavigationStack {
                switch source {
                case .editor(let editor): MobileTaskEditor(model: model, source: editor) { _ in close(source.id) }
                case .details(let task, let token): MobileTaskDetail(model: model, task: task, activation: token) { close(source.id) }
                }
            }
        }
        .fillsAvailableContentArea(alignment: .topLeading)
    }
    private func close(_ id: String) { if sheet?.id == id { sheet = nil } }
}

private struct MobileTaskEditorSource: Identifiable {
    let id = UUID()
    let task: NasScheduledTask?
    let draft: NasScheduledTaskDraft
    let activation: UUID
}
private enum MobileTaskSheet: Identifiable {
    case editor(MobileTaskEditorSource), details(NasScheduledTask, UUID)
    var id: String { switch self { case .editor(let source): source.id.uuidString; case .details(let task, let token): "details-" + task.id + token.uuidString } }
}
private enum MobileTaskFilter: String, CaseIterable {
    case all, enabled, disabled, unknown
    var title: String {
        let key = switch self { case .all: "mobile.nas.task.all"; case .enabled: "mobile.nas-details.task.enabled"; case .disabled: "mobile.nas-details.task.disabled"; case .unknown: "mobile.nas.task.unknown" }
        return L10n.string(key)
    }
    func includes(_ task: NasScheduledTask) -> Bool {
        switch self { case .all: true; case .unknown: !task.isEnabledKnown; case .enabled: task.isEnabledKnown && task.isEnabled; case .disabled: task.isEnabledKnown && !task.isEnabled }
    }
}
private struct MobileTaskProposal: Identifiable { let id = UUID(); let change: NasScheduledTaskChange }

private struct MobileTaskDetail: View {
    @Bindable var model: MobileScheduledTasksModel
    let task: NasScheduledTask
    let activation: UUID
    let onClose: () -> Void
    @State private var draft: NasScheduledTaskDraft?
    @State private var loaded = false
    @State private var error: MobileScheduledTasksModel.Failure?
    @State private var editor: MobileTaskEditorSource?
    @State private var proposal: MobileTaskProposal?
    @State private var showingResults = false
    @State private var operationID: UUID?
    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.string("mobile.nas.task.name"), value: task.name)
                if let owner = task.owner { LabeledContent(L10n.string("mobile.nas.task.owner"), value: owner) }
                LabeledContent(L10n.string("mobile.nas.task.filter"), value: task.enabledLabel)
                if let action = task.action, !action.isEmpty { Text(action).textSelection(.enabled) }
                if let next = task.nextTriggerDescription, !next.isEmpty { LabeledContent(L10n.string("mobile.nas-details.field.next-trigger"), value: next) }
            }
            if !loaded { Section { ProgressView(L10n.string("mobile.nas.task.loading")).accessibilityIdentifier("mobile.nas.task.detailLoading") } }
            if let error { Section { Text(error.message); Button(L10n.string("mobile.nas-health.action.retry")) { Task { await load() } } } }
            Section {
                Button(L10n.string("mobile.nas.task.results")) { showingResults = true }.accessibilityIdentifier("mobile.nas.task.results")
                if let draft, task.canEdit, model.supportsEditing {
                    Button(L10n.string("mobile.nas.task.edit")) { editor = .init(task: task, draft: draft, activation: activation) }
                        .disabled(!model.canManage(task)).accessibilityIdentifier("mobile.nas.task.edit")
                }
                if task.canEdit {
                    Button(task.isEnabled ? L10n.string("mobile.nas.task.disable") : L10n.string("mobile.nas.task.enable")) {
                        proposal = .init(change: .setEnabled(task: task, original: draft, enabled: !task.isEnabled))
                    }.disabled(!model.canPerform(.setEnabled(task: task, original: draft, enabled: !task.isEnabled))).accessibilityIdentifier("mobile.nas.task.enable")
                }
                if task.canRun {
                    Button(L10n.string("mobile.nas.task.run")) { proposal = .init(change: .run(task: task, original: draft)) }
                        .disabled(!loaded || error != nil || !model.canPerform(.run(task: task, original: draft))).accessibilityIdentifier("mobile.nas.task.run")
                }
                if task.canEdit {
                    Button(L10n.string("mobile.nas.task.delete"), role: .destructive) { proposal = .init(change: .delete(task: task)) }
                        .disabled(!model.canPerform(.delete(task: task))).accessibilityIdentifier("mobile.nas.task.delete")
                }
            }
            if let operationID, let entry = model.recovery.entry(operationID) { Section { Text(entry.message).accessibilityIdentifier("mobile.nas.task.operationResult") } }
            if let draft { MobileTaskDraftSummary(draft: draft, showsIdentity: false) }
        }
        .accessibilityIdentifier("mobile.nas.task.detail")
        .navigationTitle(L10n.string("mobile.nas.task.details")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.nas.service.done"), action: onClose).accessibilityIdentifier("mobile.nas.task.done") } }
        .task { await load() }.task(id: operationID) { await finishIfSuccessful() }
        .sheet(item: $editor) { source in NavigationStack { MobileTaskEditor(model: model, source: source) { saved in editor = nil; if saved { onClose() } } } }
        .sheet(item: $proposal) { source in NavigationStack { MobileTaskConfirmation(model: model, change: source.change, activation: activation) { operationID = $0 } } }
        .sheet(isPresented: $showingResults) { NavigationStack { MobileTaskResults(model: model, task: task, activation: activation) } }
        .privacySensitive().fillsAvailableContentArea(alignment: .topLeading)
    }
    private func load() async {
        guard activation == model.activation, !Task.isCancelled else { return }
        loaded = false; error = nil; draft = nil
        do { draft = try await model.inspect(task) }
        catch { if !(error is CancellationError) { self.error = MobileScheduledTasksModel.failure(error) } }
        loaded = true
    }
    private func finishIfSuccessful() async {
        guard let operationID else { return }; await model.waitForOperation(operationID)
        if !Task.isCancelled, let phase = model.recovery.entry(operationID)?.phase, [.succeeded, .accepted].contains(phase) { onClose() }
    }
}

private struct MobileTaskEditor: View {
    @Bindable var model: MobileScheduledTasksModel
    let source: MobileTaskEditorSource
    let onClose: (Bool) -> Void
    @State private var draft: NasScheduledTaskDraft
    @State private var proposal: MobileTaskProposal?
    @State private var operationID: UUID?
    @FocusState private var focused: String?
    init(model: MobileScheduledTasksModel, source: MobileTaskEditorSource, onClose: @escaping (Bool) -> Void) {
        self.model = model; self.source = source; self.onClose = onClose; _draft = .init(initialValue: source.draft)
    }
    private var change: NasScheduledTaskChange { .save(task: source.task, original: source.draft, desired: draft) }
    var body: some View {
        Form {
            Group {
                Section {
                    TextField(L10n.string("mobile.nas.task.name"), text: $draft.name).focused($focused, equals: "name").accessibilityIdentifier("mobile.nas.task.name")
                    TextField(L10n.string("mobile.nas.task.owner"), text: $draft.owner).focused($focused, equals: "owner").accessibilityIdentifier("mobile.nas.task.owner")
                    Toggle(L10n.string("mobile.nas.task.enable"), isOn: $draft.isEnabled).accessibilityIdentifier("mobile.nas.task.enabled")
                }
                Section(L10n.string("mobile.nas.task.schedule")) {
                    Picker(L10n.string("power-schedule.edit.hour"), selection: $draft.schedule.hour) { ForEach(0..<24) { Text($0, format: .number.grouping(.never)).tag($0) } }.accessibilityIdentifier("mobile.nas.task.hour")
                    Picker(L10n.string("power-schedule.edit.minute"), selection: $draft.schedule.minute) { ForEach(0..<60) { Text($0, format: .number.grouping(.never)).tag($0) } }.accessibilityIdentifier("mobile.nas.task.minute")
                    ForEach(NasWeekday.allCases, id: \.rawValue) { day in
                        Toggle(MobileNasReadFormatting.recurrence(.weekly([day])), isOn: Binding(get: { draft.schedule.selectedWeekdays?.contains(day.rawValue % 7) == true }, set: {
                            var days = draft.schedule.selectedWeekdays ?? []; if $0 { days.insert(day.rawValue % 7) } else { days.remove(day.rawValue % 7) }
                            draft.schedule.weekDays = days.sorted().map(String.init).joined(separator: ",")
                        })).disabled(source.task != nil && source.draft.schedule.selectedWeekdays == nil).accessibilityIdentifier("mobile.nas.task.day.\(day.rawValue % 7)")
                    }
                    if source.task != nil && source.draft.schedule.selectedWeekdays == nil { Text(L10n.string("mobile.nas.task.unknownDays")).foregroundStyle(.secondary) }
                    Text(L10n.string("mobile.nas.task.scheduleHint")).foregroundStyle(.secondary)
                }
                Section(L10n.string("mobile.nas.task.script")) {
                    TextEditor(text: $draft.script).font(.system(.body, design: .monospaced)).frame(minHeight: 160)
                        .focused($focused, equals: "script").accessibilityLabel(L10n.string("mobile.nas.task.script")).accessibilityIdentifier("mobile.nas.task.script")
                }
                Section(L10n.string("mobile.nas.task.notifications")) {
                    Toggle(L10n.string("mobile.nas.task.notifyError"), isOn: $draft.notifyOnError).accessibilityIdentifier("mobile.nas.task.notifyError")
                    TextField(L10n.string("mobile.nas.task.emails"), text: $draft.notificationEmails).focused($focused, equals: "emails").keyboardType(.emailAddress).accessibilityIdentifier("mobile.nas.task.emails")
                }
            }.disabled(!model.canManage(source.task))
            if !draft.hasValidContent || draft.schedule.selectedWeekdays == nil && (source.task == nil || draft.schedule.weekDays != source.draft.schedule.weekDays) { Section { Text(L10n.string("mobile.nas.task.invalid")).foregroundStyle(.secondary).accessibilityIdentifier("mobile.nas.task.invalid") } }
            if let error = model.error { Section { Text(error.message) } }
            if let operationID, let entry = model.recovery.entry(operationID) { Section { Text(entry.message).accessibilityIdentifier("mobile.nas.task.operationResult") } }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled().scrollDismissesKeyboard(.interactively).onSubmit { focused = nil }
        .navigationTitle(L10n.string(source.task == nil ? "mobile.nas.task.create" : "mobile.nas.task.edit")).navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("mobile.nas.task.editor")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.nas.service.done")) { onClose(false) }.accessibilityIdentifier("mobile.nas.task.done") }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.string("mobile.nas.service.save")) { focused = nil; proposal = .init(change: change) }
                    .disabled(!model.canPerform(change)).accessibilityIdentifier("mobile.nas.task.save")
            }
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(L10n.string("mobile.nas.service.done")) { focused = nil }.accessibilityIdentifier("mobile.nas.task.keyboardDone") }
        }
        .sheet(item: $proposal) { value in NavigationStack { MobileTaskConfirmation(model: model, change: value.change, activation: source.activation) { operationID = $0 } } }
        .task(id: operationID) {
            guard let operationID else { return }; await model.waitForOperation(operationID)
            if !Task.isCancelled, source.activation == model.activation, model.recovery.entry(operationID)?.phase == .succeeded { onClose(true) }
        }
        .privacySensitive().fillsAvailableContentArea(alignment: .topLeading)
    }
}

private struct MobileTaskConfirmation: View {
    @Bindable var model: MobileScheduledTasksModel
    let change: NasScheduledTaskChange
    let activation: UUID
    let onSubmit: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var submitted = false
    var body: some View {
        Form {
            Section { Text(change.action.warning).accessibilityIdentifier("mobile.nas.task.warning") }
            if let draft = change.desiredDraft ?? change.originalDraft { MobileTaskDraftSummary(draft: draft) }
            else if let task = change.task {
                Section { LabeledContent(L10n.string("mobile.nas.task.name"), value: task.name)
                    if let owner = task.owner { LabeledContent(L10n.string("mobile.nas.task.owner"), value: owner) }
                    if let action = task.action, !action.isEmpty { Text(action).textSelection(.enabled) }
                }
            }
            if let error = model.error { Section { Text(error.message) } }
        }
        .accessibilityIdentifier("mobile.nas.task.confirmation")
        .navigationTitle(change.action.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.nas.service.cancel")) { dismiss() }.accessibilityIdentifier("mobile.nas.task.cancel") }
            ToolbarItem(placement: .confirmationAction) {
                Button(change.action.title, role: .destructive) {
                    guard !submitted, let id = model.perform(change, activation: activation) else { return }
                    submitted = true; onSubmit(id); dismiss()
                }.disabled(submitted || !model.canPerform(change)).accessibilityIdentifier("mobile.nas.task.confirm")
            }
        }
        .privacySensitive().fillsAvailableContentArea(alignment: .topLeading)
    }
}

private struct MobileTaskDraftSummary: View {
    let draft: NasScheduledTaskDraft
    var showsIdentity = true
    var body: some View {
        Section {
            if showsIdentity {
            LabeledContent(L10n.string("mobile.nas.task.name"), value: draft.name)
            LabeledContent(L10n.string("mobile.nas.task.owner"), value: draft.owner)
            LabeledContent(L10n.string("mobile.nas.task.filter"), value: L10n.string(draft.isEnabled ? "mobile.nas-details.task.enabled" : "mobile.nas-details.task.disabled"))
            }
            LabeledContent(L10n.string("mobile.nas.task.schedule"), value: MobileNasReadFormatting.time(hour: draft.schedule.hour, minute: draft.schedule.minute))
            if let weekdays = draft.schedule.selectedWeekdays { Text(MobileNasReadFormatting.recurrence(.weekly(NasWeekday.allCases.filter { weekdays.contains($0.rawValue % 7) }))) }
            if let date = draft.schedule.date, !date.isEmpty { Text(date) }
            Text(L10n.string("mobile.nas.task.scheduleHint")).foregroundStyle(.secondary)
        }
        Section(L10n.string("mobile.nas.task.script")) { Text(draft.script).font(.system(.body, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("mobile.nas.task.scriptPreview") }
        Section(L10n.string("mobile.nas.task.notifications")) {
            LabeledContent(L10n.string("mobile.nas.task.notifyError"), value: L10n.string(draft.notifyOnError ? "mobile.nas-details.task.enabled" : "mobile.nas-details.task.disabled"))
            if !draft.notificationEmails.isEmpty { Text(draft.notificationEmails).textSelection(.enabled) }
        }
    }
}

private struct MobileTaskResults: View {
    @Bindable var model: MobileScheduledTasksModel
    let task: NasScheduledTask
    let activation: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var results: [NasScheduledTaskResult] = []
    @State private var loading = true
    @State private var error: MobileScheduledTasksModel.Failure?
    var body: some View {
        List {
            if loading { ProgressView(L10n.string("mobile.nas.task.loadingResults")) }
            else if let error { Text(error.message); Button(L10n.string("mobile.nas-health.action.retry")) { Task { await load() } } }
            else if results.isEmpty { ContentUnavailableView(L10n.string("mobile.nas.task.noResults"), systemImage: "clock", description: Text(L10n.string("mobile.nas.task.noResultsHint"))) }
            else {
                ForEach(results) { result in
                    NavigationLink {
                        MobileTaskOutput(model: model, task: task, result: result, activation: activation)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(result.startedAt?.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.locale)) ?? L10n.string("mobile.nas.task.unknownTime"))
                            Text(result.exitCode.map { L10n.string("mobile.nas.task.exitCode", $0.formatted(.number.locale(L10n.locale))) } ?? L10n.string("mobile.nas.task.unknownResult")).foregroundStyle(.secondary)
                        }.frame(minHeight: 44)
                    }.accessibilityIdentifier("mobile.nas.task.result.\(result.id)")
                }
            }
        }
        .navigationTitle(L10n.string("mobile.nas.task.results")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.nas.service.done")) { dismiss() }.accessibilityIdentifier("mobile.nas.task.resultsDone") } }
        .task { await load() }.refreshable { await load() }
        .onChange(of: model.activation) { _, _ in results = []; dismiss() }
        .privacySensitive().fillsAvailableContentArea(alignment: .topLeading)
    }
    private func load() async {
        guard activation == model.activation, !Task.isCancelled else { return }
        loading = true; error = nil
        do { results = try await model.results(task) }
        catch { if !(error is CancellationError) { self.error = MobileScheduledTasksModel.failure(error) } }
        loading = false
    }
}
private struct MobileTaskOutput: View {
    @Bindable var model: MobileScheduledTasksModel
    let task: NasScheduledTask
    let result: NasScheduledTaskResult
    let activation: UUID
    @State private var output: NasScheduledTaskResultOutput?
    @State private var loading = true
    @State private var error: MobileScheduledTasksModel.Failure?
    var body: some View {
        List {
            Section {
                LabeledContent(L10n.string("mobile.nas.task.started"), value: date(result.startedAt))
                LabeledContent(L10n.string("mobile.nas.task.stopped"), value: date(result.stoppedAt))
                if let type = result.exitType { LabeledContent(L10n.string("mobile.nas.task.exitType"), value: type) }
                if let trigger = result.triggerEvent { LabeledContent(L10n.string("mobile.nas.task.trigger"), value: trigger) }
                if let code = result.exitCode { Text(L10n.string("mobile.nas.task.exitCode", code.formatted(.number.locale(L10n.locale)))) }
            }
            if loading { ProgressView(L10n.string("mobile.nas.task.loadingOutput")) }
            else if let error { Text(error.message); Button(L10n.string("mobile.nas-health.action.retry")) { Task { await load() } } }
            else {
                Section(L10n.string("mobile.nas.task.command")) { outputText(output?.command).accessibilityIdentifier("mobile.nas.task.command") }
                Section(L10n.string("mobile.nas.task.output")) { outputText(output?.output).accessibilityIdentifier("mobile.nas.task.output") }
            }
        }
        .navigationTitle(L10n.string("mobile.nas.task.output")).navigationBarTitleDisplayMode(.inline)
        .task { await load() }.onChange(of: model.activation) { _, _ in output = nil }
        .privacySensitive().fillsAvailableContentArea(alignment: .topLeading)
    }
    private func date(_ value: Date?) -> String { value?.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.locale)) ?? L10n.string("mobile.nas.task.unknownTime") }
    private func outputText(_ value: String?) -> some View {
        Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.string("mobile.nas.task.noOutput")).font(.system(.body, design: .monospaced)).textSelection(.enabled)
    }
    private func load() async {
        guard activation == model.activation, !Task.isCancelled else { return }
        loading = true; error = nil; output = nil
        do { output = try await model.output(task, resultID: result.id) }
        catch { if !(error is CancellationError) { self.error = MobileScheduledTasksModel.failure(error) } }
        loading = false
    }
}

private extension NasScheduledTask {
    var enabledLabel: String { L10n.string(!isEnabledKnown ? "mobile.nas.task.unknown" : (isEnabled ? "mobile.nas-details.task.enabled" : "mobile.nas-details.task.disabled")) }
}
private extension NasScheduledTaskAction {
    var title: String {
        let key = switch self { case .create: "mobile.nas.task.create"; case .save: "mobile.nas.task.save"; case .enable: "mobile.nas.task.enable"; case .disable: "mobile.nas.task.disable"; case .run: "mobile.nas.task.run"; case .delete: "mobile.nas.task.delete" }
        return L10n.string(key)
    }
    var warning: String {
        let key = switch self { case .create, .save: "mobile.nas.task.saveWarning"; case .enable: "mobile.nas.task.enableWarning"; case .disable: "mobile.nas.task.disableWarning"; case .run: "mobile.nas.task.runWarning"; case .delete: "mobile.nas.task.deleteWarning" }
        return L10n.string(key)
    }
}
extension MobileScheduledTasksModel.Failure {
    var message: String {
        let key = switch self { case .read: "mobile.nas.task.readError"; case .denied: "mobile.nas.task.denied"; case .unavailable: "mobile.nas.task.unsupported"; case .changed: "mobile.nas.task.changed"; case .storage: "mobile.nas.task.storageError"; case .trust: "mobile.nas.service.trustError" }
        return L10n.string(key)
    }
}
private extension MobileScheduledTaskStore.Entry {
    var message: String {
        let key: String
        switch phase {
        case .prepared: key = "mobile.nas.service.working"
        case .submitted: key = action == .run ? "mobile.nas.task.runUnknown" : "mobile.nas.task.unknownOperation"
        case .accepted: key = "mobile.nas.task.requestAccepted"
        case .cancelled: key = "mobile.nas.task.cancelled"
        case .succeeded:
            key = switch action { case .delete: "mobile.nas.task.deleted"; case .enable: "mobile.nas.task.enabled"; case .disable: "mobile.nas.task.disabled"; default: "mobile.nas.task.saved" }
        case .failed:
            key = switch failure { case .denied: "mobile.nas.task.denied"; case .unavailable: "mobile.nas.task.unsupported"; case .changed: "mobile.nas.task.changed"; default: "mobile.nas.task.failed" }
        }
        return L10n.string(key)
    }
}

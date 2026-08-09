import DsmCore
import DsmLocalization
import SwiftUI

struct MobileFileLocationsView: View {
    @Bindable var locations: MobileFileLocationsModel
    let refresh: () async -> Void
    let openLocation: (String, MobileFileLocationSource) async -> Bool
    let cancelOpenLocation: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var openingPath: String?
    @State private var showsOpenError = false
    @State private var openTask: Task<Void, Never>?

    private var state: MobileFileLocationsProfileState { locations.state }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    locationButton(
                        title: L10n.string("mobile.files.locations.shares"),
                        path: "",
                        source: .shares,
                        systemImage: "externaldrive.fill.badge.person.crop"
                    )
                }

                favoritesSection
                recentSection
                recycleSection
                remoteSection
            }
            .navigationTitle(L10n.string("mobile.files.locations.title"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.string("mobile.files.locations.close")) { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(
                        !locations.canOpenLocations
                            || state.favorites.isRefreshing
                            || state.remote.isRefreshing
                            || state.recycle.isRefreshing
                    )
                    .accessibilityLabel(L10n.string("mobile.files.locations.refresh"))
                }
            }
            .alert(
                L10n.string("mobile.files.locations.open-error.title"),
                isPresented: $showsOpenError
            ) {
                Button(L10n.string("mobile.files.locations.close"), role: .cancel) {}
            } message: {
                Text(L10n.string("mobile.files.locations.open-error.message"))
            }
        }
        .onDisappear {
            openTask?.cancel()
            openTask = nil
            openingPath = nil
            showsOpenError = false
            cancelOpenLocation()
        }
    }

    @ViewBuilder
    private var favoritesSection: some View {
        Section(L10n.string("mobile.files.locations.favorites")) {
            switch state.favorites.pageState {
            case .loading:
                loadingRow("mobile.files.locations.favorites.loading")
            case .empty:
                messageRow("mobile.files.locations.favorites.empty")
            case .filteredEmpty:
                messageRow("mobile.files.locations.favorites.filtered-empty")
            case .error:
                errorRow("mobile.files.locations.favorites.error")
            case .content:
                ForEach(state.favorites.locations) { location in
                    locationButton(
                        title: location.name,
                        path: location.path,
                        source: .favorite,
                        systemImage: "star.fill"
                    )
                }
            }
            if state.favorites.isTruncated {
                noticeRow("mobile.files.locations.favorites.truncated")
            }
            if state.favorites.hasRefreshError {
                noticeRow("mobile.files.locations.favorites.refresh-error")
            }
            if state.favorites.isRefreshing {
                loadingRow("mobile.files.locations.favorites.refreshing")
            }
        }
    }

    @ViewBuilder
    private var recycleSection: some View {
        Section(L10n.string("mobile.files.locations.recycle")) {
            switch state.recycle.pageState {
            case .loading:
                loadingRow("mobile.files.locations.recycle.loading")
            case .empty:
                messageRow("mobile.files.locations.recycle.empty")
            case .filteredEmpty:
                messageRow("mobile.files.locations.recycle.filtered-empty")
            case .error:
                errorRow("mobile.files.locations.recycle.error")
            case .content:
                ForEach(state.recycle.locations, id: \.recyclePath) { location in
                    locationButton(
                        title: location.shareName,
                        path: location.recyclePath,
                        source: .recycle,
                        systemImage: "trash"
                    )
                }
            }
            if state.recycle.isPartial {
                noticeRow("mobile.files.locations.recycle.partial")
            }
            if state.recycle.isTruncated {
                noticeRow("mobile.files.locations.recycle.truncated")
            }
            if state.recycle.hasRefreshError {
                noticeRow("mobile.files.locations.recycle.refresh-error")
            }
            if state.recycle.isRefreshing {
                loadingRow("mobile.files.locations.recycle.refreshing")
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        Section(L10n.string("mobile.files.locations.recent")) {
            if state.recent.isEmpty {
                messageRow("mobile.files.locations.recent.empty")
            } else {
                ForEach(state.recent) { location in
                    locationButton(
                        title: location.name,
                        path: location.path,
                        source: .recent,
                        systemImage: "clock"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var remoteSection: some View {
        Section(L10n.string("mobile.files.locations.remote")) {
            switch state.remote.pageState {
            case .loading:
                loadingRow("mobile.files.locations.remote.loading")
            case .empty:
                messageRow("mobile.files.locations.remote.empty")
            case .filteredEmpty:
                messageRow("mobile.files.locations.remote.filtered-empty")
            case .error:
                errorRow("mobile.files.locations.remote.error")
            case .content:
                ForEach(state.remote.folders) { folder in
                    locationButton(
                        title: folder.item.name,
                        path: folder.item.path,
                        source: .remote,
                        systemImage: "network"
                    )
                    .accessibilityHint(L10n.string("mobile.files.locations.remote.read-only-hint"))
                }
            }
            if state.remote.isPartial {
                noticeRow("mobile.files.locations.remote.partial")
            }
            if state.remote.isTruncated {
                noticeRow("mobile.files.locations.remote.truncated")
            }
            if state.remote.hasRefreshError {
                noticeRow("mobile.files.locations.remote.refresh-error")
            }
            if state.remote.isRefreshing {
                loadingRow("mobile.files.locations.remote.refreshing")
            }
        }
    }

    private func locationButton(
        title: String,
        path: String,
        source: MobileFileLocationSource,
        systemImage: String
    ) -> some View {
        Button {
            guard openingPath == nil else { return }
            openingPath = path
            openTask = Task {
                let opened = await openLocation(path, source)
                guard !Task.isCancelled else { return }
                openingPath = nil
                openTask = nil
                if opened {
                    dismiss()
                } else {
                    showsOpenError = true
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if !path.isEmpty {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if openingPath == path {
                    ProgressView()
                        .accessibilityLabel(L10n.string("mobile.files.locations.opening"))
                } else {
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(openingPath != nil || !locations.canOpenLocations)
        .accessibilityLabel(L10n.string("mobile.files.locations.item-format", title))
        .accessibilityValue(path)
        .accessibilityHint(L10n.string("mobile.files.locations.open-hint"))
    }

    private func loadingRow(_ key: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(L10n.string(key))
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
    }

    private func messageRow(_ key: String) -> some View {
        Text(L10n.string(key))
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
    }

    private func errorRow(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.string(key), systemImage: "exclamationmark.circle")
            Button(L10n.string("mobile.files.locations.retry")) {
                Task { await refresh() }
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        }
        .accessibilityElement(children: .contain)
    }

    private func noticeRow(_ key: String) -> some View {
        Label(L10n.string(key), systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }
}

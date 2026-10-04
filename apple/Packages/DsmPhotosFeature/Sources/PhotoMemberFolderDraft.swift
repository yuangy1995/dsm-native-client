import DsmCore

public extension SynologyPhotoMemberFolderEdit {
    func canEditFolder(_ folder: SynologyPhotoMemberFolder) -> Bool {
        guard folder.hasKnownPermissions else { return false }
        if folder.depth == 0 { return true }
        guard let parent = original.first(where: { $0.id == folder.folder.parentID }), parent.hasKnownPermissions else { return false }
        return parent.publicRole != nil || expectedRole(for: parent) != nil
    }

    mutating func setDraftRole(_ role: SynologyPhotoFolderMemberRole?, for folder: SynologyPhotoMemberFolder) {
        guard canEditFolder(folder) else { return }
        changes.removeAll { $0.folderID == folder.id }
        changes.append(.init(folderID: folder.id, role: role))
        if folder.depth == 0, folder.privacy == "private", role == nil {
            let children = Set(original.filter { $0.folder.parentID == folder.id }.map(\.id))
            changes.removeAll { children.contains($0.folderID) }
        }
    }

    mutating func applyDraftBatch(_ next: Batch) {
        guard original.allSatisfy(\.hasKnownPermissions) else { return }
        // 连续批量操作作用于当前草稿；用最后一批加逐项差异表达，不能丢掉前一批结果。
        let desired = original.map { ($0.id, next.applying(to: expectedRole(for: $0))) }
        batch = next; changes = []
        for (id, value) in desired {
            guard let folder = original.first(where: { $0.id == id }), value != next.applying(to: folder.directRole) else { continue }
            changes.append(.init(folderID: id, role: value.flatMap(SynologyPhotoFolderMemberRole.init(rawValue:))))
        }
        let blocked = Set(original.filter { $0.depth == 1 && !canEditFolder($0) }.map(\.id))
        changes.removeAll { blocked.contains($0.folderID) }
    }
}

import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor final class MobileVirtualMachineControlTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        let values = await MainActor.run { let values = roots; roots = []; return values }
        for value in values { try? FileManager.default.removeItem(at: value) }
        try await super.tearDown()
    }
    func test按真实状态和可用接口开放操作() async throws {
        let (stopped, _, _, _) = try make(); await stopped.refresh()
        XCTAssertTrue(stopped.canPerform(ids: ["synthetic-vm"], kind: .powerOn))
        XCTAssertTrue(stopped.canPerform(ids: ["synthetic-vm"], kind: .delete))
        XCTAssertFalse(stopped.canPerform(ids: ["synthetic-vm"], kind: .shutdown))
        let (running, _, _, _) = try make(mode: "vmm-running"); await running.refresh()
        XCTAssertTrue(running.canPerform(ids: ["synthetic-vm"], kind: .shutdown))
        XCTAssertTrue(running.canPerform(ids: ["synthetic-vm"], kind: .powerOff))
        XCTAssertFalse(running.canPerform(ids: ["synthetic-vm"], kind: .restart))
        XCTAssertFalse(running.canPerform(ids: ["synthetic-vm"], kind: .delete))
        let (restarting, _, _, _) = try make(mode: "vmm-restart", internalAPI: true); await restarting.refresh()
        XCTAssertTrue(restarting.canPerform(ids: ["synthetic-vm"], kind: .restart))
    }
    func test公开及内部三种电源与删除都逐项完成() async throws {
        for internalAPI in [false, true] {
            for kind in [MobileVirtualMachineControlStore.Kind.powerOn, .shutdown, .powerOff, .delete] {
                let mode = kind == .powerOn || kind == .delete ? "vmm-control" : "vmm-running"
                let (model, transport, _, _) = try make(mode: mode, internalAPI: internalAPI)
                await model.refresh(); let id = try perform(model, kind); await model.waitForOperation(id)
                XCTAssertEqual(model.entries.first?.items.first?.phase, .succeeded)
                XCTAssertTrue(model.entries.first?.items.first?.accepted == true)
                let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
                XCTAssertEqual(writes.first?["guest_id"], "synthetic-vm")
                XCTAssertEqual(writes.first?["version"], "1")
            }
        }
    }
    func test丢回执后外部达到目标状态仍保持未知且跨重启不重发() async throws {
        let (model, transport, _, root) = try make(mode: "vmm-unknown"); await model.refresh()
        let id = try perform(model); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.items.first?.phase, .submitted)
        XCTAssertFalse(model.entries.first?.items.first?.accepted ?? true)
        let (next, target, _, _) = try make(mode: "vmm-recover", root: root); await next.refresh()
        XCTAssertEqual(next.entries.first?.items.first?.phase, .submitted)
        XCTAssertFalse(next.canPerform(ids: ["synthetic-vm"], kind: .shutdown))
        XCTAssertThrowsError(try next.recovery.remove(id, context: try XCTUnwrap(next.context)))
        let originalWrites = await transport.writes, writes = await target.writes
        XCTAssertEqual(originalWrites.count, 1); XCTAssertTrue(writes.isEmpty)
    }
    func test已接受回执断网后跨重启只读确认开机() async throws {
        let (model, _, _, root) = try make(mode: "vmm-accepted-offline"); await model.refresh()
        let id = try perform(model); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.items.first?.phase, .submitted)
        XCTAssertTrue(model.entries.first?.items.first?.accepted == true)
        let (next, transport, _, _) = try make(mode: "vmm-recover", root: root); await next.refresh()
        XCTAssertEqual(next.entries.first?.items.first?.phase, .succeeded)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        XCTAssertTrue(next.canPerform(ids: ["synthetic-vm"], kind: .shutdown))
    }
    func test删除接受与丢回执在目标消失后仍区分归属() async throws {
        for accepted in [true, false] {
            let (model, _, _, root) = try make(mode: accepted ? "vmm-accepted-offline" : "vmm-unknown"); await model.refresh()
            let id = try perform(model, .delete); await model.waitForOperation(id)
            let (next, transport, _, _) = try make(mode: "vmm-delete-recovered", root: root); await next.refresh()
            XCTAssertEqual(next.entries.first?.items.first?.phase, accepted ? .succeeded : .submitted)
            XCTAssertEqual(next.entries.first?.isProtected, !accepted)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test重启只记录接受不把仍运行或重新打开当作完成() async throws {
        let (model, transport, _, root) = try make(mode: "vmm-restart", internalAPI: true); await model.refresh()
        let id = try perform(model, .restart); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.items.first?.phase, .submitted)
        XCTAssertTrue(model.entries.first?.items.first?.accepted == true)
        XCTAssertFalse(model.canPerform(ids: ["synthetic-vm"], kind: .restart))
        let (next, target, _, _) = try make(mode: "vmm-restart", root: root, internalAPI: true); await next.refresh()
        XCTAssertEqual(next.entries.first?.items.first?.phase, .submitted)
        XCTAssertFalse(next.canPerform(ids: ["synthetic-vm"], kind: .powerOff))
        let writes = await transport.writes, nextWrites = await target.writes
        XCTAssertEqual(writes.first?["action"], "reboot"); XCTAssertEqual(writes.count, 1); XCTAssertTrue(nextWrites.isEmpty)
    }
    func test多项删除逐项确认与批量后项停止() async throws {
        for mode in ["vmm-control", "vmm-partial", "vmm-reject"] {
            let (model, transport, _, _) = try make(mode: mode); await model.refresh()
            let id = try perform(model, .delete, ids: ["synthetic-vm", "worker-b"]); await model.waitForOperation(id)
            let phases = model.entries.first?.items.map(\.phase)
            XCTAssertEqual(phases, mode == "vmm-control" ? [.succeeded, .succeeded] : mode == "vmm-partial" ? [.succeeded, .submitted] : [.failed, .skipped])
            let writes = await transport.writes; XCTAssertEqual(writes.count, mode == "vmm-reject" ? 1 : 2)
        }
    }
    func test权限在确认后撤回零提交并保留失败() async throws {
        let (model, transport, gate, _) = try make(); await model.refresh(); await gate.set(false)
        let id = try perform(model); await model.waitForOperation(id)
        XCTAssertEqual(model.error, .denied); XCTAssertFalse(model.allowed)
        XCTAssertEqual(model.entries.first?.items.first?.failure, .denied)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test确认后身份或名称改变整批零写() async throws {
        for replace in [false, true] {
            let (model, transport, _, _) = try make(); await model.refresh()
            if replace { await transport.replaceFirst() } else { await transport.renameFirst() }
            let id = try perform(model, .powerOn, ids: ["synthetic-vm", "worker-b"]); await model.waitForOperation(id)
            XCTAssertEqual(model.entries.first?.items.first?.failure, .changed)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test重复点击及在途移除记录被阻止() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(); await transport.holdWrites()
        let confirmation = try XCTUnwrap(model.confirmation(ids: ["synthetic-vm"], kind: .powerOn))
        let id = try XCTUnwrap(model.perform(confirmation)); await transport.waitForWrite()
        XCTAssertNil(model.perform(confirmation))
        XCTAssertThrowsError(try model.recovery.remove(id, context: try XCTUnwrap(model.context)))
        await transport.release(); await model.waitForOperation(id)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test明确拒绝不被外部后续状态覆盖() async throws {
        let (model, transport, _, _) = try make(mode: "vmm-reject"); await model.refresh()
        let id = try perform(model); await model.waitForOperation(id)
        XCTAssertEqual(model.entries.first?.items.first?.phase, .failed)
        await transport.setMode("vmm-control"); await transport.apply(.powerOn); await model.refresh()
        XCTAssertEqual(model.entries.first?.items.first?.phase, .failed)
        XCTAssertFalse(model.entries.first?.items.first?.accepted ?? true)
    }
    func test同配置换账号只保存原回执不继续后项() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(); await transport.holdWrites()
        let confirmation = try XCTUnwrap(model.confirmation(ids: ["synthetic-vm", "worker-b"], kind: .powerOn))
        let context = try XCTUnwrap(model.context), id = try XCTUnwrap(model.perform(confirmation)); await transport.waitForWrite()
        let profile = try profile(username: "other"), target = MobileVirtualMachineUITransport()
        model.configure(profile: profile, repository: try repository(target, profile: profile), authorize: { true })
        await model.refresh(); XCTAssertNotEqual(model.context, context); XCTAssertNil(model.perform(confirmation))
        await transport.release(); await model.waitForOperation(id)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(model.recovery.entry(id)?.context, context)
        XCTAssertEqual(model.recovery.entry(id)?.items[1].phase, .skipped)
        let writes = await transport.writes, nextWrites = await target.writes
        XCTAssertEqual(writes.count, 1); XCTAssertTrue(nextWrites.isEmpty)
    }
    func test缺失或不完整状态与状态转换不允许默认写入() async throws {
        for mode in ["vmm-missing-state", "vmm-incomplete", "vmm-transition"] {
            let (model, transport, _, _) = try make(mode: mode); await model.refresh()
            for kind in MobileVirtualMachineControlStore.Kind.allCases { XCTAssertFalse(model.canPerform(ids: ["synthetic-vm"], kind: kind)) }
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test读取撤权不解除未知保护() async throws {
        let (model, _, _, root) = try make(mode: "vmm-accepted-offline"); await model.refresh()
        let id = try perform(model); await model.waitForOperation(id)
        let (next, transport, gate, _) = try make(mode: "vmm-recover", root: root); await gate.set(false); await next.refresh()
        XCTAssertEqual(next.entries.first?.items.first?.phase, .submitted)
        let calls = await transport.calls; XCTAssertTrue(calls.isEmpty)
    }
    func test证书失败停止恢复读取与批量后项() async throws {
        let (model, transport, _, _) = try make(); await model.refresh(); await transport.setMode("vmm-write-trust")
        let id = try perform(model, .powerOn, ids: ["synthetic-vm", "worker-b"]); await model.waitForOperation(id)
        XCTAssertEqual(model.error, .trust); XCTAssertFalse(model.allowed)
        XCTAssertEqual(model.entries.first?.items.map(\.phase), [.submitted, .skipped])
        let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "poweron")
    }
    func test记录损坏保存失败及丢失不得重新提交() async throws {
        for corrupt in [false, true] {
            let root = newRoot()
            if corrupt {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("invalid".utf8).write(to: root.appendingPathComponent("virtual-machine-controls-v1.json"))
            } else { try Data("file".utf8).write(to: root) }
            let (model, transport, _, _) = try make(root: root); await model.refresh()
            XCTAssertTrue(model.recovery.failed); XCTAssertFalse(model.canPerform(ids: ["synthetic-vm"], kind: .delete))
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
        let (model, transport, _, root) = try make(mode: "vmm-unknown"); await model.refresh()
        let id = try perform(model); await model.waitForOperation(id)
        try FileManager.default.removeItem(at: root.appendingPathComponent("virtual-machine-controls-v1.json"))
        await transport.setMode("vmm-control"); await model.refresh()
        XCTAssertTrue(model.recovery.failed); XCTAssertEqual(model.entries.first?.items.first?.phase, .submitted)
    }
    func test恢复记录只含摘要不含真实名称账号地址凭据() async throws {
        let (model, _, _, root) = try make(); await model.refresh()
        let id = try perform(model); await model.waitForOperation(id)
        let text = try String(contentsOf: root.appendingPathComponent("virtual-machine-controls-v1.json"), encoding: .utf8)
        for forbidden in ["synthetic-vm", "Sample virtual machine", "fixture.example.invalid", "operator", "synthetic-session"] { XCTAssertFalse(text.contains(forbidden)) }
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
    func test未知原对象改名仍按编号保护() async throws {
        let (model, transport, _, _) = try make(mode: "vmm-unknown"); await model.refresh()
        let id = try perform(model); await model.waitForOperation(id)
        await transport.setMode("vmm-control"); await transport.renameFirst(); await model.refresh()
        XCTAssertFalse(model.canPerform(ids: ["synthetic-vm"], kind: .powerOn))
        XCTAssertFalse(model.canPerform(ids: ["synthetic-vm"], kind: .delete))
    }
    func test编辑草稿保留缺失值与半GiB内存且只提交变化() {
        let unknown = VirtualMachineSettingsState(id: "vm", name: "Sample", status: "shutdown")
        var empty = MobileVirtualMachineSettingsDraft(unknown)
        XCTAssertNil(empty.cpuCount); XCTAssertNil(empty.memoryMiB); XCTAssertNil(empty.cpuWeight); XCTAssertNil(empty.startupBehavior)
        XCTAssertFalse(empty.hasChanges); empty.name = "Renamed"
        XCTAssertTrue(empty.isValid); XCTAssertNil(empty.update.memoryMiB); XCTAssertNil(empty.update.cpuCount)
        let known = VirtualMachineSettingsState(id: "vm", name: "Sample", status: "running", description: "old", cpuCount: 1, memoryMiB: 512, cpuWeight: 128, startupBehavior: .restorePreviousState)
        var draft = MobileVirtualMachineSettingsDraft(known)
        XCTAssertEqual(draft.memoryMiB, 512); XCTAssertEqual(draft.cpuWeight, 128)
        draft.description = ""; draft.memoryMiB = 2048
        XCTAssertEqual(draft.update.description, ""); XCTAssertNil(draft.update.memoryMiB); XCTAssertNil(draft.update.cpuWeight)
        var invalid = MobileVirtualMachineSettingsDraft(unknown); invalid.cpuCount = 0; XCTAssertFalse(invalid.isValid)
    }
    func test编辑全部字段保持精确单位与逐阶段结果() async throws {
        let (model, transport, _, _) = try make(internalAPI: true); await model.refresh()
        XCTAssertTrue(model.canEdit(id: "synthetic-vm"))
        let target = try await model.loadSettings(id: "synthetic-vm", activation: model.activation)
        XCTAssertEqual(target.memoryMiB, 512)
        let id = try XCTUnwrap(model.saveSettings(target, configuration: .init(name: "Renamed", description: "", cpuCount: 4, memoryMiB: 1536,
            cpuWeight: 1024, startupBehavior: .restorePreviousState), activation: model.activation))
        await model.waitForOperation(id)
        XCTAssertEqual(model.recovery.entry(id)?.items.first?.phase, .succeeded)
        XCTAssertEqual(model.targets.first?.name, "Renamed")
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes[0]["vram_size"], "1536"); XCTAssertEqual(writes[0]["cpu_weight"], "1024")
        XCTAssertEqual(writes[0]["autorun"], "1"); XCTAssertEqual(writes[0]["version"], "1")
    }
    func test编辑丢回执或已接受跨重启只读恢复并阻止交叉操作() async throws {
        for accepted in [false, true] {
            let (model, transport, _, root) = try make(mode: accepted ? "vmm-accepted-offline" : "vmm-unknown", internalAPI: true)
            await model.refresh(); let target = try await model.loadSettings(id: "synthetic-vm", activation: model.activation)
            let id = try XCTUnwrap(model.saveSettings(target, configuration: .init(description: "Updated synthetic description"), activation: model.activation))
            await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.items.first?.phase, .submitted)
            XCTAssertEqual(model.recovery.entry(id)?.items.first?.accepted, accepted)
            let (next, fresh, _, _) = try make(mode: "vmm-settings-recovered", root: root, internalAPI: true); await next.refresh()
            XCTAssertEqual(next.recovery.entry(id)?.items.first?.phase, accepted ? .succeeded : .submitted)
            XCTAssertEqual(next.canEdit(id: "synthetic-vm"), accepted)
            XCTAssertEqual(next.canPerform(ids: ["synthetic-vm"], kind: .powerOn), accepted)
            XCTAssertEqual(next.canPerform(ids: ["synthetic-vm"], kind: .delete), accepted)
            let writes = await transport.writes, newWrites = await fresh.writes
            XCTAssertEqual(writes.count, 1); XCTAssertTrue(newWrites.isEmpty)
        }
    }
    func test编辑表单打开后状态字段变化或撤权零写() async throws {
        for change in ["state", "field", "denied"] {
            let (model, transport, gate, _) = try make(internalAPI: true); await model.refresh()
            let target = try await model.loadSettings(id: "synthetic-vm", activation: model.activation)
            if change == "state" { await transport.apply(.powerOn) }
            else if change == "field" { await transport.setSettings(["desc": "Changed elsewhere"]) }
            else { await gate.set(false) }
            let id = try XCTUnwrap(model.saveSettings(target, configuration: .init(description: "new"), activation: model.activation))
            await model.waitForOperation(id)
            XCTAssertEqual(model.recovery.entry(id)?.items.first?.phase, .failed)
            XCTAssertEqual(model.recovery.entry(id)?.items.first?.failure, change == "denied" ? .denied : .changed)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test编辑重复点击和电源删除在途均不进入请求() async throws {
        let (model, transport, _, _) = try make(internalAPI: true); await model.refresh()
        let target = try await model.loadSettings(id: "synthetic-vm", activation: model.activation)
        await transport.holdWrites()
        let id = try XCTUnwrap(model.saveSettings(target, configuration: .init(description: "new"), activation: model.activation))
        await transport.waitForWrite()
        XCTAssertFalse(model.canEdit(id: target.id)); XCTAssertFalse(model.canPerform(ids: [target.id], kind: .delete))
        XCTAssertFalse(model.canPerform(ids: [target.id], kind: .powerOn))
        XCTAssertNil(model.saveSettings(target, configuration: .init(description: "new"), activation: model.activation))
        await transport.release(); await model.waitForOperation(id)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test编辑证书失败停止后续请求并保留原记录() async throws {
        let (model, transport, _, _) = try make(internalAPI: true); await model.refresh()
        let target = try await model.loadSettings(id: "synthetic-vm", activation: model.activation)
        await transport.setMode("vmm-write-trust")
        let id = try XCTUnwrap(model.saveSettings(target, configuration: .init(description: "new"), activation: model.activation))
        await model.waitForOperation(id)
        XCTAssertEqual(model.error, .trust); XCTAssertEqual(model.recovery.entry(id)?.items.first?.phase, .submitted)
        let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "set")
    }
    func test编辑换账号旧回执不更新新界面且记录无字段明文() async throws {
        let (model, transport, _, root) = try make(internalAPI: true); await model.refresh()
        let activation = model.activation, context = model.context
        let target = try await model.loadSettings(id: "synthetic-vm", activation: activation)
        await transport.holdWrites()
        let id = try XCTUnwrap(model.saveSettings(target, configuration: .init(name: "Private VM", description: "Private notes"), activation: activation))
        await transport.waitForWrite()
        let nextProfile = try profile(username: "second"), next = MobileVirtualMachineUITransport()
        model.configure(profile: nextProfile, repository: try repository(next, profile: nextProfile, internalAPI: true), authorize: { true })
        await model.refresh(); await transport.release(); await model.waitForOperation(id)
        XCTAssertTrue(model.entries.isEmpty); XCTAssertEqual(model.recovery.entry(id)?.context, context)
        XCTAssertNil(model.saveSettings(target, configuration: .init(description: "new"), activation: activation))
        XCTAssertNil(model.error)
        let text = try String(contentsOf: root.appendingPathComponent("virtual-machine-controls-v1.json"), encoding: .utf8)
        for forbidden in ["Private VM", "Private notes", "synthetic-vm", "operator", "synthetic-session"] { XCTAssertFalse(text.contains(forbidden)) }
    }
    private func perform(_ model: MobileVirtualMachineControlModel, _ kind: MobileVirtualMachineControlStore.Kind = .powerOn,
                         ids: Set<String> = ["synthetic-vm"]) throws -> UUID {
        try XCTUnwrap(model.perform(try XCTUnwrap(model.confirmation(ids: ids, kind: kind))))
    }
    private func newRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VirtualMachineTests-\(UUID())"); roots.append(root); return root
    }
    private func profile(username: String = "operator") throws -> NasProfile {
        try .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000023")!, displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: username)
    }
    private func repository(_ transport: MobileVirtualMachineUITransport, profile: NasProfile, internalAPI: Bool = false) throws -> DsmServiceManagementRepository {
        let versions = internalAPI ? [DsmAPIName.virtualizationGuest: 2, DsmAPIName.virtualizationGuestAction: 1]
            : [DsmAPIName.virtualizationAPIGuest: 1, DsmAPIName.virtualizationAPIGuestAction: 1]
        let values = CapabilitySet(Dictionary(uniqueKeysWithValues: versions.map { name, version in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version))
        }))
        return try .init(profile: profile, capabilities: values,
                         session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func make(mode: String = "vmm-control", root: URL? = nil, internalAPI: Bool = false) throws -> (MobileVirtualMachineControlModel, MobileVirtualMachineUITransport, VirtualMachinePermissionGate, URL) {
        let root = root ?? newRoot(), transport = MobileVirtualMachineUITransport(mode: mode), gate = VirtualMachinePermissionGate(), profile = try profile()
        let model = MobileVirtualMachineControlModel(root: root)
        model.configure(profile: profile, repository: try repository(transport, profile: profile, internalAPI: internalAPI), authorize: { await gate.check() })
        return (model, transport, gate, root)
    }
}

private actor VirtualMachinePermissionGate {
    private var allowed = true
    func set(_ value: Bool) { allowed = value }
    func check() -> Bool { allowed }
}

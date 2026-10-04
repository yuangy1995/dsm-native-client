import XCTest

@MainActor
final class MobileWorkspaceUITests: XCTestCase {
    func test文件下载和设置可通过原生导航到达() {
        let app = launchFixture()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("activity", title: "Activity", in: app)
        let downloads = element("mobile.module.downloads", in: app)
        XCTAssertTrue(downloads.waitForExistence(timeout: 5))
        downloads.tap()
        XCTAssertTrue(app.staticTexts["Sample archive.zip"].waitForExistence(timeout: 8))
        navigate("more", title: "More", in: app)
        let settings = element("mobile.module.settings", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(element("mobile.settings.page", in: app).waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Workspace settings")
    }

    func test文件页加载空内容和错误均有实际呈现() {
        for state in ["loading", "empty", "error"] {
            let app = launchFixture(state: state)
            XCTAssertTrue(element("mobile.page.\(state)", in: app).waitForExistence(timeout: 8), state)
            attachScreenshot(app, name: "Files — \(state)")
            app.terminate()
        }
    }

    func test文件搜索无结果保持筛选状态() {
        let app = launchFixture()
        defer { app.terminate() }
        let folder = app.staticTexts["Sample folder"]
        XCTAssertTrue(folder.waitForExistence(timeout: 8))
        folder.tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 8))
        let search = app.searchFields.firstMatch
        if !search.exists {
            // iPad 的原生工具栏先呈现搜索按钮，点击后才创建输入框。
            let reveal = app.buttons.matching(NSPredicate(format: "label == 'Search' OR label == '搜索'")).firstMatch
            XCTAssertTrue(reveal.waitForExistence(timeout: 5))
            reveal.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("missing-fixture\n")
        XCTAssertTrue(element("mobile.page.filteredEmpty", in: app).waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Files — no search results")
    }

    func test目录上传在活动中显示逐项成功且重启保留() {
        let app = launchFixture(state: "upload")
        let start = element("mobile.upload.start", in: app)
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Sample upload/Sample upload.txt"].exists)
        start.tap()
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("activity", title: "Activity", in: app)
        let tasks = element("mobile.module.transfers", in: app)
        XCTAssertTrue(tasks.waitForExistence(timeout: 5))
        tasks.tap()
        XCTAssertTrue(app.staticTexts["Sample upload/Sample upload.txt"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Clear Finished Uploads"].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Folder upload completed")
        app.terminate()
        app.launchArguments.append("--ui-preserve-transfer-fixture")
        app.launch()
        navigate("activity", title: "Activity", in: app)
        let restoredTasks = element("mobile.module.transfers", in: app)
        XCTAssertTrue(restoredTasks.waitForExistence(timeout: 5))
        restoredTasks.tap()
        XCTAssertTrue(app.staticTexts["Sample upload/Sample upload.txt"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Clear Finished Uploads"].exists)
        app.buttons["Clear Finished Uploads"].tap()
        XCTAssertFalse(app.staticTexts["Sample upload/Sample upload.txt"].exists)
        app.terminate()
    }

    func test高级搜索通过文件夹选择应用条件并显示部分正文提示() {
        let app = launchFixture(state: "advanced")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        let filters = app.buttons["Sort and filter"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        filters.tap()
        let advanced = element("files.search.advanced", in: app)
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.tap()
        let name = element("files.search.name", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        if app.buttons["Continue"].waitForExistence(timeout: 1) { app.buttons["Continue"].tap() }
        name.typeText("term")
        let contents = app.switches["Search file contents"]
        XCTAssertTrue(contents.exists)
        // 系统开关的可访问性元素包含整行；点击右侧开关本体，避免只结束输入焦点。
        contents.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(contents.value as? String, "1")
        element("files.search.addLocation", in: app).tap()
        let folder = element("files.folder-picker.folder./fixture", in: app)
        XCTAssertTrue(folder.waitForExistence(timeout: 8))
        folder.tap()
        let choose = app.buttons["Choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.tap()
        let apply = element("files.search.apply", in: app)
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(apply.isEnabled)
        attachScreenshot(app, name: "Advanced search conditions")
        apply.tap()
        XCTAssertTrue(app.staticTexts["Filtered result.txt"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Search Filters Active"].exists)
        XCTAssertFalse(app.staticTexts["Storage Visible to This Account"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'not been indexed'")).firstMatch.exists)
        attachScreenshot(app, name: "Advanced search results")
    }

    func test原生压缩创建文件且活动保存完成结果() {
        let app = launchFixture(state: "archive")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        app.staticTexts["Sample folder"].tap()
        app.buttons["Actions for Sample archive.zip"].tap()
        app.buttons["Compress"].tap()
        XCTAssertTrue(element("files.archive.source./fixture/Sample archive.zip", in: app).waitForExistence(timeout: 5))
        let name = element("files.archive.name", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Created archive")
        attachScreenshot(app, name: "Compression form")
        element("files.archive.start-compression", in: app).tap()
        XCTAssertTrue(app.staticTexts["Created archive.zip"].waitForExistence(timeout: 8))
        navigate("activity", title: "Activity", in: app)
        element("mobile.module.transfers", in: app).tap()
        XCTAssertTrue(element("files.archive.phase.completed", in: app).waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Archive completed in Transfers")
    }

    func test原生压缩包浏览及解压完成() {
        let app = launchFixture(state: "archive")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        app.staticTexts["Sample folder"].tap()
        app.buttons["Actions for Sample archive.zip"].tap()
        app.buttons["Extract"].tap()
        XCTAssertTrue(app.staticTexts["Extracted document.txt"].waitForExistence(timeout: 8))
        let start = element("files.archive.start-extraction", in: app)
        XCTAssertTrue(start.isEnabled)
        attachScreenshot(app, name: "Archive contents and extraction options")
        start.tap()
        XCTAssertTrue(app.staticTexts["Sample archive"].waitForExistence(timeout: 8))
        navigate("activity", title: "Activity", in: app)
        element("mobile.module.transfers", in: app).tap()
        XCTAssertTrue(element("files.archive.phase.completed", in: app).waitForExistence(timeout: 8))
    }

    func testNAS原任务停止及移除记录需要确认并刷新() throws {
        let app = launchFixture(state: "archive")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("activity", title: "Activity", in: app)
        element("mobile.module.transfers", in: app).tap()
        let stop = app.buttons["Stop this task"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8)); stop.tap()
        let confirmations = app.buttons.matching(identifier: "Stop this task")
        let confirmation = try XCTUnwrap(confirmations.allElementsBoundByIndex.first(where: { $0.isHittable }))
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); confirmation.tap()
        let clear = app.buttons["Clear this record"]
        XCTAssertTrue(clear.waitForExistence(timeout: 8))
        attachScreenshot(app, name: "NAS task stopped")
        clear.tap()
        let clears = app.buttons.matching(identifier: "Clear this record")
        try XCTUnwrap(clears.allElementsBoundByIndex.first(where: { $0.isHittable })).tap()
        XCTAssertTrue(app.staticTexts["No transfer tasks yet"].waitForExistence(timeout: 8))
    }

    func test权限编辑保留继承规则并保存后重新读取() {
        let app = launchFixture(state: "permissions-acl")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        app.buttons["Actions for Inbox"].tap(); app.buttons["Owner and permissions"].tap()
        let rule = app.buttons["Sample member, Allow"]
        XCTAssertTrue(rule.waitForExistence(timeout: 8)); rule.tap()
        let write = app.switches["files.permissions.rule.0.write_data"]
        XCTAssertTrue(write.waitForExistence(timeout: 5))
        write.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        element("files.permissions.save", in: app).tap()
        XCTAssertTrue(app.staticTexts["These changes apply to this item and may change who can access it."].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Permission change confirmation")
        element("files.permissions.confirm", in: app).tap()
        XCTAssertTrue(app.staticTexts["Permissions saved."].waitForExistence(timeout: 8))
        XCTAssertEqual(write.value as? String, "1")
        attachScreenshot(app, name: "Explicit permissions saved")
    }

    func test基础权限修改需确认移除访问且准确回读() {
        let app = launchFixture(state: "permissions-posix")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        app.buttons["Actions for Sample document.txt"].tap(); app.buttons["Owner and permissions"].tap()
        let write = app.switches["files.permissions.posix.0.2"]
        XCTAssertTrue(write.waitForExistence(timeout: 8))
        write.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        element("files.permissions.save", in: app).tap()
        XCTAssertTrue(app.staticTexts["Some accounts will lose part or all of their current access."].waitForExistence(timeout: 5))
        element("files.permissions.confirm", in: app).tap()
        XCTAssertTrue(app.staticTexts["Permissions saved."].waitForExistence(timeout: 8))
        XCTAssertEqual(write.value as? String, "0")
        attachScreenshot(app, name: "Basic permissions saved")
    }

    func test共享根权限只读且仍可展开继承规则() {
        let app = launchFixture(state: "permissions-acl")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        app.buttons["Actions for Sample folder"].tap(); app.buttons["Owner and permissions"].tap()
        XCTAssertTrue(app.staticTexts["Permissions are read-only here. Manage permissions for this location in DSM."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["files.permissions.save"].isEnabled)
        let rule = app.buttons["Sample member, Allow"]
        XCTAssertTrue(rule.exists); rule.tap()
        XCTAssertFalse(app.switches["files.permissions.rule.0.write_data"].isEnabled)
        app.staticTexts["Sample member"].firstMatch.tap()
        let inherited = element("files.permissions.inherited.0", in: app)
        for _ in 0..<3 where !inherited.isHittable { app.swipeUp() }
        XCTAssertTrue(inherited.isHittable); inherited.tap()
        let inheritedRead = app.staticTexts["Read files / list folders"]
        for _ in 0..<3 where !inheritedRead.isHittable { app.swipeUp() }
        XCTAssertTrue(inheritedRead.waitForExistence(timeout: 5))
        XCTAssertTrue(inheritedRead.isHittable)
        attachScreenshot(app, name: "Shared root permissions remain read-only")
    }

    func test文件多选可批量创建并保留逐项链接() {
        let app = launchFixture(state: "sharing")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 5))
        let toolbar = element("files.toolbar.more", in: app)
        let toolbarExists = toolbar.waitForExistence(timeout: 5)
        attachScreenshot(app, name: "Batch selection toolbar")
        XCTAssertTrue(toolbarExists)
        toolbar.tap(); app.buttons["Select Items"].tap()
        app.staticTexts["Sample document.txt"].tap(); app.staticTexts["Inbox"].tap()
        let more = element("files.batch.more", in: app)
        XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
        app.buttons["Create sharing link"].tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].exists); XCTAssertTrue(app.staticTexts["Inbox"].exists)
        let submit = element("sharing.create.submit", in: app)
        for _ in 0..<3 where !submit.isHittable { app.swipeUp() }
        XCTAssertTrue(submit.isHittable); submit.tap()
        XCTAssertTrue(element("sharing.results", in: app).waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts.matching(identifier: "Completed").count, 2)
        XCTAssertTrue(app.buttons["Copy selected links"].exists)
        attachScreenshot(app, name: "Batch sharing links created")
    }

    func test分享创建文件收集后可展示二维码和返回管理() {
        let app = launchFixture(state: "sharing")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        app.staticTexts["Sample folder"].tap()
        let actions = app.buttons["Actions for Inbox"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5)); actions.tap()
        app.buttons["Create sharing link"].tap()
        let collection = app.switches["Create a file request link"]
        XCTAssertTrue(collection.waitForExistence(timeout: 5))
        collection.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let name = app.textFields["Collection name"]
        XCTAssertTrue(name.exists); name.tap(); name.typeText("Sample collection")
        let submit = element("sharing.create.submit", in: app)
        for _ in 0..<4 where !submit.isHittable { app.swipeUp() }
        XCTAssertTrue(submit.isHittable); submit.tap()
        let confirm = app.alerts.buttons["Create link"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.staticTexts["Link ready"].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "File collection link ready")
        app.buttons["Show QR code"].tap()
        XCTAssertTrue(app.images["Show QR code"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Local sharing QR code")
    }

    func test全部分享链接编辑密码并撤销原链接() {
        let app = launchFixture(state: "sharing")
        defer { app.terminate() }
        openAllSharing(app)
        let actions = element("sharing.row.more.fixture-existing", in: app)
        XCTAssertTrue(actions.waitForExistence(timeout: 5)); actions.tap()
        app.buttons["Edit shared links"].tap()
        let mode = element("sharing.edit.passwordMode", in: app)
        XCTAssertTrue(mode.waitForExistence(timeout: 5)); mode.tap()
        app.buttons["Set a new password"].tap()
        let password = element("sharing.edit.password", in: app)
        XCTAssertTrue(password.waitForExistence(timeout: 5)); password.tap(); password.typeText("synthetic-only")
        element("sharing.edit.save", in: app).tap()
        XCTAssertTrue(element("sharing.results", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Inbox, Completed"].exists)
        attachScreenshot(app, name: "Sharing password updated")
        app.buttons["Back to links"].tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 5)); actions.tap()
        app.buttons["Cancel sharing"].tap()
        let confirm = app.buttons["Cancel sharing"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.buttons["Back to links"].waitForExistence(timeout: 8)); app.buttons["Back to links"].tap()
        XCTAssertFalse(actions.exists)
        XCTAssertTrue(element("sharing.row.more.fixture-folder", in: app).exists)
        attachScreenshot(app, name: "Sharing original link removed")
    }

    func test分享访问次数可编辑并保留原链接() {
        let app = launchFixture(state: "sharing")
        defer { app.terminate() }
        openAllSharing(app)
        let actions = element("sharing.row.more.fixture-existing", in: app)
        XCTAssertTrue(actions.waitForExistence(timeout: 5)); actions.tap()
        app.buttons["Access and collection settings"].tap()
        let audience = element("sharing.access.audience", in: app)
        XCTAssertTrue(audience.waitForExistence(timeout: 5)); audience.tap()
        app.buttons["Selected users and groups"].tap()
        app.buttons["Choose users and groups"].tap()
        XCTAssertTrue(app.buttons["Sample member"].waitForExistence(timeout: 5)); app.buttons["Sample member"].tap()
        app.buttons["Done"].tap()
        let limit = app.switches["Change access limit"]
        XCTAssertTrue(limit.waitForExistence(timeout: 5)); limit.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let count = app.textFields["Access count"]
        XCTAssertTrue(count.exists); count.tap(); count.typeText(XCUIKeyboardKey.delete.rawValue + "5")
        element("sharing.access.save", in: app).tap()
        XCTAssertTrue(app.alerts.buttons["Save changes"].waitForExistence(timeout: 5)); app.alerts.buttons["Save changes"].tap()
        XCTAssertTrue(element("sharing.results", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Inbox, Completed"].exists)
        app.buttons["Back to links"].tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 5)); actions.tap(); app.buttons["Access and collection settings"].tap()
        XCTAssertTrue(limit.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Sharing access limit saved")
        limit.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(count.value as? String, "5")
    }

    func test远程位置可浏览原始目录并显示筛选为空() throws {
        let app = launchFixture(state: "remote")
        defer { app.terminate() }
        openRemoteLocations(app)
        app.buttons["files.remote.profile.fixture-remote"].tap()
        XCTAssertTrue(app.staticTexts["Remote sample.txt"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Download"].exists)
        attachScreenshot(app, name: "Remote directory and download")
        let search = app.searchFields["Filter files in this folder"]
        if !search.exists {
            let reveal = try XCTUnwrap(app.buttons.matching(NSPredicate(format: "label == 'Search' OR label == '搜索'"))
                .allElementsBoundByIndex.first(where: { $0.isHittable }))
            reveal.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("missing-file\n")
        XCTAssertTrue(app.staticTexts["No files to show"].waitForExistence(timeout: 5))
    }

    func test远程服务器完整地址创建断开再移除配置() {
        let app = launchFixture(state: "remote")
        defer { app.terminate() }
        openRemoteLocations(app)
        app.buttons["files.remote.add"].tap(); app.buttons["FTP, WebDAV and cloud connections"].tap()
        let alias = app.textFields["files.remote.vfs.alias"]
        XCTAssertTrue(alias.waitForExistence(timeout: 5)); alias.tap(); alias.typeText("New remote")
        let address = app.textFields["files.remote.vfs.hostname"]
        address.tap(); address.typeText("https://new.example.invalid:8443/webdav")
        attachScreenshot(app, name: "Remote server form")
        app.buttons["files.remote.vfs.save"].tap()
        let profile = app.buttons["files.remote.profile.fixture-created"]
        XCTAssertTrue(profile.waitForExistence(timeout: 8))
        app.buttons["files.remote.actions.fixture-created"].tap(); app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.alerts.staticTexts["You will need to reconnect to browse files. No files will be deleted."].exists)
        app.alerts.buttons["Disconnect"].tap()
        XCTAssertTrue(app.staticTexts["Disconnected"].waitForExistence(timeout: 8))
        app.buttons["files.remote.actions.fixture-created"].tap(); app.buttons["Remove connection"].tap()
        app.alerts.buttons["Remove connection"].tap()
        XCTAssertTrue(app.staticTexts["The connection change is complete."].waitForExistence(timeout: 8))
        XCTAssertFalse(profile.exists)
        attachScreenshot(app, name: "Saved remote connection removed")
    }

    func testSMB连接使用目录选择并断开后恢复普通目录() {
        let app = launchFixture(state: "remote")
        defer { app.terminate() }
        openRemoteLocations(app)
        app.buttons["files.remote.add"].tap(); app.buttons["SMB / NFS shared folder"].tap()
        let server = app.textFields["files.remote.mount.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 5)); server.tap(); server.typeText("remote.example.invalid")
        let folder = app.textFields["files.remote.mount.folder"]
        folder.tap(); folder.typeText("Media")
        element("files.remote.mount.destination", in: app).tap()
        chooseRemoteDestination(app)
        app.buttons["files.remote.mount.save"].tap()
        XCTAssertTrue(app.staticTexts["//remote.example.invalid/Media"].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "SMB connection created")
        app.buttons["files.remote.mount-actions./fixture/Inbox"].tap(); app.buttons["Disconnect"].tap()
        app.alerts.buttons["Disconnect"].tap()
        XCTAssertTrue(app.staticTexts["The connection change is complete."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["files.remote.mount-actions./fixture/Inbox"].exists)
    }

    func testISO选择空目录加载并可卸载() {
        let app = launchFixture(state: "remote")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        app.buttons["Actions for Sample image.iso"].tap(); app.buttons["Mount ISO"].tap()
        let destination = app.buttons["files.remote.iso.destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5)); destination.tap()
        chooseRemoteDestination(app)
        app.buttons["files.remote.iso.save"].tap()
        XCTAssertTrue(app.staticTexts["Sample image.iso"].waitForExistence(timeout: 8))
        element("files.toolbar.more", in: app).tap(); app.buttons["files.remote.manage"].tap()
        let unmount = app.buttons["Unmount ISO"]
        XCTAssertTrue(unmount.waitForExistence(timeout: 8)); unmount.tap()
        attachScreenshot(app, name: "ISO unmount consequence")
        app.buttons["files.remote.iso.save"].tap()
        XCTAssertTrue(app.staticTexts["The connection change is complete."].waitForExistence(timeout: 8))
        XCTAssertFalse(unmount.exists)
    }

    func test云授权使用系统浏览器且取消后返回原表单() throws {
        let app = launchFixture(state: "remote")
        defer { app.terminate() }
        openRemoteLocations(app)
        app.buttons["files.remote.add"].tap(); app.buttons["FTP, WebDAV and cloud connections"].tap()
        let type = element("files.remote.vfs.protocol", in: app)
        XCTAssertTrue(type.waitForExistence(timeout: 5)); type.tap(); app.buttons["Google Drive"].tap()
        app.buttons["Authorize cloud account"].tap()
        XCTAssertTrue(app.staticTexts["Sign in and authorize access on the cloud service page, then return here to save the connection."].waitForExistence(timeout: 5))
        // 仅打开官方公开授权起始页；不选择账号、不填写凭据、不授权或创建云连接。
        app.buttons["files.remote.cloud.start"].tap()
        XCTAssertTrue(app.buttons["URL"].waitForExistence(timeout: 8))
        let systemBrowser = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'BrowserView?'")).firstMatch
        let done = systemBrowser.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成", "Close", "关闭"])).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        attachScreenshot(app, name: "System browser cloud sign-in")
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["The sign-in page was closed before authorization completed. Close this window and try again."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["files.remote.cloud.start"].isEnabled)
        XCTAssertFalse(app.buttons["files.remote.cloud.save"].exists)
    }

    func test文件夹收藏可进入并从位置列表移除() {
        let app = launchFixture(state: "favorites")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        app.buttons["Actions for Sample folder"].tap(); app.buttons["add to favorites"].tap()
        XCTAssertTrue(app.staticTexts["Added to favorites."].waitForExistence(timeout: 8))
        app.buttons["Show locations"].tap()
        let row = app.buttons["files.favorite./fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 8))
        app.buttons["Show locations"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.press(forDuration: 1)
        app.buttons["Remove from favorites"].tap()
        XCTAssertTrue(app.staticTexts["Removed from favorites."].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Favorite removed from locations")
        XCTAssertFalse(row.exists)
    }

    func test文件收藏打开现有预览且不作为文件夹导航() {
        let app = launchFixture(state: "favorites")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        app.buttons["Actions for Sample document.txt"].tap(); app.buttons["add to favorites"].tap()
        XCTAssertTrue(app.staticTexts["Added to favorites."].waitForExistence(timeout: 8))
        app.buttons["Show locations"].tap()
        let row = app.buttons["files.favorite./fixture/Sample document.txt"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["No text content"].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Favorite file uses preview")
        XCTAssertFalse(app.alerts.staticTexts["Could not open location"].exists)
    }

    func test文件设置普通保存后可以继续修改并回读() {
        let app = launchFixture(state: "file-settings")
        defer { app.terminate() }
        openFileSettings(app); app.buttons["General"].tap()
        let toggle = app.switches["Record file transfers"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8)); XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let save = app.buttons["files.settings.save"]
        reveal(save, in: app); XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.staticTexts["Settings saved."].waitForExistence(timeout: 8)); XCTAssertFalse(save.isEnabled)
        app.swipeDown(); app.swipeDown()
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        reveal(save, in: app); XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.staticTexts["Settings saved."].waitForExistence(timeout: 8)); XCTAssertFalse(save.isEnabled)
        attachScreenshot(app, name: "File settings saved twice")
    }

    func test文件设置扩大账号权限显示后果且取消不会保存() {
        let app = launchFixture(state: "file-settings")
        defer { app.terminate() }
        openFileSettings(app); app.buttons["Remote access"].tap()
        app.buttons["Manage account permissions"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample member'")).firstMatch.waitForExistence(timeout: 8))
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample member'")).firstMatch.tap()
        let toggle = app.switches["Allow remote connections"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        app.buttons["files.settings.save"].tap()
        XCTAssertTrue(app.staticTexts["More accounts will be able to use remote connections."].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["files.settings.save"].isEnabled)
        app.buttons["files.settings.save"].tap()
        // 系统将同一警告按钮暴露为外层和 SwiftUI 子元素，限定警告作用域。
        app.alerts.buttons["files.settings.confirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample member' AND label CONTAINS 'Access allowed'")).firstMatch.waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Remote access saved with explicit consequence")
    }

    func test限速保留群组继承并可用触控编辑每周时间表() {
        let app = launchFixture(state: "file-settings")
        defer { app.terminate() }
        openFileSettings(app); app.buttons["Speed limits"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample member'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8)); XCTAssertTrue(row.label.contains("Use group limits")); row.tap()
        XCTAssertFalse(app.buttons["files.settings.save"].isEnabled)
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'When to apply speed limits'")).firstMatch.tap()
        app.buttons["Follow a schedule"].tap()
        app.buttons["Follow a schedule"].tap()
        let hour = app.buttons["files.settings.hour.0"]
        XCTAssertTrue(hour.waitForExistence(timeout: 5)); XCTAssertTrue(hour.label.contains("Default limit"))
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Apply to selected hours'")).firstMatch.tap()
        app.buttons["Custom limit"].tap(); hour.tap()
        XCTAssertTrue(hour.label.contains("Custom limit"))
        attachScreenshot(app, name: "Accessible hourly bandwidth schedule")
        app.navigationBars["Follow a schedule"].buttons["BackButton"].tap()
        reveal(app.buttons["files.settings.save"], in: app); app.buttons["files.settings.save"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 8)); XCTAssertTrue(row.label.contains("Follow a schedule"))
    }

    func test分享页面选择内置背景后保存并保留外观() {
        let app = launchFixture(state: "file-settings")
        defer { app.terminate() }
        openFileSettings(app); app.buttons["Sharing page"].tap()
        XCTAssertTrue(app.buttons["Choose background"].waitForExistence(timeout: 8)); app.buttons["Choose background"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Image source'")).firstMatch.tap()
        app.buttons["Built-in backgrounds"].tap()
        app.buttons["Background 1"].tap()
        let choose = app.buttons["Use this image"]
        reveal(choose, in: app); XCTAssertTrue(choose.isEnabled); choose.tap()
        XCTAssertEqual(app.switches["Use a custom background"].value as? String, "1")
        let save = app.buttons["files.settings.save"]; reveal(save, in: app); XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.staticTexts["Settings saved."].waitForExistence(timeout: 8))
        attachScreenshot(app, name: "Sharing page background applied")
    }

    func test文件设置读取错误和普通账号只读有实际呈现() {
        for state in ["file-settings-error", "file-settings-readonly", "file-settings-loading"] {
            let app = launchFixture(state: state)
            openFileSettings(app); app.buttons["General"].tap()
            if state.hasSuffix("loading") {
                XCTAssertTrue(element("files.settings.loading", in: app).waitForExistence(timeout: 8))
            } else if state.hasSuffix("error") {
                XCTAssertTrue(app.staticTexts["Could not load these settings"].waitForExistence(timeout: 8)); XCTAssertTrue(app.buttons["Retry"].exists)
            } else {
                let toggle = app.switches["Record file transfers"]
                XCTAssertTrue(toggle.waitForExistence(timeout: 8)); XCTAssertFalse(toggle.isEnabled)
                reveal(app.buttons["files.settings.save"], in: app); XCTAssertFalse(app.buttons["files.settings.save"].isEnabled)
            }
            attachScreenshot(app, name: state); app.terminate()
        }
    }

    func test限速名单空内容和搜索无结果提供恢复路径() {
        let app = launchFixture(state: "file-settings")
        defer { app.terminate() }
        openFileSettings(app); app.buttons["Speed limits"].tap()
        let type = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Account type'")).firstMatch
        XCTAssertTrue(type.waitForExistence(timeout: 8)); type.tap(); app.buttons["Local groups"].tap()
        XCTAssertTrue(app.staticTexts["No accounts were returned for this type. Choose another account type or refresh."].waitForExistence(timeout: 5))
        type.tap(); app.buttons["Local accounts"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample member'")).firstMatch.waitForExistence(timeout: 5))
        let search = app.searchFields["Search accounts"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("missing-fixture")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sample member'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Try another search or ask an administrator to check your access to the account list."].exists)
        attachScreenshot(app, name: "Bandwidth list filtered empty")
    }

    private func openFileSettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        element("files.toolbar.more", in: app).tap(); app.buttons["files.settings.open"].tap()
        XCTAssertTrue(app.buttons["General"].waitForExistence(timeout: 5))
    }
    private func reveal(_ item: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<7 { if item.exists && item.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(item.exists && item.isHittable)
    }

    private func openRemoteLocations(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        element("files.toolbar.more", in: app).tap(); app.buttons["files.remote.manage"].tap()
        XCTAssertTrue(app.buttons["files.remote.profile.fixture-remote"].waitForExistence(timeout: 8))
    }
    private func chooseRemoteDestination(_ app: XCUIApplication) {
        let share = element("files.folder-picker.folder./fixture", in: app)
        XCTAssertTrue(share.waitForExistence(timeout: 5)); share.tap()
        let folder = element("files.folder-picker.folder./fixture/Inbox", in: app)
        XCTAssertTrue(folder.waitForExistence(timeout: 5)); folder.tap()
        app.buttons["Choose"].tap()
    }

    private func openAllSharing(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        element("files.toolbar.more", in: app).tap()
        element("files.sharing.all", in: app).tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 8))
    }

    func test批量复制文件和文件夹逐项成功且源内容保留() {
        let app = launchFixture(state: "copy-move")
        defer { app.terminate() }
        beginCopyMoveBatch(app, move: false)
        XCTAssertTrue(app.staticTexts["Batch complete"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Completed: 2 · Failed: 0 · Result unavailable: 0 · Cancelled: 0 · Not started: 0"].exists)
        XCTAssertTrue(app.staticTexts["Sample document.txt"].exists); XCTAssertTrue(app.staticTexts["Inbox"].exists)
        attachScreenshot(app, name: "Mixed file and folder copy results")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Inbox"].exists)
    }

    func test批量移动文件和文件夹后源列表为空() {
        let app = launchFixture(state: "copy-move")
        defer { app.terminate() }
        beginCopyMoveBatch(app, move: true)
        XCTAssertTrue(app.staticTexts["Completed: 2 · Failed: 0 · Result unavailable: 0 · Cancelled: 0 · Not started: 0"].waitForExistence(timeout: 10))
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["This position is empty"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "Move refreshes the source folder")
    }

    func test批量同名冲突保留失败原因并继续其他文件夹() {
        let app = launchFixture(state: "copy-conflict")
        defer { app.terminate() }
        beginCopyMoveBatch(app, move: false)
        XCTAssertTrue(app.staticTexts["Completed: 1 · Failed: 1 · Result unavailable: 0 · Cancelled: 0 · Not started: 0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sample document.txt, An item with this name already exists"].exists)
        XCTAssertTrue(app.staticTexts["Inbox, Completed"].exists)
        attachScreenshot(app, name: "Partial copy keeps per-item outcomes")
    }

    func test批量未知结果保留未开始项且重启不重放() {
        let app = launchFixture(state: "copy-unknown")
        defer { app.terminate() }
        beginCopyMoveBatch(app, move: false)
        XCTAssertTrue(app.staticTexts["Completed: 0 · Failed: 0 · Result unavailable: 1 · Cancelled: 0 · Not started: 1"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Sample document.txt, Not started"].exists)
        attachScreenshot(app, name: "Unknown copy stops remaining items")
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch()
        beginCopyMoveBatch(app, move: false)
        XCTAssertTrue(app.staticTexts["Result unavailable"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(element("files.copy-move.submit", in: app).exists)
    }

    func test批量复制无写入权限显示逐项失败与恢复说明() {
        let app = launchFixture(state: "copy-readonly")
        defer { app.terminate() }
        beginCopyMoveBatch(app, move: false)
        XCTAssertTrue(app.staticTexts["Completed: 0 · Failed: 2 · Result unavailable: 0 · Cancelled: 0 · Not started: 0"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Inbox, No permission"].exists)
        XCTAssertTrue(app.staticTexts["Sample document.txt, No permission"].exists)
        XCTAssertTrue(app.staticTexts["You don’t have permission to use this destination. Choose another folder or ask an administrator for access."].exists)
        attachScreenshot(app, name: "Copy respects actual destination permissions")
    }

    func test文件夹下载ZIP后打开系统保存面板() {
        let app = launchFixture(state: "download-archive"); defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        let menu = app.buttons["Actions for Inbox"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
        element("files.item.download-archive", in: app).tap()
        XCTAssertTrue(element("mobile.documents.export-panel", in: app).waitForExistence(timeout: 10))
        let save = app.buttons.matching(NSPredicate(format: "label == 'Save' OR label == '保存'")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        attachScreenshot(app, name: "Folder ZIP system export")
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == '取消'")).firstMatch
        if !cancel.exists {
            let back = app.buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        }
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        XCTAssertTrue(app.staticTexts["Inbox"].waitForExistence(timeout: 5))
    }

    func test只读文件夹和多文件可打包并交给系统分享() {
        let app = launchFixture(state: "download-readonly"); defer { app.terminate() }
        beginDownloadSelection(app, singleFile: false)
        element("files.batch.more", in: app).tap()
        let share = element("files.batch.share", in: app)
        XCTAssertTrue(share.isEnabled); share.tap()
        XCTAssertTrue(element("ActivityListView", in: app).waitForExistence(timeout: 10))
        let title = element("LP.CaptionBar.TopCaption", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 10)); XCTAssertEqual(title.label, "2 items")
        XCTAssertTrue(element("LP.CaptionBar.BottomCaption", in: app).label.contains("ZIP"))
        attachScreenshot(app, name: "Read-only mixed selection ZIP share")
        app.buttons["header.closeButton"].tap()
        XCTAssertFalse(element("ActivityListView", in: app).exists)
    }

    func test多选仅一个文件保持原格式且下载失败能从活动重试() {
        let app = launchFixture(state: "download-failure"); defer { app.terminate() }
        beginDownloadSelection(app, singleFile: true)
        element("files.batch.more", in: app).tap(); element("files.batch.download", in: app).tap()
        // 错误文案及重试入口由现有前台下载流程提供。
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        attachScreenshot(app, name: "Download failure recovery")
        app.alerts.buttons.firstMatch.tap()
        navigate("activity", title: "Activity", in: app)
        element("mobile.module.transfers", in: app).tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Start Over"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["1 items.zip"].exists)
    }

    private func beginDownloadSelection(_ app: XCUIApplication, singleFile: Bool) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 5))
        element("files.toolbar.more", in: app).tap(); app.buttons["Select Items"].tap()
        app.staticTexts["Sample document.txt"].tap()
        if !singleFile { app.staticTexts["Inbox"].tap() }
    }

    func test批量删除文件和文件夹明确后果且刷新源列表() {
        let app = launchFixture(state: "recycle-delete"); defer { app.terminate() }
        beginRecycleBatch(app, restore: false)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "The selected items and folder contents will be deleted. Depending on the NAS recycle bin settings, they may be permanently deleted.")).firstMatch.exists)
        element("files.recycle.submit", in: app).tap()
        XCTAssertTrue(app.staticTexts["Completed: 2 · Failed: 0 · Result unavailable: 0 · Cancelled: 0 · Not started: 0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Inbox, Completed"].exists)
        attachScreenshot(app, name: "Delete per-item results")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["This position is empty"].waitForExistence(timeout: 5))
    }

    func test批量永久删除回收站项目明确无法恢复() {
        let app = launchFixture(state: "recycle-permanent"); defer { app.terminate() }
        beginRecycleBatch(app, restore: false, recycle: true)
        XCTAssertTrue(app.staticTexts["These items are in the recycle bin. Deleting them also deletes all folder contents and cannot be undone."].exists)
        attachScreenshot(app, name: "Permanent deletion consequence")
        element("files.recycle.submit", in: app).tap()
        XCTAssertTrue(app.staticTexts["Completed: 2 · Failed: 0 · Result unavailable: 0 · Cancelled: 0 · Not started: 0"].waitForExistence(timeout: 10))
    }

    func test批量恢复文件夹和文件返回原位置并保留同名冲突() {
        let app = launchFixture(state: "recycle-restore-conflict"); defer { app.terminate() }
        beginRecycleBatch(app, restore: true, recycle: true)
        element("files.recycle.submit", in: app).tap()
        XCTAssertTrue(app.staticTexts["Completed: 1 · Failed: 1 · Result unavailable: 0 · Cancelled: 0 · Not started: 0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Inbox, Completed"].exists)
        XCTAssertTrue(app.staticTexts["Sample document.txt, The item or destination changed"].exists)
        attachScreenshot(app, name: "Restore keeps existing destination")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Inbox"].exists)
    }

    func test批量删除无权限零写并提供恢复方法() {
        let app = launchFixture(state: "recycle-readonly"); defer { app.terminate() }
        beginRecycleBatch(app, restore: false); element("files.recycle.submit", in: app).tap()
        XCTAssertTrue(app.staticTexts["Completed: 0 · Failed: 2 · Result unavailable: 0 · Cancelled: 0 · Not started: 0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Inbox, You don’t have permission"].exists)
        XCTAssertTrue(app.staticTexts["Your account can’t change this item. Ask an administrator for access, then refresh the folder."].exists)
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Inbox"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sample document.txt"].exists)
    }

    func test批量删除未知停止余项且重启不重放() {
        let app = launchFixture(state: "recycle-unknown"); defer { app.terminate() }
        beginRecycleBatch(app, restore: false); element("files.recycle.submit", in: app).tap()
        let summary = "Completed: 0 · Failed: 0 · Result unavailable: 1 · Cancelled: 0 · Not started: 1"
        XCTAssertTrue(app.staticTexts[summary].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sample document.txt, Not started"].exists)
        attachScreenshot(app, name: "Unknown deletion stops remaining items")
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch()
        beginRecycleBatch(app, restore: false); element("files.recycle.submit", in: app).tap()
        XCTAssertTrue(app.staticTexts[summary].waitForExistence(timeout: 6))
        XCTAssertFalse(element("files.recycle.submit", in: app).exists)
    }

    func test跨NAS混合复制与移动删源分开确认() {
        let app = launchFixture(state: "cross-copy"); defer { app.terminate() }
        beginCrossNAS(app, move: true)
        let start = app.buttons["files.cross.start"]
        XCTAssertTrue(start.isEnabled); start.tap()
        openTransfers(app)
        XCTAssertTrue(app.staticTexts["Copy Complete"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Sample NAS → Destination NAS"].exists)
        attachScreenshot(app, name: "Cross NAS verified copy before removal")
        let remove = app.buttons["files.cross.remove"]
        XCTAssertTrue(remove.exists); remove.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Remove the copied originals from “Sample NAS” and keep the copies on “Destination NAS”. Removal may be permanent. Do not edit these files at the same time.")).firstMatch.waitForExistence(timeout: 5))
        let confirmations = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Remove Originals", "files.cross.remove"))
        XCTAssertEqual(confirmations.count, 1)
        confirmations.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Move Complete"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["files.cross.remove"].exists)
        attachScreenshot(app, name: "Cross NAS move completed")
        navigate("files", title: "File", in: app)
        XCTAssertTrue(app.staticTexts["This position is empty"].waitForExistence(timeout: 8))
    }

    func test跨NAS断线刷新后继续未开始项目() {
        let app = launchFixture(state: "cross-unknown"); defer { app.terminate() }
        beginCrossNAS(app, move: false); app.buttons["files.cross.start"].tap()
        openTransfers(app)
        XCTAssertTrue(app.staticTexts["Transfer Interrupted"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["files.cross.resume"].exists)
        XCTAssertFalse(app.buttons["files.cross.remove"].exists)
        app.buttons["files.cross.refresh"].tap()
        let resume = app.buttons["files.cross.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 8)); resume.tap()
        XCTAssertTrue(app.staticTexts["Copy Complete"].waitForExistence(timeout: 12))
        attachScreenshot(app, name: "Cross NAS recovered without duplicate upload")
        app.terminate(); app.launchArguments.append("--ui-preserve-transfer-fixture"); app.launch()
        openTransfers(app)
        XCTAssertTrue(app.staticTexts["Copy Complete"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["files.cross.remove"].exists)
    }

    func test跨NAS重名和只读目标保留来源并给出恢复方法() {
        for state in ["cross-conflict", "cross-readonly"] {
            let app = launchFixture(state: state)
            beginCrossNAS(app, move: false); app.buttons["files.cross.start"].tap()
            let error = element("files.cross.error", in: app)
            XCTAssertTrue(error.waitForExistence(timeout: 8))
            XCTAssertTrue(error.label.contains(state == "cross-conflict" ? "same name" : "permissions"))
            XCTAssertTrue(app.buttons["files.cross.start"].isEnabled)
            attachScreenshot(app, name: state)
            app.terminate()
        }
    }

    private func beginCrossNAS(_ app: XCUIApplication, move: Bool) {
        beginDownloadSelection(app, singleFile: false)
        app.buttons["files.batch.more"].tap(); element("files.batch.cross-nas", in: app).tap()
        let destination = app.buttons["files.cross.destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 8)); destination.tap()
        let folder = app.buttons["files.folder-picker.folder./output"]
        XCTAssertTrue(folder.waitForExistence(timeout: 8)); folder.tap()
        app.buttons["Choose"].tap()
        if move { app.segmentedControls.buttons["Move to…"].tap() }
    }

    private func openTransfers(_ app: XCUIApplication) {
        navigate("activity", title: "Activity", in: app)
        let tasks = element("mobile.module.transfers", in: app)
        if tasks.waitForExistence(timeout: 5) { tasks.tap() }
    }

    private func beginRecycleBatch(_ app: XCUIApplication, restore: Bool, recycle: Bool = false) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        if recycle {
            XCTAssertTrue(app.staticTexts["#recycle"].waitForExistence(timeout: 5)); app.staticTexts["#recycle"].tap()
        }
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 5))
        element("files.toolbar.more", in: app).tap(); app.buttons["Select Items"].tap()
        app.staticTexts["Sample document.txt"].tap(); app.staticTexts["Inbox"].tap()
        element("files.batch.more", in: app).tap()
        let operation = element(restore ? "files.batch.restore" : "files.batch.delete", in: app)
        XCTAssertTrue(operation.waitForExistence(timeout: 5)); XCTAssertTrue(operation.isEnabled); operation.tap()
        XCTAssertTrue(element("files.recycle.submit", in: app).waitForExistence(timeout: 5))
    }

    private func beginCopyMoveBatch(_ app: XCUIApplication, move: Bool) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        XCTAssertTrue(app.staticTexts["Sample document.txt"].waitForExistence(timeout: 5))
        element("files.toolbar.more", in: app).tap(); app.buttons["Select Items"].tap()
        app.staticTexts["Sample document.txt"].tap(); app.staticTexts["Inbox"].tap()
        let operation = element(move ? "files.batch.move" : "files.batch.copy", in: app)
        XCTAssertTrue(operation.isEnabled); operation.tap()
        XCTAssertTrue(app.buttons["output"].waitForExistence(timeout: 5)); app.buttons["output"].tap()
        let submit = element("files.copy-move.submit", in: app)
        XCTAssertTrue(submit.waitForExistence(timeout: 5)); XCTAssertTrue(submit.isEnabled); submit.tap()
    }

    func testOffice预览并交给系统分享及文件选择器() {
        let app = launchFixture(state: "office-preview"); defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        XCTAssertTrue(app.staticTexts["Document.docx"].waitForExistence(timeout: 5)); app.staticTexts["Document.docx"].tap()
        let edit = element("files.office.preview.edit", in: app)
        XCTAssertTrue(edit.waitForExistence(timeout: 8))
        let rendered = app.staticTexts["Office preview sample"]
        XCTAssertTrue(rendered.waitForExistence(timeout: 15))
        attachScreenshot(app, name: "Office native Quick Look")
        edit.tap()
        XCTAssertTrue(app.staticTexts["Editing copy ready"].waitForExistence(timeout: 10))
        element("files.office.export", in: app).tap()
        XCTAssertTrue(element("ActivityListView", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("LP.CaptionBar.TopCaption", in: app).label.contains("Document"))
        attachScreenshot(app, name: "Office system editing handoff")
        app.buttons["header.closeButton"].tap()
        element("files.office.import", in: app).tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == '取消'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        attachScreenshot(app, name: "Office system document picker")
        cancel.tap()
        XCTAssertTrue(app.staticTexts["Editing copy ready"].waitForExistence(timeout: 5))
    }

    func testOffice主动保存并从活动中心继续编辑() {
        let app = launchFixture(state: "office-save"); defer { app.terminate() }
        openOfficeEditor(app)
        XCTAssertTrue(app.staticTexts["Changes ready to save"].waitForExistence(timeout: 10))
        element("files.office.save", in: app).tap()
        XCTAssertTrue(app.staticTexts["Changes saved to NAS"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("files.office.save", in: app).exists)
        attachScreenshot(app, name: "Office changes saved")
        app.buttons["Done"].tap(); openTransfers(app)
        let document = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'files.office.activity.'")).firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 8)); document.tap()
        XCTAssertTrue(app.staticTexts["Changes saved to NAS"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["files.office.import"].waitForExistence(timeout: 5))
    }

    func testOffice丢回执后刷新恢复且不显示再次保存() {
        let app = launchFixture(state: "office-unknown"); defer { app.terminate() }
        openOfficeEditor(app)
        XCTAssertTrue(element("files.office.save", in: app).waitForExistence(timeout: 10)); element("files.office.save", in: app).tap()
        XCTAssertTrue(app.staticTexts["Save not yet complete"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("files.office.save", in: app).exists)
        XCTAssertFalse(element("files.office.import", in: app).exists)
        XCTAssertFalse(element("files.office.discard", in: app).exists)
        element("files.office.refresh", in: app).tap()
        XCTAssertTrue(app.staticTexts["Changes saved to NAS"].waitForExistence(timeout: 10))
        attachScreenshot(app, name: "Office lost receipt recovery")
    }

    func testOffice冲突权限与相同内容保留正确操作() {
        for state in ["office-conflict", "office-readonly", "office-unchanged"] {
            let app = launchFixture(state: state)
            openOfficeEditor(app)
            if state == "office-unchanged" {
                XCTAssertTrue(app.staticTexts["Content unchanged. No save needed."].waitForExistence(timeout: 10))
                XCTAssertFalse(element("files.office.save", in: app).exists)
            } else {
                XCTAssertTrue(element("files.office.save", in: app).waitForExistence(timeout: 10)); element("files.office.save", in: app).tap()
                if state == "office-conflict" {
                    XCTAssertTrue(app.staticTexts["Original file changed"].waitForExistence(timeout: 10))
                    XCTAssertFalse(element("files.office.save", in: app).exists)
                } else {
                    let error = element("files.office.error", in: app)
                    XCTAssertTrue(error.waitForExistence(timeout: 10)); XCTAssertTrue(error.label.contains("permission"))
                }
            }
            XCTAssertTrue(element("files.office.export", in: app).isEnabled)
            attachScreenshot(app, name: state); app.terminate()
        }
    }

    private func openOfficeEditor(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8)); app.staticTexts["Sample folder"].tap()
        let actions = app.buttons["Actions for Document.docx"]
        XCTAssertTrue(actions.waitForExistence(timeout: 8)); actions.tap()
        let edit = element("files.office.open", in: app)
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
    }

    private func launchFixture(state: String = "content") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", "en"]
        app.launchEnvironment["LANSTASH_UI_STATE"] = state
        app.launch()
        return app
    }

    private func navigate(_ destination: String, title: String, in app: XCUIApplication) {
        // iPhone 的系统标签栏按本地化标题暴露，iPad 侧栏使用稳定标识。
        let tab = app.tabBars.buttons[title]
        if tab.exists { tab.tap() }
        else {
            let item = element("mobile.navigation.\(destination)", in: app)
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            item.tap()
        }
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}

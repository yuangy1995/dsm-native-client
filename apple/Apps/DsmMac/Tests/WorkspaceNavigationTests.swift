import DsmCore
@testable import DsmMacExecutable
import XCTest

final class WorkspaceNavigationTests: XCTestCase {
    func test照片子页面与浏览模式保持一一对应() {
        XCTAssertEqual(PhotoWorkspacePage(rawValue: "timeline"), .timeline)
        XCTAssertEqual(PhotoWorkspacePage(rawValue: "albums"), .albums)
        XCTAssertEqual(PhotoWorkspacePage(rawValue: "folders"), .folders)
        XCTAssertEqual(PhotoWorkspacePage.timeline.photosSection, .timeline)
        XCTAssertEqual(PhotoWorkspacePage.albums.photosSection, .albums)
        XCTAssertEqual(PhotoWorkspacePage.folders.photosSection, .folders)
    }

    func test工作区子页面使用稳定且唯一的导航标识() {
        let sections = PhotoWorkspacePage.allCases.map(WorkspaceSection.photos)
            + ContainerManagerPane.allCases.map(WorkspaceSection.containerManager)
            + VirtualMachineManagerPane.allCases.map(WorkspaceSection.virtualMachineManager)
        let identifiers = sections.map(\.id)

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func test工作区子页面归入正确模块() {
        XCTAssertTrue(WorkspaceSection.photos(.albums).belongsToPhotosModule)
        XCTAssertTrue(
            WorkspaceSection.containerManager(.images)
                .belongsToContainerManagerModule
        )
        XCTAssertTrue(
            WorkspaceSection.virtualMachineManager(.protection)
                .belongsToVirtualMachineManagerModule
        )

        XCTAssertFalse(WorkspaceSection.chat.belongsToPhotosModule)
        XCTAssertFalse(
            WorkspaceSection.downloadStation.belongsToContainerManagerModule
        )
        XCTAssertFalse(
            WorkspaceSection.settings.belongsToVirtualMachineManagerModule
        )
    }
}

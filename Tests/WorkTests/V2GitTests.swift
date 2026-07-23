import Foundation
import XCTest
@testable import Work

final class V2GitTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atelier-v2-git-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testInitializeRepositoryNotifiesAfterGitIsReady() async throws {
        let notified = expectation(description: "repository-initialized notification")
        let expectedPath = temporaryDirectory.path
        let observer = NotificationCenter.default.addObserver(
            forName: V2Git.repositoryInitialized,
            object: nil,
            queue: nil
        ) { notification in
            if notification.object as? String == expectedPath {
                notified.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let result = await V2Git.initializeRepository(cwd: expectedPath)

        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent(".git").path))
        await fulfillment(of: [notified], timeout: 1)
    }
}

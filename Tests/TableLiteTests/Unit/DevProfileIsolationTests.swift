import XCTest
@testable import TableLite

/// 隔离 profile 真的隔离了数据与偏好（`docs/tech-designs/15-testing.md` §9.1）。
///
/// 这是本次基建风险最高的保证：调试实例绝不能写真实目录、也不能写标准 `UserDefaults` 域。
@MainActor
final class DevProfileIsolationTests: XCTestCase {

    private var temporaryRoot: URL!
    private var suiteName: String!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableLiteDevProfile-\(UUID().uuidString)", isDirectory: true)
        suiteName = "com.graycarl.tablelite.devtest.\(UUID().uuidString.lowercased())"
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        temporaryRoot = nil
        suiteName = nil
    }

    func testPreferencesGoToDevSuiteOnly() throws {
        let standard = UserDefaults.standard
        let standardBefore = standard.integer(forKey: "grid.pageSize")

        let environment = try AppEnvironment.live(dataDirectory: temporaryRoot, defaultsSuite: suiteName)
        XCTAssertTrue(environment.isDevProfile)
        XCTAssertEqual(environment.defaultsSuiteName, suiteName)
        XCTAssertEqual(environment.layout.rootDirectory.standardizedFileURL,
                       temporaryRoot.standardizedFileURL)
        // 窗口 frame 走标准域，必须靠后缀隔离（S51 的例外项）。
        XCTAssertTrue(environment.windowFrameAutosaveName.hasSuffix("-dev"))

        environment.preferences.rowLimit = 777

        let devDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(devDefaults.integer(forKey: "grid.pageSize"), 777)
        XCTAssertEqual(standard.integer(forKey: "grid.pageSize"), standardBefore)
    }

    func testConnectionFilesLandInDevDirectory() async throws {
        let environment = try AppEnvironment.live(dataDirectory: temporaryRoot, defaultsSuite: suiteName)
        let connection = Connection(name: "demo", mysql: MySQLConfig(host: "127.0.0.1", port: 13307, user: "root"))
        _ = try await environment.connections.upsert(connection)

        let expected = temporaryRoot.appendingPathComponent("connections.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: expected.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testRejectsIncompleteProfile() {
        XCTAssertThrowsError(try AppEnvironment.live(dataDirectory: temporaryRoot, defaultsSuite: nil))
        XCTAssertThrowsError(try AppEnvironment.live(dataDirectory: nil, defaultsSuite: suiteName))
    }

    func testRejectsUnusableSuite() {
        XCTAssertThrowsError(try AppEnvironment.live(dataDirectory: temporaryRoot, defaultsSuite: ""))
    }
}

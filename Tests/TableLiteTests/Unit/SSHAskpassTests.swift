import XCTest
@testable import TableLite

/// SSH_ASKPASS 机制：口令经环境变量传入，不写进脚本文件。
///
/// 见 `docs/tech-designs/04-ssh-tunnel.md` §5、L6。
final class SSHAskpassTests: XCTestCase {

    func testScriptReadsSecretFromEnvironmentOnly() {
        let content = SSHAskpassScript.scriptContent()
        XCTAssertTrue(content.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(content.contains("$\(SSHAskpassScript.secretEnvironmentKey)"))
        // 脚本里不能出现任何字面口令。
        XCTAssertFalse(content.contains("s3cret"))
    }

    func testEnvironmentForcesAskpass() {
        let environment = SSHAskpassScript.makeEnvironment(secret: "s3cret", scriptPath: "/tmp/x/askpass.sh")
        XCTAssertEqual(environment["SSH_ASKPASS"], "/tmp/x/askpass.sh")
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(environment[SSHAskpassScript.secretEnvironmentKey], "s3cret")
    }

    func testCreateWritesPrivateScript() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableLiteAskpassTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let script = try SSHAskpassScript.create(secret: "topsecret", baseDirectory: base)
        defer { script.remove() }

        XCTAssertTrue(FileManager.default.fileExists(atPath: script.scriptURL.path))
        XCTAssertEqual(script.environment[SSHAskpassScript.secretEnvironmentKey], "topsecret")

        let attributes = try FileManager.default.attributesOfItem(atPath: script.scriptURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)

        // 口令不落盘。
        let onDisk = try String(contentsOf: script.scriptURL, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("topsecret"))
    }

    func testRemoveDeletesDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableLiteAskpassTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let script = try SSHAskpassScript.create(secret: "x", baseDirectory: base)
        script.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.scriptURL.path))

        // 幂等。
        script.remove()
    }
}

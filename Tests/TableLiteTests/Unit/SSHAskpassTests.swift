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

    // MARK: 私钥是否加密（`specs/10-ssh-tunnel.md` §3.2）

    func testUnencryptedOpenSSHKeyIsNotEncrypted() {
        XCTAssertFalse(SSHPrivateKeyInspector.isEncrypted(pem: openSSHKeyPEM(cipher: "none")))
    }

    func testEncryptedOpenSSHKeyIsEncrypted() {
        XCTAssertTrue(SSHPrivateKeyInspector.isEncrypted(pem: openSSHKeyPEM(cipher: "aes256-ctr")))
    }

    func testPKCS8EncryptedHeaderIsEncrypted() {
        let pem = "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----\n"
        XCTAssertTrue(SSHPrivateKeyInspector.isEncrypted(pem: pem))
    }

    func testLegacyPEMEncryptedHeaderIsEncrypted() {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        Proc-Type: 4,ENCRYPTED
        DEK-Info: AES-128-CBC,0123456789ABCDEF

        AAAA
        -----END RSA PRIVATE KEY-----
        """
        XCTAssertTrue(SSHPrivateKeyInspector.isEncrypted(pem: pem))
    }

    func testReadsKeyFileFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableLiteKeyInspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plain = directory.appendingPathComponent("plain")
        try openSSHKeyPEM(cipher: "none").write(to: plain, atomically: true, encoding: .utf8)
        let encrypted = directory.appendingPathComponent("encrypted")
        try openSSHKeyPEM(cipher: "aes256-ctr").write(to: encrypted, atomically: true, encoding: .utf8)

        XCTAssertFalse(SSHPrivateKeyInspector.isEncrypted(path: plain.path))
        XCTAssertTrue(SSHPrivateKeyInspector.isEncrypted(path: encrypted.path))
        XCTAssertFalse(SSHPrivateKeyInspector.isEncrypted(path: directory.appendingPathComponent("missing").path))
    }

    // MARK: 辅助

    /// 构造一个足够让 inspector 读到 ciphername 的 OpenSSH 私钥文本。
    private func openSSHKeyPEM(cipher: String) -> String {
        var data = Data("openssh-key-v1\u{0}".utf8)
        let cipherData = Data(cipher.utf8)
        let length = UInt32(cipherData.count)
        data.append(UInt8((length >> 24) & 0xFF))
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(cipherData)
        data.append(Data(repeating: 0, count: 8))
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(data.base64EncodedString())\n-----END OPENSSH PRIVATE KEY-----\n"
    }
}

import XCTest
@testable import TableLite

/// stderr 分类：指纹变化必须可区分，不能静默接受（L8）。
///
/// 见 `docs/tech-designs/04-ssh-tunnel.md` §5、§7、`specs/10-ssh-tunnel.md` §5。
final class SSHTunnelErrorTests: XCTestCase {

    private func classify(_ stderr: String, auth: SSHAuthMethod = .password, status: Int32 = 255) -> SSHTunnelError {
        SSHStderrClassifier.classify(stderrTail: stderr, exitStatus: status, authMethod: auth)
    }

    // MARK: 指纹

    func testHostKeyChangedBannerIsDistinct() {
        let stderr = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        Host key for 'bastion.example.com' has changed and you have requested strict checking.
        Host key verification failed.
        """
        let error = classify(stderr)
        XCTAssertTrue(error.isHostKeyChanged)
        guard case .hostKeyChanged(let tail) = error else {
            return XCTFail("指纹变化必须单独成一种错误，实际：\(error)")
        }
        XCTAssertTrue(tail.contains("REMOTE HOST IDENTIFICATION HAS CHANGED"))
    }

    func testHostKeyVerificationFailedIsNotAuthenticationFailure() {
        let error = classify("Host key verification failed.\n")
        XCTAssertTrue(error.isHostKeyChanged)
        if case .authenticationFailed = error {
            XCTFail("不能把指纹问题误报成认证失败")
        }
    }

    // MARK: 本地端口

    func testAddressAlreadyInUseIsRetryable() {
        let stderr = "bind [127.0.0.1]:53142: Address already in use\ncannot listen to port: 53142\nCould not request local forwarding.\n"
        let error = classify(stderr)
        XCTAssertTrue(error.isRetryableLocalPort)
        guard case .localPortInUse(let tail) = error else {
            return XCTFail("应为 localPortInUse，实际：\(error)")
        }
        XCTAssertTrue(tail.contains("Address already in use"))
    }

    // MARK: 认证

    func testPermissionDeniedIsAuthenticationFailure() {
        let error = classify("deploy@bastion: Permission denied (password).\n", auth: .password)
        guard case .authenticationFailed(let tail) = error else {
            return XCTFail("应为 authenticationFailed，实际：\(error)")
        }
        XCTAssertTrue(tail.contains("Permission denied"))
    }

    func testPrivateKeyLoadFailureIsPrivateKeyRejected() {
        let stderr = "Load key \"/Users/me/.ssh/id_rsa\": invalid format\nuser@host: Permission denied (publickey).\n"
        let error = classify(stderr, auth: .privateKey)
        guard case .privateKeyRejected = error else {
            return XCTFail("应为 privateKeyRejected，实际：\(error)")
        }
    }

    func testPrivateKeyPassphraseIssueIsPrivateKeyRejected() {
        let stderr = "Enter passphrase for key '/Users/me/.ssh/id_ed25519': \n"
        let error = classify(stderr, auth: .privateKey)
        guard case .privateKeyRejected = error else {
            return XCTFail("应为 privateKeyRejected，实际：\(error)")
        }
    }

    func testPublicKeyPermissionDeniedWithoutKeyLoadIsAuthFailure() {
        let error = classify("user@host: Permission denied (publickey).\n", auth: .privateKey)
        guard case .authenticationFailed = error else {
            return XCTFail("应为 authenticationFailed，实际：\(error)")
        }
    }

    // MARK: 连接

    func testConnectionTimeoutIsConnectionFailure() {
        let error = classify("ssh: connect to host bastion.example.com port 22: Connection timed out\n")
        guard case .connectionFailed(let tail) = error else {
            return XCTFail("应为 connectionFailed，实际：\(error)")
        }
        XCTAssertTrue(tail.contains("Connection timed out"))
    }

    func testUnresolvableHostIsConnectionFailure() {
        let error = classify("ssh: Could not resolve hostname nope.invalid: Name or service not known\n")
        guard case .connectionFailed = error else {
            return XCTFail("应为 connectionFailed，实际：\(error)")
        }
    }

    func testUnknownStderrFallsBackToConnectionFailureAndKeepsText() {
        let error = classify("something totally unexpected\n")
        guard case .connectionFailed(let tail) = error else {
            return XCTFail("应为 connectionFailed，实际：\(error)")
        }
        XCTAssertEqual(tail, "something totally unexpected\n")
    }

    // MARK: 展示

    func testNonStderrErrorsHaveEmptyTail() {
        XCTAssertTrue(SSHTunnelError.sshExecutableMissing(path: "/usr/bin/ssh").stderrTail.isEmpty)
        XCTAssertTrue(SSHTunnelError.invalidConfiguration(reason: "x").stderrTail.isEmpty)
        XCTAssertTrue(SSHTunnelError.portAllocationFailed(reason: "x").stderrTail.isEmpty)
        XCTAssertTrue(SSHTunnelError.processLaunchFailed(reason: "x").stderrTail.isEmpty)
    }

    func testDisplayMessagesAreNonEmptyAndInChinese() {
        let errors: [SSHTunnelError] = [
            .sshExecutableMissing(path: "/usr/bin/ssh"),
            .invalidConfiguration(reason: "x"),
            .portAllocationFailed(reason: "x"),
            .processLaunchFailed(reason: "x"),
            .localPortInUse(stderrTail: ""),
            .startupTimedOut(stderrTail: ""),
            .connectionFailed(stderrTail: ""),
            .authenticationFailed(stderrTail: ""),
            .privateKeyRejected(stderrTail: ""),
            .hostKeyChanged(stderrTail: ""),
            .tunnelClosed(stderrTail: ""),
        ]
        for error in errors {
            XCTAssertFalse(error.displayMessage.isEmpty)
            XCTAssertTrue(error.displayMessage.contains { $0.unicodeScalars.first.map { $0.value > 0x2E80 } ?? false })
        }
    }

    func testHostKeyChangedMessageMentionsRisk() {
        XCTAssertTrue(SSHTunnelError.hostKeyChanged(stderrTail: "").displayMessage.contains("安全风险"))
    }
}

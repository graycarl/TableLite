import XCTest
@testable import TableLite

/// `ConnectionFormState`：字段映射、校验、密码处置意图。
final class ConnectionFormStateTests: XCTestCase {

    private func validForm() -> ConnectionFormState {
        var form = ConnectionFormState()
        form.name = "本地开发"
        form.host = "127.0.0.1"
        form.user = "root"
        return form
    }

    // MARK: 字段映射

    func testMakeConnectionMapsAllFields() {
        var form = ConnectionFormState()
        form.name = "本地开发"
        form.color = .green
        form.isReadOnly = true
        form.host = "127.0.0.1"
        form.portText = "3307"
        form.user = "root"
        form.database = "app_dev"
        form.charset = "utf8mb4"
        form.unixSocket = "/tmp/mysql.sock"
        form.useSSL = false
        form.skipCertificateVerification = true
        form.connectTimeoutText = "5"
        form.queryTimeoutText = "60"
        form.keepAlive = false
        form.keepAliveIntervalText = "15"
        form.sshEnabled = true
        form.sshHost = "bastion.example.com"
        form.sshPortText = "2222"
        form.sshUser = "deploy"
        form.sshAuthMethod = .privateKey
        form.sshPrivateKeyPath = "/Users/me/.ssh/id_ed25519"
        form.sshUseConfigAlias = false
        form.sshJumpHost = "user@proxy:22"

        let now = Date(timeIntervalSince1970: 1000)
        let connection = form.makeConnection(now: now)

        XCTAssertEqual(connection.name, "本地开发")
        XCTAssertEqual(connection.color, .green)
        XCTAssertTrue(connection.isReadOnly)
        XCTAssertEqual(connection.mysql.host, "127.0.0.1")
        XCTAssertEqual(connection.mysql.port, 3307)
        XCTAssertEqual(connection.mysql.user, "root")
        XCTAssertEqual(connection.mysql.database, "app_dev")
        XCTAssertEqual(connection.mysql.charset, "utf8mb4")
        XCTAssertEqual(connection.mysql.unixSocket, "/tmp/mysql.sock")
        XCTAssertFalse(connection.mysql.useSSL)
        XCTAssertTrue(connection.mysql.skipCertificateVerification)
        XCTAssertEqual(connection.mysql.connectTimeout, 5)
        XCTAssertEqual(connection.mysql.queryTimeout, 60)
        XCTAssertFalse(connection.mysql.keepAlive)
        XCTAssertEqual(connection.mysql.keepAliveInterval, 15)
        XCTAssertTrue(connection.ssh.enabled)
        XCTAssertEqual(connection.ssh.host, "bastion.example.com")
        XCTAssertEqual(connection.ssh.port, 2222)
        XCTAssertEqual(connection.ssh.user, "deploy")
        XCTAssertEqual(connection.ssh.authMethod, .privateKey)
        XCTAssertEqual(connection.ssh.privateKeyPath, "/Users/me/.ssh/id_ed25519")
        XCTAssertEqual(connection.ssh.jumpHost, "user@proxy:22")
        XCTAssertEqual(connection.createdAt, now)
        XCTAssertEqual(connection.updatedAt, now)
        XCTAssertTrue(connection.validationIssues().isEmpty)
    }

    func testEditPreservesIdentityAndCreatedAt() {
        let original = Connection(
            id: UUID(),
            name: "旧名字",
            mysql: MySQLConfig(host: "10.0.0.1", port: 3306, user: "app", database: "db"),
            ssh: SSHConfig(),
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        var form = ConnectionFormState(connection: original)
        XCTAssertTrue(form.isEditing)
        form.name = "新名字"

        let now = Date(timeIntervalSince1970: 500)
        let connection = form.makeConnection(now: now)

        XCTAssertEqual(connection.id, original.id)
        XCTAssertEqual(connection.createdAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(connection.updatedAt, now)
        XCTAssertEqual(connection.name, "新名字")
    }

    func testBlankOptionalFieldsBecomeNil() {
        var form = validForm()
        form.unixSocket = "   "
        form.sshEnabled = true
        form.sshHost = "bastion"
        form.sshUser = "deploy"
        form.sshAuthMethod = .password
        form.sshJumpHost = ""

        let connection = form.makeConnection(now: Date())

        XCTAssertNil(connection.mysql.unixSocket)
        XCTAssertNil(connection.ssh.jumpHost)
        XCTAssertTrue(connection.validationIssues().isEmpty)
    }

    // MARK: 校验

    func testRequiredFieldIssues() {
        let form = ConnectionFormState()
        let issues = form.issues(fileExists: { _ in true })

        XCTAssertTrue(issues.contains(.validation(.emptyName)))
        XCTAssertTrue(issues.contains(.validation(.emptyHost)))
        XCTAssertTrue(issues.contains(.validation(.emptyUser)))
    }

    func testNonNumericPortIsRejected() {
        var form = validForm()
        form.portText = "abc"

        XCTAssertEqual(form.makeConnection(now: Date()).mysql.port, -1)
        XCTAssertTrue(form.issues(fileExists: { _ in true }).contains(.validation(.invalidMySQLPort)))
    }

    func testNonPositiveTimeoutIsRejected() {
        var form = validForm()
        form.connectTimeoutText = "0"
        form.queryTimeoutText = "-3"

        let issues = form.issues(fileExists: { _ in true })
        XCTAssertTrue(issues.contains(.validation(.invalidConnectTimeout)))
        XCTAssertTrue(issues.contains(.validation(.invalidQueryTimeout)))
    }

    func testKeepAliveIntervalOnlyCheckedWhenEnabled() {
        var form = validForm()
        form.keepAliveIntervalText = "abc"

        // 关闭保活时忽略心跳间隔。
        form.keepAlive = false
        XCTAssertFalse(form.issues(fileExists: { _ in true }).contains(.validation(.invalidKeepAliveInterval)))

        form.keepAlive = true
        XCTAssertTrue(form.issues(fileExists: { _ in true }).contains(.validation(.invalidKeepAliveInterval)))
    }

    func testSSHIssuesOnlyWhenEnabled() {
        var form = validForm()
        XCTAssertFalse(form.issues(fileExists: { _ in true }).contains(.validation(.emptySSHHost)))

        form.sshEnabled = true
        let issues = form.issues(fileExists: { _ in true })
        XCTAssertTrue(issues.contains(.validation(.emptySSHHost)))
        XCTAssertTrue(issues.contains(.validation(.emptySSHUser)))
    }

    func testAliasModeSkipsSSHUserPortAndPrivateKeyValidation() {
        var form = validForm()
        form.sshEnabled = true
        form.sshHost = "my-alias"
        form.sshUseConfigAlias = true
        form.sshAuthMethod = .privateKey
        form.sshPrivateKeyPath = ""

        XCTAssertTrue(form.issues(fileExists: { _ in false }).isEmpty)
    }

    func testPrivateKeyFileMustExist() {
        var form = validForm()
        form.sshEnabled = true
        form.sshHost = "bastion"
        form.sshUser = "deploy"
        form.sshAuthMethod = .privateKey
        form.sshPrivateKeyPath = "/missing/key"

        let issues = form.issues(fileExists: { $0 != "/missing/key" })
        XCTAssertTrue(issues.contains(.privateKeyFileMissing("/missing/key")))
        XCTAssertEqual(
            issues.first { $0.field == .privateKeyPath }?.message,
            "私钥文件不存在：/missing/key"
        )
    }

    // MARK: 密码处置

    func testPasswordUpdateDefaultsToKeychain() {
        var form = validForm()
        form.password = "secret"

        XCTAssertEqual(form.passwordUpdate, .set("secret"))
        XCTAssertEqual(form.connectionPassword, "secret")
    }

    func testPasswordUpdateSessionOnlyWhenCheckboxOff() {
        var form = validForm()
        form.password = "secret"
        form.savePasswordToKeychain = false

        XCTAssertEqual(form.passwordUpdate, .sessionOnly("secret"))
        XCTAssertEqual(form.connectionPassword, "secret")
    }

    func testPasswordUpdateClearWhenRequested() {
        var form = validForm()
        form.password = "secret"
        form.clearStoredPasswordRequested = true

        XCTAssertEqual(form.passwordUpdate, .clear)
        XCTAssertNil(form.connectionPassword)
    }

    func testPasswordUpdateEmptyDeletesStoredEntry() {
        var form = validForm()
        form.hasStoredPassword = true
        form.password = ""

        XCTAssertEqual(form.passwordUpdate, .clear)
        XCTAssertNil(form.connectionPassword)
    }

    func testPasswordUpdateClearsWhenNotSavingAndEmpty() {
        var form = validForm()
        form.savePasswordToKeychain = false
        form.password = ""

        XCTAssertEqual(form.passwordUpdate, .clear)
    }
}

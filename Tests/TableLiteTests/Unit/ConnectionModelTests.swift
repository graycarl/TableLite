import XCTest
@testable import TableLite

/// 连接模型：摘要、校验、复制、序列化，以及**密码字段永不进入 JSON**。
///
/// 见 `docs/tech-designs/02-persistence.md` §2、`05-session-management.md` §1。
final class ConnectionModelTests: XCTestCase {

    private func makeConnection() -> Connection {
        Connection(
            name: "本地开发",
            color: .green,
            isReadOnly: false,
            mysql: MySQLConfig(host: "127.0.0.1", port: 3306, user: "root", database: "app_dev")
        )
    }

    func testSummary() {
        XCTAssertEqual(makeConnection().summary, "root@127.0.0.1:3306/app_dev")
    }

    func testSummaryIncludesSSHHost() {
        var connection = makeConnection()
        connection.ssh = SSHConfig(enabled: true, host: "bastion.example.com", user: "deploy")
        XCTAssertEqual(connection.summary, "root@127.0.0.1:3306/app_dev（经 ssh-bastion.example.com）")
    }

    func testEmptyDatabaseOmitsSlash() {
        var connection = makeConnection()
        connection.mysql.database = ""
        XCTAssertEqual(connection.summary, "root@127.0.0.1:3306")
    }

    func testValidationIssues() {
        let empty = Connection()
        let issues = empty.validationIssues()
        XCTAssertTrue(issues.contains(.emptyName))
        XCTAssertTrue(issues.contains(.emptyHost))
        XCTAssertTrue(issues.contains(.emptyUser))

        var connection = makeConnection()
        connection.mysql.port = 70000
        connection.mysql.connectTimeout = 0
        connection.mysql.queryTimeout = -1
        connection.ssh = SSHConfig(enabled: true, host: "h", user: "u", authMethod: .privateKey, privateKeyPath: nil)
        let more = connection.validationIssues()
        XCTAssertTrue(more.contains(.invalidMySQLPort))
        XCTAssertTrue(more.contains(.invalidConnectTimeout))
        XCTAssertTrue(more.contains(.invalidQueryTimeout))
        XCTAssertTrue(more.contains(.missingPrivateKeyPath))
    }

    func testValidConnectionHasNoIssues() {
        XCTAssertTrue(makeConnection().validationIssues().isEmpty)
    }

    func testDuplicatedHasNewIdentityAndName() {
        let original = makeConnection()
        let copy = original.duplicated(newName: "副本")
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, "副本")
        XCTAssertEqual(copy.mysql, original.mysql)
    }

    func testCodableRoundTrip() throws {
        let connection = makeConnection()
        let data = try JSONEncoder().encode(connection)
        let decoded = try JSONDecoder().decode(Connection.self, from: data)
        XCTAssertEqual(decoded, connection)
    }

    // MARK: 密码防护

    func testDetectSecretKeys() throws {
        let file = ConnectionMetadataFile(connections: [makeConnection()])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as! [String: Any]
        var connections = json["connections"] as! [[String: Any]]
        var first = connections[0]
        first["password"] = "secret"
        var mysql = first["mysql"] as! [String: Any]
        mysql["password"] = "secret"
        first["mysql"] = mysql
        connections[0] = first
        json["connections"] = connections
        let data = try JSONSerialization.data(withJSONObject: json)

        let keys = ConnectionMetadataFile.detectSecretKeys(in: data)
        XCTAssertEqual(keys, ["password"])

        let (decoded, dropped) = try ConnectionMetadataFile.decode(from: data)
        XCTAssertEqual(dropped, ["password"])
        XCTAssertEqual(decoded.connections.count, 1)

        // 重新编码后不得再出现密码字段。
        let reencoded = try JSONEncoder().encode(decoded)
        let text = String(decoding: reencoded, as: UTF8.self)
        XCTAssertFalse(text.contains("password"))
    }

    func testSSHAuthMethodCodable() throws {
        for method in SSHAuthMethod.allCases {
            let data = try JSONEncoder().encode(method)
            XCTAssertEqual(try JSONDecoder().decode(SSHAuthMethod.self, from: data), method)
        }
    }
}

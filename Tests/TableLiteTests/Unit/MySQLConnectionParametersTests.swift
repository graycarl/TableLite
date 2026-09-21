import XCTest
@testable import TableLite

/// 连接参数映射：从 `MySQLConfig` 到自包含参数，以及端口 / socket / 超时的归一化。
///
/// 见 `docs/tech-designs/03-mysql-layer.md` §2、`05-session-management.md` §1。
final class MySQLConnectionParametersTests: XCTestCase {

    func testMappingFromMySQLConfig() {
        var config = MySQLConfig(
            host: "db.internal",
            port: 3307,
            user: "app",
            database: "shop",
            charset: "utf8mb4",
            unixSocket: "/tmp/mysql.sock"
        )
        config.useSSL = false
        config.skipCertificateVerification = true
        config.connectTimeout = 15
        config.queryTimeout = 60
        config.keepAlive = true
        config.keepAliveInterval = 45

        let parameters = MySQLConnectionParameters(config: config, password: "s3cret")

        XCTAssertEqual(parameters.host, "db.internal")
        XCTAssertEqual(parameters.port, 3307)
        XCTAssertEqual(parameters.user, "app")
        XCTAssertEqual(parameters.password, "s3cret")
        XCTAssertEqual(parameters.database, "shop")
        XCTAssertEqual(parameters.charset, "utf8mb4")
        XCTAssertEqual(parameters.unixSocket, "/tmp/mysql.sock")
        XCTAssertFalse(parameters.useSSL)
        XCTAssertTrue(parameters.skipCertificateVerification)
        XCTAssertEqual(parameters.connectTimeout, 15)
        XCTAssertEqual(parameters.queryTimeout, 60)
        XCTAssertTrue(parameters.keepAlive)
        XCTAssertEqual(parameters.keepAliveInterval, 45)
    }

    func testInvalidPortFallsBackToDefault() {
        XCTAssertEqual(MySQLConnectionParameters.normalizedPort(0), 3306)
        XCTAssertEqual(MySQLConnectionParameters.normalizedPort(-1), 3306)
        XCTAssertEqual(MySQLConnectionParameters.normalizedPort(70000), 3306)
        XCTAssertEqual(MySQLConnectionParameters.normalizedPort(1), 1)
        XCTAssertEqual(MySQLConnectionParameters.normalizedPort(65535), 65535)

        let config = MySQLConfig(host: "h", port: 70000, user: "u")
        XCTAssertEqual(MySQLConnectionParameters(config: config, password: "").port, 3306)
    }

    func testSocketNormalization() {
        XCTAssertNil(MySQLConnectionParameters.normalizedSocket(nil))
        XCTAssertNil(MySQLConnectionParameters.normalizedSocket(""))
        XCTAssertNil(MySQLConnectionParameters.normalizedSocket("   "))
        XCTAssertEqual(MySQLConnectionParameters.normalizedSocket("/tmp/mysql.sock"), "/tmp/mysql.sock")
    }

    func testTimeoutSecondsAreNormalized() {
        XCTAssertEqual(MySQLConnectionParameters.wholeSeconds(10, fallback: 10), 10)
        XCTAssertEqual(MySQLConnectionParameters.wholeSeconds(2.4, fallback: 10), 2)
        XCTAssertEqual(MySQLConnectionParameters.wholeSeconds(2.6, fallback: 10), 3)
        XCTAssertEqual(MySQLConnectionParameters.wholeSeconds(0, fallback: 10), 10)
        XCTAssertEqual(MySQLConnectionParameters.wholeSeconds(-5, fallback: 10), 10)
        XCTAssertEqual(MySQLConnectionParameters.wholeSeconds(.infinity, fallback: 10), 10)
        XCTAssertEqual(MySQLConnectionParameters.wholeSeconds(Double(UInt32.max) * 4, fallback: 10), UInt32.max)
    }

    func testSecondsAccessors() {
        var parameters = MySQLConnectionParameters(host: "h", user: "u", connectTimeout: 10)
        XCTAssertEqual(parameters.connectTimeoutSeconds, 10)
        XCTAssertEqual(parameters.readWriteTimeoutSeconds, 0, "0 表示用库默认")

        parameters.connectTimeout = 0
        parameters.readWriteTimeout = 3.2
        XCTAssertEqual(parameters.connectTimeoutSeconds, 10, "非法连接超时退回 10s")
        XCTAssertEqual(parameters.readWriteTimeoutSeconds, 3)
    }

    func testSummary() {
        let parameters = MySQLConnectionParameters(host: "127.0.0.1", port: 3306, user: "root", database: "app_dev")
        XCTAssertEqual(parameters.summary, "root@127.0.0.1:3306/app_dev")

        let noDatabase = MySQLConnectionParameters(host: "127.0.0.1", user: "root")
        XCTAssertEqual(noDatabase.summary, "root@127.0.0.1:3306")
    }

    func testDefaults() {
        let parameters = MySQLConnectionParameters(host: "h", user: "u")
        XCTAssertEqual(parameters.port, 3306)
        XCTAssertEqual(parameters.charset, "utf8mb4")
        XCTAssertEqual(parameters.database, "")
        XCTAssertNil(parameters.unixSocket)
        XCTAssertTrue(parameters.useSSL)
        XCTAssertEqual(parameters.queryTimeout, 300)
        XCTAssertEqual(parameters.keepAliveInterval, 30)
    }
}

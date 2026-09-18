import XCTest
@testable import TableLite
import CMySQLClient

/// Phase 0 的占位测试：确认测试 target 能构建、能 import 到 C 模块。
/// 真正的测试按各技术设计文档的硬约束与边界情况来写：
///   StatementSplitterTests / SQLLexerTests / SQLValueLiteralTests /
///   MySQLValueMappingTests / CSVCodecTests / SSHCommandBuilderTests /
///   PendingChangeStoreTests / FilterSQLBuilderTests
final class SmokeTests: XCTestCase {

    func testCModuleIsLinkable() {
        let handle = mtl_conn_create()
        XCTAssertNotNil(handle, "mtl_conn_create 应当返回非空句柄")
        if let handle {
            mtl_conn_free(handle)
        }
    }

    func testClientLibraryVersionIsAvailable() {
        let version = String(cString: mtl_client_version())
        XCTAssertFalse(version.isEmpty, "应当能取到 libmysqlclient 的版本字符串")
    }

    func testEscapingWithoutConnectionIsConservative() {
        let handle = mtl_conn_create()
        defer { if let handle { mtl_conn_free(handle) } }
        guard let handle else { return XCTFail("句柄为空") }

        // 没有连接时走保守转义路径，引号与反斜杠都要被转义
        // 输入 a'b\c （5 字节）→ 输出 a\'b\\c （7 字节）
        var output = [CChar](repeating: 0, count: 64)
        let input = "a'b\\c"
        let written = input.withCString { pointer in
            mtl_conn_escape(handle, pointer, strlen(pointer), &output, output.count)
        }
        let escaped = String(cString: output)
        XCTAssertEqual(written, 7)
        XCTAssertEqual(escaped, "a\\'b\\\\c")
    }
}

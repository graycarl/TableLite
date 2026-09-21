import XCTest
@testable import TableLite

/// 列元数据：字段类型映射、flags 派生属性、ENUM / SET 解析。
///
/// 见 `docs/tech-designs/03-mysql-layer.md` §4.1、`07-data-grid.md` §2。
final class ColumnInfoTests: XCTestCase {

    func testFieldTypeRawValueRoundTrip() {
        let types: [MySQLFieldType] = [
            .decimal, .tiny, .short, .long, .float, .double, .null, .timestamp,
            .longlong, .int24, .date, .time, .datetime, .year, .newdate, .varchar,
            .bit, .json, .newdecimal, .enumeration, .set, .tinyBlob, .mediumBlob,
            .longBlob, .blob, .varString, .string, .geometry, .unknown(200),
        ]
        for type in types {
            XCTAssertEqual(MySQLFieldType(rawValue: type.rawValue), type)
        }
    }

    func testKnownRawValues() {
        XCTAssertEqual(MySQLFieldType.long.rawValue, 3)
        XCTAssertEqual(MySQLFieldType.json.rawValue, 245)
        XCTAssertEqual(MySQLFieldType.enumeration.rawValue, 247)
        XCTAssertEqual(MySQLFieldType.geometry.rawValue, 255)
    }

    func testFlagDerivedProperties() {
        let column = TestSupport.column(
            "id",
            type: .long,
            flags: ColumnFlag.primaryKey | ColumnFlag.unsigned | ColumnFlag.autoIncrement | ColumnFlag.notNull,
            charset: 63
        )
        XCTAssertTrue(column.isPrimaryKey)
        XCTAssertTrue(column.isUnsigned)
        XCTAssertTrue(column.isAutoIncrement)
        XCTAssertTrue(column.isNotNull)
        XCTAssertTrue(column.isBinary) // charsetNumber == 63
    }

    func testBinaryFlagAlsoMarksBinary() {
        let column = TestSupport.column("payload", type: .blob, flags: ColumnFlag.binary, charset: 33)
        XCTAssertTrue(column.isBinary)
    }

    func testUniqueIndexIsNotPrimaryKey() {
        let column = TestSupport.column("email", flags: ColumnFlag.uniqueKey)
        XCTAssertTrue(column.isUniqueKey)
        XCTAssertFalse(column.isPrimaryKey)
    }

    func testBooleanTinyIntDetection() {
        let tiny = TestSupport.column("flag", type: .tiny, charset: 63, length: 1)
        let tinyBig = TestSupport.column("count", type: .tiny, charset: 63, length: 4)
        XCTAssertTrue(tiny.isBooleanTinyInt)
        XCTAssertFalse(tinyBig.isBooleanTinyInt)
    }

    func testLargeObjectDetectionFromDataType() {
        let text = TestSupport.column("bio", type: .blob, charset: 63, dataType: "text")
        let varchar = TestSupport.column("name", type: .varString, dataType: "varchar")
        let json = TestSupport.column("doc", type: .json, charset: 63, dataType: "json")
        XCTAssertTrue(text.isLargeObject)
        XCTAssertTrue(json.isLargeObject)
        XCTAssertFalse(varchar.isLargeObject)
    }

    func testEnumValuesParsing() {
        let column = TestSupport.column(
            "status",
            type: .enumeration,
            charset: 33,
            columnType: "enum('active','inactive','pending')"
        )
        XCTAssertEqual(column.enumValues, ["active", "inactive", "pending"])
    }

    func testEnumValuesWithEscapedQuote() {
        XCTAssertEqual(
            ColumnInfo.parseEnumValues(from: "enum('a','b''c')"),
            ["a", "b'c"]
        )
    }

    func testSetValues() {
        let column = TestSupport.column(
            "roles",
            type: .set,
            charset: 33,
            columnType: "set('read','write')"
        )
        XCTAssertEqual(column.enumValues, ["read", "write"])
    }

    func testNonEnumReturnsNil() {
        let column = TestSupport.column("name", type: .varString, columnType: "varchar(50)")
        XCTAssertNil(column.enumValues)
    }

    func testTypeCategoryHelpers() {
        XCTAssertTrue(MySQLFieldType.long.isNumeric)
        XCTAssertFalse(MySQLFieldType.varString.isNumeric)
        XCTAssertTrue(MySQLFieldType.datetime.isTemporal)
        XCTAssertTrue(MySQLFieldType.blob.isBlobType)
        XCTAssertTrue(MySQLFieldType.blob.isLargeObjectType)
    }
}

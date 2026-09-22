import Foundation
@testable import TableLite

/// 单元测试共用的构造辅助。
enum TestSupport {
    static func column(
        _ name: String,
        type: MySQLFieldType = .varString,
        flags: UInt32 = 0,
        charset: UInt32 = 33,
        length: Int = 255,
        dataType: String? = nil,
        columnType: String? = nil
    ) -> ColumnInfo {
        ColumnInfo(
            name: name,
            fieldType: type,
            flags: flags,
            charsetNumber: charset,
            length: length,
            dataType: dataType,
            columnTypeText: columnType
        )
    }

    static let primaryKeyFlag = ColumnFlag.primaryKey

    static func locator(
        id: String = "5",
        column: String = "id",
        type: MySQLFieldType = .long
    ) -> RowLocator {
        RowLocator(keys: [
            RowKeyValue(column: column, value: .text(id), fieldType: type),
        ])
    }

    static func edit(_ column: String, _ value: SQLValue) -> PendingEdit {
        PendingEdit(column: column, value: value)
    }
}

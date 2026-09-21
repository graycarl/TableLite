import Foundation
import os

/// Store 层日志出口。
///
/// `02-persistence.md` §8：subsystem `com.graycarl.tablelite`，分类 `store`。
/// `01-architecture.md` §4：禁止吞错误，所有 `catch` 至少写一条日志。
enum StoreLog {
    private static let subsystem = "com.graycarl.tablelite"

    private static let store = Logger(subsystem: subsystem, category: "store")

    static func info(_ message: String) {
        store.info("\(message, privacy: .public)")
    }

    static func warning(_ message: String) {
        store.warning("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        store.error("\(message, privacy: .public)")
    }
}

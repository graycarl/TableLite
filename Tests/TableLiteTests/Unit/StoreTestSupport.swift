import Foundation
@testable import TableLite

/// Store 层单测共用的临时目录与构造辅助。
enum StoreTestSupport {

    /// 在系统临时目录里建一个唯一根目录，返回布局与目录。
    static func makeTemporaryLayout() -> (layout: AppStorageLayout, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableLiteStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (AppStorageLayout(rootDirectory: directory), directory)
    }

    /// 简单可用的连接。
    static func connection(name: String = "本地开发", id: UUID = UUID()) -> Connection {
        Connection(
            id: id,
            name: name,
            mysql: MySQLConfig(host: "127.0.0.1", port: 3306, user: "root", database: "app_dev"),
            ssh: SSHConfig()
        )
    }

    /// 删除临时目录。
    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

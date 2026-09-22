import AppKit

/// 剪贴板写入抽象。
///
/// 「复制建表语句 / 定义」必须落到系统剪贴板，而 macOS 上只有 `NSPasteboard` 一个入口。
/// 为了让 `TableStructureViewModel` 可单测，这里把它抽成协议，生产实现是本文件里的
/// `SystemSchemaClipboard` —— **SchemaView 里唯一 `import AppKit` 的文件**，
/// 其余视图一律纯 SwiftUI。
///
/// 若主 session 后续在 Core 里放了统一的剪贴板工具，把默认实现换掉即可。
@MainActor
protocol SchemaClipboard: AnyObject {
    func write(_ text: String)
}

/// 系统剪贴板实现。
@MainActor
final class SystemSchemaClipboard: SchemaClipboard {
    func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

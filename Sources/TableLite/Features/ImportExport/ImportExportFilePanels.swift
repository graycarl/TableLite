import AppKit
import Foundation
import UniformTypeIdentifiers

/// 导出 / 导入用的系统文件面板。
///
/// `docs/tech-designs/06-ui-layer.md` §1：能用 SwiftUI 就用 SwiftUI，
/// 文件面板是 SwiftUI `fileExporter` / `fileImporter` 无法覆盖「流式写入 + 保留 `.partial`」
/// 的场景，因此这里用 AppKit 的 `NSSavePanel` / `NSOpenPanel`。
///
/// `NSSavePanel` 自带「目标文件已存在」的覆盖确认，满足
/// `specs/08-import-export.md` §1「目标文件已存在 → 询问是否覆盖」。
@MainActor
enum ImportExportFilePanels {

    /// 选择导出目标。返回 nil 表示用户取消。
    static func chooseExportDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出到 CSV"
        panel.prompt = "导出"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            panel.directoryURL = downloads
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// 选择要导入的 CSV 文件。返回 nil 表示用户取消。
    static func chooseCSVFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择 CSV 文件"
        panel.prompt = "选择"
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// 默认导出目录（`~/Downloads`）。
    static func defaultExportDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}

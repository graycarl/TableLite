import SwiftUI
import AppKit

/// 快速查看面板（`specs/03-data-browsing.md` §8、`07-data-grid.md` §9）。
///
/// `NSPanel`（AppKit）+ SwiftUI 内容（`06-ui-layer.md` §1）。
/// `Esc` 关闭；大字段未加载时先显示 loading，接着由 ViewModel 二次加载完再更新。
@MainActor
final class QuickLookPanelController {

    private var panel: QuickLookPanel?

    func present(_ content: QuickLookContent) {
        if let panel {
            panel.update(content)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = QuickLookPanel(content: content)
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func update(_ content: QuickLookContent) {
        panel?.update(content)
    }

    func dismiss() {
        panel?.close()
        panel = nil
    }
}

// MARK: - 面板

final class QuickLookPanel: NSPanel {

    private let hostingView: NSHostingView<QuickLookContentView>

    init(content: QuickLookContent) {
        self.hostingView = NSHostingView(rootView: QuickLookContentView(content: content))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        title = content.title
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = hostingView
        minSize = NSSize(width: 380, height: 260)
    }

    override var canBecomeKey: Bool { true }

    func update(_ content: QuickLookContent) {
        title = content.title
        hostingView.rootView = QuickLookContentView(content: content)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            close()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - 内容

struct QuickLookContentView: View {

    let content: QuickLookContent

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body(for: content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(content.title)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Text(content.kind.displayName)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let byteCount = content.byteCount, byteCount > 0 {
                Text(ByteSize.format(byteCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func body(for content: QuickLookContent) -> some View {
        if content.isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在加载完整内容…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = content.error {
            Text(error)
                .foregroundStyle(.secondary)
                .padding()
        } else if content.isNull {
            Text("NULL")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch content.kind {
            case .image:
                imageBody
            case .binary:
                textBody(HexDump.format(content.data ?? Data()))
            case .json:
                textBody(Self.prettyJSON(content.text) ?? content.text)
            case .text:
                textBody(content.text)
            }
        }
    }

    @ViewBuilder
    private var imageBody: some View {
        if let data = content.data, let image = NSImage(data: data) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
            }
        } else {
            textBody("无法解析为图片")
        }
    }

    private func textBody(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("复制") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                if let data = content.data {
                    pasteboard.setData(data, forType: .string)
                } else {
                    pasteboard.setString(content.text, forType: .string)
                }
            }
            .disabled(content.isLoading)

            if content.kind == .binary || content.kind == .image {
                Button("导出为文件…") {
                    export()
                }
                .disabled(content.isLoading)
            }
            Spacer()
            Text("Esc 关闭")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = content.columnName + "." + (suggestedExtension ?? "bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if let data = content.data {
                try data.write(to: url)
            } else {
                try content.text.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            NSSound.beep()
        }
    }

    private var suggestedExtension: String? {
        guard let data = content.data else { return nil }
        return BinaryFormatDetector.detect(data).fileExtension
    }

    static func prettyJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: pretty, encoding: .utf8) else {
            return nil
        }
        return string
    }
}

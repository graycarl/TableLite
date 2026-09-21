import SwiftUI
import AppKit
import CMySQLClient

/// 应用入口。
///
/// 这里的界面只是 Phase 0 的骨架：用来验证
///   1. 工程能生成、能构建、能启动
///   2. Swift 侧能 `import CMySQLClient`，并且运行时能加载 libmysqlclient
///
/// 真正的界面见 specs/02-workspace.md，实现见 docs/tech-designs/06-ui-layer.md。
@main
struct TableLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // `--smoke` 时跑完 C shim 的端到端验证就直接退出，不启动 GUI。
        // 见 Sources/TableLite/Core/MySQL/SmokeRunner.swift。
        SmokeRunner.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            EnvironmentCheckView()
                .frame(minWidth: 520, minHeight: 360)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // 单窗口应用：不要「新建窗口」
            CommandGroup(replacing: .newItem) { }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // TODO(P10): 关闭所有 MySQLSession，停止所有 SSHTunnel（不能残留 ssh 进程）
        //           见 docs/tech-designs/05-session-management.md §7
    }
}

/// Phase 0 的自检面板：把构建与链接问题在界面上直接暴露出来。
private struct EnvironmentCheckView: View {
    @State private var checks: [CheckResult] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TableLite")
                    .font(.largeTitle.bold())
                Text("macOS 原生 MySQL 客户端 · Phase 0 骨架")
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(checks) { check in
                    HStack(spacing: 8) {
                        Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(check.passed ? .green : .red)
                        Text(check.title)
                        if let detail = check.detail {
                            Text(detail)
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }
                    }
                }
            }

            Spacer()

            HStack {
                Button("重新检查") { runChecks() }
                Spacer()
                Text("下一步：make smoke")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .task { runChecks() }
    }

    private func runChecks() {
        var results: [CheckResult] = []

        // 1. 能创建并释放 C 侧的连接对象 —— 说明 modulemap 与静态库链接正常
        let handle = mtl_conn_create()
        results.append(.init(title: "CMySQLClient 已链接",
                             passed: handle != nil,
                             detail: handle != nil ? nil : "mtl_conn_create 返回 NULL"))
        if let handle { mtl_conn_free(handle) }

        // 2. 运行时能加载 libmysqlclient（能拿到客户端库版本字符串）
        let version = String(cString: mtl_client_version())
        results.append(.init(title: "libmysqlclient 已加载",
                             passed: !version.isEmpty,
                             detail: "客户端库版本 \(version)"))

        checks = results
    }
}

private struct CheckResult: Identifiable {
    let id = UUID()
    let title: String
    let passed: Bool
    let detail: String?
}

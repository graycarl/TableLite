import AppKit
import QuartzCore

/// 调试与基准共用的状态探测：等标签装配 / 加载完成，在主窗口里定位数据网格。
///
/// 决策见 `docs/tech-designs/15-testing.md` §8.1（基准）与 §9.2（启动原语）：
/// 这里只做「轮询到某个状态」，不带任何打印策略，失败文案由调用方决定。
@MainActor
enum DevStateProbe {

    /// 等标签的 ViewModel 出现且数据加载完成。
    ///
    /// 返回 `nil` 表示超时或加载失败（失败文案通过 `onFailure` 回给调用方）。
    static func waitForLoaded(
        tab: Tab,
        timeout: TimeInterval,
        onFailure: (String) -> Void = { _ in }
    ) async -> TableDataViewModel? {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            if let viewModel = tab.content as? TableDataViewModel {
                switch viewModel.loadState {
                case .loaded:
                    return viewModel
                case .failed(let message):
                    onFailure(message)
                    return nil
                case .idle, .loading:
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// 等**本次**重载真正跑完。
    ///
    /// 不能直接用 `waitForLoaded`：`setRowLimit` 是异步起查询，调用后 `loadState` 还停在
    /// 改条数之前的 `.loaded`，按状态轮询会立即返回，于是加载与测量窗口重叠
    /// （`15-testing.md` §8.1 的教训）。所以先等它进入 `.loading`，再等 `.loaded`。
    static func waitForReload(
        tab: Tab,
        timeout: TimeInterval,
        onFailure: (String) -> Void = { _ in }
    ) async -> TableDataViewModel? {
        let deadline = CACurrentMediaTime() + timeout
        var sawLoading = false
        while CACurrentMediaTime() < deadline {
            if let viewModel = tab.content as? TableDataViewModel {
                switch viewModel.loadState {
                case .loading:
                    sawLoading = true
                case .loaded:
                    if sawLoading { return viewModel }
                case .failed(let message):
                    if sawLoading {
                        onFailure(message)
                        return nil
                    }
                case .idle:
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// 等标签的内容视图装配完成（查询 / 历史 / Console 等非表数据标签用）。
    static func waitForContent(tab: Tab, timeout: TimeInterval) async -> AnyObject? {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            if let content = tab.content { return content }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// 在主窗口视图树里找数据网格的 `NSScrollView`（documentView 是 `DataGridTableView`）。
    static func findGridScrollView() -> NSScrollView? {
        for window in NSApp.windows {
            if let found = findScrollView(in: window.contentView) { return found }
        }
        return nil
    }

    static func findGridTableView() -> NSTableView? {
        findGridScrollView()?.documentView as? NSTableView
    }

    /// 主窗口（排除面板 / 弹窗）。
    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
    }

    private static func findScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scrollView = view as? NSScrollView, scrollView.documentView is DataGridTableView {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }
}

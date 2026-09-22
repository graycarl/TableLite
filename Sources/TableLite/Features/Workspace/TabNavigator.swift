import Foundation

/// 标签切换的纯逻辑（`specs/02-workspace.md` §9）。
///
/// - `⌘[` / `⌘]`：上一个 / 下一个标签，循环切换；
/// - `⌘1`…`⌘9`：跳到第 N 个标签，超出范围时不动。
///
/// 抽成纯函数便于单测；视图只负责把结果写回 `ConnectionSession.activeTabID`。
enum TabNavigator {

    /// 下一个标签的下标；没有标签时返回 nil。
    static func nextIndex(current: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard current >= 0, current < count else { return 0 }
        return (current + 1) % count
    }

    /// 上一个标签的下标；没有标签时返回 nil。
    static func previousIndex(current: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard current >= 0, current < count else { return count - 1 }
        return (current - 1 + count) % count
    }

    /// `⌘1`…`⌘9` 对应的下标；`number` 是 1-based，越界返回 nil。
    static func index(forShortcut number: Int, count: Int) -> Int? {
        guard number >= 1, number <= 9 else { return nil }
        let index = number - 1
        guard index < count else { return nil }
        return index
    }
}

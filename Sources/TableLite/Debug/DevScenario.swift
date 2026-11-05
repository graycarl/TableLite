#if DEBUG
import Foundation

/// 具名调试场景（`docs/tech-designs/15-testing.md` §9.3）。
///
/// **v1 刻意不预置任何场景**（S49）：启动原语 + AX 驱动已覆盖盘点过的状态，
/// 预置场景会重复实现，并慢慢长成第二套 UI 测试。
///
/// 只有「原语表达不了、AX 也到不了」时才在这里加一个，且必须满足：
/// - 一个场景 ≤ 10 行，只调用现有公开 API，不绕过产品逻辑；
/// - `summary` 写清它造出的是什么状态、为什么不能拆成原语。
///
/// 例：
///
///     DevScenario(
///         name: "pending-changes",
///         summary: "批量造 3 行 × 2 列未提交改动（原语需重复 6 次，保留作回归）"
///     ) { environment in
///         // …
///     }
struct DevScenario {
    let name: String
    let summary: String
    let run: @MainActor (AppEnvironment) async throws -> Void
}

enum DevScenarioRegistry {

    static let all: [DevScenario] = []

    static func scenario(named name: String) -> DevScenario? {
        all.first { $0.name == name }
    }
}
#endif

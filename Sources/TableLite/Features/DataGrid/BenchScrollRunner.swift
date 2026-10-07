import AppKit
import Foundation
import QuartzCore

/// 应用内滚动性能基准（隐藏参数 `--bench-scroll <表名>`）。
///
/// 与 `--filter-smoke` 等同族但**不是无头模式**：基准要测的就是真实窗口里的
/// 帧级行为（CA commit / WindowServer / UpdateCycle），必须走真实渲染管线。
/// 流程：正常启动 → 自动连库 → 开表 → 等加载 → 调大显示条数 → `CADisplayLink`
/// 按固定速度驱动滚动 → 输出逐帧间隔的统计 JSON 到 stdout 并退出。
///
/// 设计决策见 `docs/tech-designs/15-testing.md` §8；度量用帧间隔分布而不是
/// CPU 采样（卡顿是帧级突发，CPU 占用低不代表不卡）。
///
/// 用法：
///
///     MYSQL_PORT=13307 MYSQL_PASSWORD=tablelite MYSQL_DATABASE=tablelite_dev \
///       TableLite.app/Contents/MacOS/TableLite --bench-scroll wide_test
///
/// 可选参数：`--bench-duration <秒>`（默认 15）、`--bench-speed <pt/s>`（默认 3000）、
/// `--bench-rows <行数>`（显示条数，默认 3000，退出前恢复偏好原值）。
@MainActor
final class BenchScrollRunner: NSObject {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--bench-scroll")
    }

    static func scheduleIfRequested(environment: AppEnvironment) {
        guard isRequested else { return }
        shared = BenchScrollRunner(environment: environment)
        shared?.start()
    }

    /// displayLink 持有 target，这里再持有一份保证整个基准周期内活着。
    private static var shared: BenchScrollRunner?

    // MARK: - 配置

    private struct Config {
        var host = "127.0.0.1"
        var port = 13307 // dev 库默认端口（`12-build-and-deps.md`）
        var user = "root"
        var password = "tablelite"
        var database = "tablelite_dev"
        var table = "wide_test"
        var duration: TimeInterval = 15
        var speed: Double = 3000 // pt/s，模拟快速滚动
        var rows = 3000

        static func parse() -> Config {
            let env = ProcessInfo.processInfo.environment
            let args = CommandLine.arguments
            var config = Config()
            config.host = env["MYSQL_HOST"] ?? config.host
            config.port = Int(env["MYSQL_PORT"] ?? "") ?? config.port
            config.user = env["MYSQL_USER"] ?? config.user
            config.password = env["MYSQL_PASSWORD"] ?? config.password
            config.database = env["MYSQL_DATABASE"] ?? config.database
            func value(after flag: String) -> String? {
                guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
                return args[index + 1]
            }
            if let table = value(after: "--bench-scroll") { config.table = table }
            if let duration = value(after: "--bench-duration").flatMap(TimeInterval.init) { config.duration = duration }
            if let speed = value(after: "--bench-speed").flatMap(Double.init) { config.speed = speed }
            if let rows = value(after: "--bench-rows").flatMap(Int.init) { config.rows = rows }
            return config
        }
    }

    // MARK: - 状态

    private let environment: AppEnvironment
    private let config: Config
    private var link: CADisplayLink?
    private weak var scrollView: NSScrollView?
    private var lastTimestamp: CFTimeInterval = 0
    private var deltas: [Double] = [] // 毫秒
    private var offset: Double = 0
    private var maxY: Double = 0
    private var measuring = false
    private var scrollStartedAt: CFTimeInterval = 0
    private var savedRowLimit: Int?
    private var tickCount = 0

    private init(environment: AppEnvironment) {
        self.environment = environment
        self.config = Config.parse()
    }

    // MARK: - 流程

    private func start() {
        Task { @MainActor in
            let code = await self.run()
            fflush(stdout)
            exit(code)
        }
    }

    private func run() async -> Int32 {
        #if DEBUG
        let build = "Debug"
        #else
        let build = "Release"
        #endif
        print("== TableLite 滚动基准（\(build)）：\(config.table) @ \(config.host):\(config.port)/\(config.database) ==")

        // 等启动装配（会话骨架恢复等）落定再连。
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let connection = Connection(
            id: UUID(),
            name: "bench-scroll",
            mysql: MySQLConfig(
                host: config.host,
                port: config.port,
                user: config.user,
                database: config.database,
                keepAlive: false
            ),
            ssh: SSHConfig()
        )
        do {
            _ = try await environment.sessionManager.connect(connection, password: config.password)
        } catch {
            print("   连接失败：\(error)")
            return 1
        }
        guard let session = environment.sessionManager.session(id: connection.id) else {
            print("   找不到会话")
            return 1
        }

        let tab = session.openTableData(database: config.database, table: config.table, forceNew: true)
        guard let viewModel = await waitForLoaded(tab: tab, timeout: 30) else {
            print("   打开表或加载超时")
            return 1
        }
        print("   已加载 \(viewModel.rows.count) 行（显示条数 \(viewModel.rowLimit)）")

        // 显示条数调大，保证滚动行程足够；退出前恢复偏好。
        if viewModel.rowLimit < config.rows {
            savedRowLimit = environment.preferences.rowLimit
            viewModel.setRowLimit(config.rows)
            guard await waitForLoaded(tab: tab, timeout: 30) != nil else {
                print("   调整显示条数后加载超时")
                return 1
            }
            print("   显示条数调至 \(config.rows)，实际 \(viewModel.rows.count) 行")
        }

        NSApp.activate(ignoringOtherApps: true)
        guard let found = findGridScrollView() else {
            print("   找不到网格视图")
            return 1
        }
        scrollView = found
        let contentHeight = Double(found.documentView?.frame.height ?? 0)
        let visibleHeight = Double(found.contentView.bounds.height)
        maxY = max(0, contentHeight - visibleHeight)
        guard maxY > 0 else {
            print("   内容不足以滚动")
            return 1
        }
        print("   滚动行程 \(Int(maxY))pt，速度 \(Int(config.speed))pt/s，时长 \(Int(config.duration))s")

        // displayLink 必须挂在窗口里的视图上。
        guard let gridView = found.documentView else { return 1 }
        let link = gridView.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link

        // 预热 1s（首开排版、字体缓存等一次性成本不进统计），然后开始测量。
        scrollStartedAt = CACurrentMediaTime()
        return await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    private var finishContinuation: CheckedContinuation<Int32, Never>?

    @objc private func tick(_ link: CADisplayLink) {
        tickCount += 1
        let now = CACurrentMediaTime()
        let timestamp = link.timestamp
        if measuring, lastTimestamp > 0 {
            deltas.append((timestamp - lastTimestamp) * 1000)
        }
        let dt = lastTimestamp > 0 ? max(0, timestamp - lastTimestamp) : 1.0 / 60
        lastTimestamp = timestamp

        guard let scrollView else { return }
        let clipView = scrollView.contentView
        // 每 tick 的步长设上限：displayLink 一旦因主线程繁忙延迟，dt 变大，
        // 不封顶的话单帧要新造几千个单元格，会自我反馈成「越卡步长越大」。
        // 220pt ≈ 10 行 / 帧，对应 60fps 下 13200pt/s 的快速滚动。
        offset += min(config.speed * dt, 220)
        if offset > maxY { offset = 0 } // 到底跳回顶部，循环滚
        clipView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(clipView)

        if !measuring, now - scrollStartedAt >= 1.0 {
            measuring = true
            deltas.removeAll()
            lastTimestamp = 0
        }
        if measuring, now - scrollStartedAt >= 1.0 + config.duration {
            finish()
        }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        if let savedRowLimit {
            environment.preferences.rowLimit = savedRowLimit
        }
        report()
        finishContinuation?.resume(returning: 0)
        finishContinuation = nil
    }

    private func report() {
        let sorted = deltas.sorted()
        guard !sorted.isEmpty else {
            print("   没有采到帧")
            return
        }
        // 诊断：displayLink 在低帧率下要区分「主线程忙」与「窗口被遮挡被节流」。
        if let window = scrollView?.window {
            print(String(format: "   诊断：tick 总数 %d，窗口 occlusion=%@，isKey=%@，App active=%@",
                         tickCount,
                         window.occlusionState.contains(.visible) ? "visible" : "occluded",
                         window.isKeyWindow ? "yes" : "no",
                         NSApp.isActive ? "yes" : "no"))
        }
        func percentile(_ p: Double) -> Double {
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        let p50 = percentile(0.5), p90 = percentile(0.9), p99 = percentile(0.99)
        let maxValue = sorted.last ?? 0
        let over34 = sorted.filter { $0 > 34 }.count
        let fps = Double(sorted.count) / config.duration
        #if DEBUG
        let build = "Debug"
        #else
        let build = "Release"
        #endif
        // 一行 JSON 给脚本消费；人类可读摘要另起几行。
        print("""
        {"tool":"bench-scroll","build":"\(build)","table":"\(config.table)",\
        "frames":\(sorted.count),"duration_s":\(config.duration),"fps":\(String(format: "%.1f", fps)),\
        "p50_ms":\(String(format: "%.1f", p50)),"p90_ms":\(String(format: "%.1f", p90)),\
        "p99_ms":\(String(format: "%.1f", p99)),"max_ms":\(String(format: "%.1f", maxValue)),\
        "over34ms":\(over34)}
        """)
        print(String(format: "   帧 %d（%.0f fps） p50 %.1fms  p90 %.1fms  p99 %.1fms  max %.1fms  >34ms %d 帧",
                     sorted.count, fps, p50, p90, p99, maxValue, over34))
    }

    // MARK: - 工具

    /// 等标签的 ViewModel 出现且数据加载完成。
    private func waitForLoaded(tab: Tab, timeout: TimeInterval) async -> TableDataViewModel? {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            if let viewModel = tab.content as? TableDataViewModel {
                switch viewModel.loadState {
                case .loaded: return viewModel
                case .failed(let message):
                    print("   加载失败：\(message)")
                    return nil
                case .idle, .loading: break
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// 在主窗口视图树里找数据网格的 NSScrollView（documentView 是 DataGridTableView）。
    private func findGridScrollView() -> NSScrollView? {
        for window in NSApp.windows {
            if let found = findScrollView(in: window.contentView) { return found }
        }
        return nil
    }

    private func findScrollView(in view: NSView?) -> NSScrollView? {
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

import AppKit

// MARK: - 行号标尺
//
// 自绘 `NSRulerView`，并标出「当前语句起始行」。见 docs/tech-designs/10-query-editor.md §2。
//
// 只做渲染：行号数量、当前语句起始行都由 `SQLEditorView.Coordinator` 推入。

@MainActor
final class LineNumberRulerView: NSRulerView {

    private weak var textView: NSTextView?

    /// 1-based；nil 表示不高亮。
    var currentStatementStartLine: Int? {
        didSet { needsDisplay = true }
    }

    private var numberFont: NSFont
    private let numberColor = NSColor.secondaryLabelColor
    private let currentNumberColor = NSColor.controlAccentColor
    private var totalLineCount = 1

    init(textView: NSTextView, scrollView: NSScrollView, fontSize: CGFloat) {
        self.textView = textView
        self.numberFont = NSFont.monospacedDigitSystemFont(ofSize: max(9, fontSize - 1), weight: .regular)
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = Self.thickness(for: 1)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 文本变化后调用：重算行号位数与标尺宽度，并重绘。
    func recountLines() {
        guard let textView else { return }
        let ns = textView.string as NSString
        var count = 1
        var index = 0
        while index < ns.length {
            if ns.character(at: index) == 0x0A { count += 1 }
            index += 1
        }
        totalLineCount = count
        let thickness = Self.thickness(for: count)
        if abs(ruleThickness - thickness) > 0.5 {
            ruleThickness = thickness
        }
        needsDisplay = true
    }

    func updateFontSize(_ size: CGFloat) {
        numberFont = NSFont.monospacedDigitSystemFont(ofSize: max(9, size - 1), weight: .regular)
        needsDisplay = true
    }

    // MARK: 绘制

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // 背景 + 右侧分隔线
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        separator.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        separator.lineWidth = 1
        separator.stroke()

        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let content = textView.string as NSString
        let inset = textView.textContainerInset
        let visibleRect = scrollView?.contentView.bounds ?? bounds

        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: numberColor,
        ]
        let currentAttributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: currentNumberColor,
        ]

        guard content.length > 0 else {
            draw(number: 1, y: inset.height, attributes: attributes)
            return
        }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // charRange 起点所在行号
        var lineNumber = 1
        var cursor = 0
        let startOffset = min(charRange.location, content.length)
        while cursor < startOffset {
            let lineRange = content.lineRange(for: NSRange(location: cursor, length: 0))
            cursor = NSMaxRange(lineRange)
            lineNumber += 1
        }

        var location = content.lineRange(for: NSRange(location: startOffset, length: 0)).location
        while location < content.length {
            let lineRange = content.lineRange(for: NSRange(location: location, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: location)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let y = inset.height + fragment.minY - visibleRect.minY
            let isCurrent = lineNumber == currentStatementStartLine
            draw(number: lineNumber, y: y, attributes: isCurrent ? currentAttributes : attributes)
            if isCurrent {
                drawMarker(y: y)
            }
            location = NSMaxRange(lineRange)
            lineNumber += 1
        }
    }

    // MARK: 私有

    private func draw(number: Int, y: CGFloat, attributes: [NSAttributedString.Key: Any]) {
        let text = "\(number)" as NSString
        let size = text.size(withAttributes: attributes)
        let x = ruleThickness - size.width - 6
        text.draw(at: NSPoint(x: max(2, x), y: y), withAttributes: attributes)
    }

    private func drawMarker(y: CGFloat) {
        let size = numberFont.pointSize
        let rect = NSRect(x: ruleThickness - 3.5, y: y + 1.5, width: 3, height: max(6, size))
        currentNumberColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
    }

    private static func thickness(for lineCount: Int) -> CGFloat {
        let digits = max(2, String(max(1, lineCount)).count)
        return CGFloat(digits) * 8 + 16
    }
}

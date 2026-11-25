import AppKit
import SwiftUI

struct HeatmapGrid: NSViewRepresentable {
    struct ScrollRequest {
        let day: DayKey
        let id = UUID()
    }

    let layout: HeatmapGridLayout
    let scene: CheckInScene
    let today: DayKey
    let highlighted: DayKey
    let library: Library
    let generation: Int
    var scrollRequest: ScrollRequest?
    let editDay: (DayKey) -> Void

    func makeNSView(context: Context) -> NSView {
        layout.showsMonths ? HeatmapScrollView() : HeatmapGridView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let scroll = view as? HeatmapScrollView {
            scroll.update(self)
        } else if let grid = view as? HeatmapGridView {
            grid.update(self)
        }
    }
}

private final class HeatmapScrollView: NSScrollView {
    private enum ScrollTarget {
        case end
        case day(DayKey, trailing: Bool)
    }

    private let grid = HeatmapGridView()
    private var target: ScrollTarget?
    private var lastRequestID: UUID?
    private var lastViewportWidth: CGFloat = 0

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        documentView = grid
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ model: HeatmapGrid) {
        let previous = grid.model?.layout
        if let request = model.scrollRequest, request.id != lastRequestID {
            lastRequestID = request.id
            target = .day(request.day, trailing: true)
        } else if let previous, previous != model.layout, target == nil {
            let viewport = documentVisibleRect
            if viewport.maxX >= previous.width - 1 {
                target = .end
            } else if let column = previous.visibleColumns(in: viewport).first,
                      let day = previous.days(in: column).compactMap({ $0 }).first {
                target = .day(day, trailing: false)
            }
        } else if previous == nil, target == nil {
            target = .end
        }

        grid.update(model)
        if previous != model.layout {
            grid.setFrameSize(NSSize(width: model.layout.width, height: model.layout.height))
        }
        if target != nil { needsLayout = true }
    }

    override func layout() {
        super.layout()
        let width = contentView.bounds.width
        guard width > 0, let layout = grid.model?.layout else { return }
        let pinnedToEnd = lastViewportWidth > 0 && width != lastViewportWidth
            && contentView.bounds.minX + lastViewportWidth >= layout.width - 1
        lastViewportWidth = width
        guard let target = target ?? (pinnedToEnd ? .end : nil) else { return }
        self.target = nil
        let rightmost = max(0, layout.width - width)
        let offset: CGFloat
        switch target {
        case .end:
            offset = rightmost
        case .day(let day, let trailing):
            if let position = layout.position(of: day) {
                let rect = layout.rect(for: position)
                offset = trailing ? rect.maxX - width : rect.minX
            } else {
                offset = 0
            }
        }
        contentView.scroll(to: NSPoint(x: min(rightmost, max(0, offset)), y: 0))
        reflectScrolledClipView(contentView)
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
           !event.modifierFlags.contains(.shift) {
            let verticalResponder = enclosingScrollView ?? nextResponder
            verticalResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

private final class HeatmapGridView: NSView, NSViewToolTipOwner {
    // AppKit makes these legacy accessibility queries on the main thread.
    // The element is returned synchronously to that same caller.
    private struct AccessibilityResult: @unchecked Sendable {
        let cell: HeatmapAccessibleDay?
    }

    private(set) var model: HeatmapGrid?
    private var hovered: DayKey?
    private var focusedDay: DayKey?
    private var pressed: DayKey?
    private var toolTipTag: NSView.ToolTipTag?
    private var tracking: NSTrackingArea?
    private var accessibleDays: [DayKey: HeatmapAccessibleDay] = [:]
    private lazy var dayFormatter = LogCalendar.dayFormatter()

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func update(_ model: HeatmapGrid) {
        let previous = self.model
        self.model = model
        if previous?.layout != model.layout || previous?.today != model.today {
            updateHover(nil)
            if let focusedDay, focusedDay > model.today || model.layout.position(of: focusedDay) == nil {
                self.focusedDay = nil
            }
        }
        if previous?.scene.name != model.scene.name {
            setAccessibilityLabel(model.scene.name)
        }
        if previous?.layout != model.layout || previous?.highlighted != model.highlighted
            || previous?.today != model.today || previous?.scene != model.scene
            || previous?.generation != model.generation {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let context = NSGraphicsContext.current?.cgContext else { return }
        let dirty = dirtyRect.intersection(visibleRect)
        let layout = model.layout
        let columns = layout.visibleColumns(in: dirty)
        guard !columns.isEmpty else { return }

        let base = NSColor(Color(logbookHex: model.scene.color))
        let secondary = NSColor.secondaryLabelColor
        let empty = secondary.withAlphaComponent(0.17).cgColor
        let future = secondary.withAlphaComponent(0.06).cgColor
        let foreground = NSColor.labelColor
        let focused = window?.firstResponder === self ? focusedDay : nil
        let monthStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: secondary
        ]
        let calendar = LogCalendar.displayCalendar
        // Month text can extend past its week into the visible area.
        let drawsMonths = layout.showsMonths && dirty.minY < layout.firstCellY
        let first = drawsMonths ? max(0, columns.lowerBound - 8) : columns.lowerBound
        for column in first..<columns.upperBound {
            let days = layout.days(in: column)
            if drawsMonths {
                drawMonth(in: days, x: layout.columnStart(column), today: model.today,
                          calendar: calendar, style: monthStyle)
            }
            guard columns.contains(column) else { continue }
            for (row, day) in days.enumerated() {
                guard let day else { continue }
                let rect = layout.rect(for: .init(column: column, row: row))
                guard dirty.intersects(rect) else { continue }
                let color: CGColor
                if day > model.today {
                    color = future
                } else if let summary = model.library.checkInDay(for: model.scene.id, on: day) {
                    color = base.withAlphaComponent(model.scene.intensity(summary.total)).cgColor
                } else {
                    color = empty
                }
                context.setFillColor(color)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
                context.fillPath()
                if day == hovered || day == model.highlighted || day == focused {
                    let stroke = foreground.withAlphaComponent(day == hovered || day == focused ? 0.9 : 0.55)
                    context.setStrokeColor(stroke.cgColor)
                    context.setLineWidth(1)
                    context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                           cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
                    context.strokePath()
                }
            }
        }
    }

    private func drawMonth(in days: [DayKey?], x: CGFloat, today: DayKey, calendar: Calendar,
                           style: [NSAttributedString.Key: Any]) {
        for case let day? in days where day <= today {
            let date = day.date
            let components = calendar.dateComponents([.month, .day], from: date)
            if components.day == 1 {
                let text = LogCalendar.label(date, template: components.month == 1 ? "yMMM" : "MMM",
                                             calendar: calendar)
                (text as NSString).draw(at: NSPoint(x: x, y: 4), withAttributes: style)
                return
            }
        }
    }

    private func day(at point: NSPoint) -> DayKey? {
        guard let model, let position = model.layout.position(at: point),
              let day = model.layout.days(in: position.column)[position.row], day <= model.today else { return nil }
        return day
    }

    func cellRect(for day: DayKey) -> NSRect? {
        guard let layout = model?.layout, let position = layout.position(of: day) else { return nil }
        return layout.rect(for: position)
    }

    @discardableResult
    func open(_ day: DayKey) -> Bool {
        guard let model, day <= model.today, model.layout.position(of: day) != nil else { return false }
        model.editDay(day)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow,
                                                       .mouseEnteredAndExited, .mouseMoved],
                                  owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { updateHover(nil) }
    override func mouseMoved(with event: NSEvent) {
        updateHover(day(at: convert(event.locationInWindow, from: nil)))
    }

    private func updateHover(_ day: DayKey?) {
        guard day != hovered else { return }
        if let hovered, let rect = cellRect(for: hovered) { setNeedsDisplay(rect) }
        if let toolTipTag { removeToolTip(toolTipTag) }
        hovered = day
        toolTipTag = nil
        if let day, let rect = cellRect(for: day) {
            setNeedsDisplay(rect)
            toolTipTag = addToolTip(rect, owner: self, userData: nil)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        guard let day = day(at: point) else { return "" }
        return ([dateLabel(for: day)] + details(for: day)).joined(separator: "\n")
    }

    override func mouseDown(with event: NSEvent) {
        pressed = day(at: convert(event.locationInWindow, from: nil))
        if let pressed {
            focusedDay = pressed
            if window?.firstResponder === self {
                focusDidChange()
            } else {
                window?.makeFirstResponder(self)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        if let pressed, day(at: convert(event.locationInWindow, from: nil)) == pressed { open(pressed) }
    }

    override func becomeFirstResponder() -> Bool {
        if focusedDay.flatMap(cellRect(for:)).map(visibleRect.intersects) != true {
            focusedDay = visibleDays().last
        }
        focusDidChange()
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let model, let current = focusedDay ?? visibleDays().last,
              let position = model.layout.position(of: current) else {
            super.keyDown(with: event)
            return
        }
        let delta: Int
        switch event.keyCode {
        case 36, 49, 76: open(current); return // Return, Space, keypad Enter
        case 123: delta = model.layout.showsMonths ? -7 : -1
        case 124: delta = model.layout.showsMonths ? 7 : 1
        case 125: delta = model.layout.showsMonths ? 1 : 7
        case 126: delta = model.layout.showsMonths ? -1 : -7
        default: super.keyDown(with: event); return
        }
        let index = position.column * 7 + position.row + delta
        let layout = model.layout
        guard (0..<(layout.columnCount * 7)).contains(index),
              let day = layout.days(in: index / 7)[index % 7], day <= model.today else { return }
        focusedDay = day
        if let rect = cellRect(for: day) { scrollToVisible(rect) }
        focusDidChange()
    }

    private func focusDidChange() {
        needsDisplay = true
        if let focusedDay {
            NSAccessibility.post(element: accessibleDay(focusedDay), notification: .focusedUIElementChanged)
        }
    }

    private func visibleDays() -> [DayKey] {
        guard let model else { return [] }
        let layout = model.layout
        let viewport = visibleRect
        return layout.visibleColumns(in: viewport).flatMap { column in
            layout.days(in: column).enumerated().compactMap { row, day in
                guard let day, day <= model.today,
                      viewport.intersects(layout.rect(for: .init(column: column, row: row))) else { return nil }
                return day
            }
        }
    }

    override func accessibilityChildren() -> [Any]? {
        let children = visibleDays().map(accessibleDay)
        accessibleDays = Dictionary(uniqueKeysWithValues: children.map { ($0.day, $0) })
        return children
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        let result = MainActor.assumeIsolated {
            if let window, let day = day(at: convert(window.convertPoint(fromScreen: point), from: nil)) {
                return AccessibilityResult(cell: accessibleDay(day))
            }
            return AccessibilityResult(cell: nil)
        }
        return result.cell ?? super.accessibilityHitTest(point)
    }

    override var accessibilityFocusedUIElement: Any? {
        let result = MainActor.assumeIsolated {
            if window?.firstResponder === self, let focusedDay {
                return AccessibilityResult(cell: accessibleDay(focusedDay))
            }
            return AccessibilityResult(cell: nil)
        }
        return result.cell ?? super.accessibilityFocusedUIElement
    }

    private func accessibleDay(_ day: DayKey) -> HeatmapAccessibleDay {
        if let existing = accessibleDays[day] { return existing }
        let cell = HeatmapAccessibleDay(day: day, grid: self)
        accessibleDays[day] = cell
        return cell
    }

    func dateLabel(for day: DayKey) -> String { dayFormatter.string(from: day.date) }

    func details(for day: DayKey) -> [String] {
        guard let model, let entry = model.library.checkInDay(for: model.scene.id, on: day) else {
            return [String(localized: "No entry")]
        }
        let scene = model.scene
        let headline = scene.kind == .quantity
            ? String(localized: "Total \(entry.total.formatted()) \(scene.unit)") : String(localized: "Completed")
        let notes = entry.entries.compactMap { record -> String? in
            guard !record.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if entry.entries.count > 1 {
                return "\(record.value.formatted()) \(scene.unit) · \(record.note)"
            }
            return record.note
        }
        return [headline] + notes
    }
}

@MainActor
private final class HeatmapAccessibleDay: NSAccessibilityElement {
    nonisolated let day: DayKey
    nonisolated private let grid: @MainActor @Sendable () -> HeatmapGridView?

    init(day: DayKey, grid: HeatmapGridView) {
        self.day = day
        self.grid = { [weak grid] in grid }
        super.init()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityParent(grid)
    }

    override func accessibilityLabel() -> String? {
        MainActor.assumeIsolated { [grid, day] in grid()?.dateLabel(for: day) }
    }
    override func accessibilityValue() -> Any? {
        let value: String? = MainActor.assumeIsolated { [grid, day] in
            grid()?.details(for: day).joined(separator: ", ")
        }
        return value
    }
    override func accessibilityFrame() -> NSRect {
        MainActor.assumeIsolated { [grid, day] in
            guard let grid = grid(), let window = grid.window, let rect = grid.cellRect(for: day) else { return .zero }
            return window.convertToScreen(grid.convert(rect, to: nil))
        }
    }
    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated { [grid, day] in grid()?.open(day) ?? false }
    }
}

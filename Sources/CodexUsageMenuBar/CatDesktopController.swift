import AppKit
import Combine
import SwiftUI

private enum CatAgentState: String {
  case working
  case waiting
  case done
  case idle

  var text: String {
    switch self {
    case .working: "작업 중"
    case .waiting: "입력 기다리는 중"
    case .done: "작업 완료"
    case .idle: ""
    }
  }
}

private struct CatAgentActivity {
  let state: CatAgentState
  let text: String
  let updatedAt: Date
}

private final class CatDesktopPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private final class CatDesktopHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class CatDesktopController: NSObject, ObservableObject, NSWindowDelegate {
  private let store: CatCollectionStore
  private let onOpen: () -> Void
  private let preferences: UserDefaults
  private var panel: NSPanel?
  private var activities: [String: CatAgentActivity] = [:]
  private var expirationTasks: [String: Task<Void, Never>] = [:]

  @Published private(set) var size: CGFloat
  @Published private(set) var lowPower: Bool
  @Published private(set) var activityText: String?

  var wantsVisible: Bool { preferences.bool(forKey: "cat.desktop.visible") }

  init(store: CatCollectionStore, onOpen: @escaping () -> Void) {
    self.store = store
    self.onOpen = onOpen
    preferences = .standard
    let savedSize = preferences.double(forKey: "cat.desktop.size")
    size = savedSize == 128 || savedSize == 160 ? savedSize : 96
    lowPower = preferences.bool(forKey: "cat.desktop.lowPower")
  }

  func toggle() { setVisible(!wantsVisible) }

  func setVisible(_ value: Bool) {
    preferences.set(value, forKey: "cat.desktop.visible")
    syncVisibility()
  }

  func syncVisibility() {
    guard wantsVisible, store.enabled else {
      panel?.orderOut(nil)
      panel?.contentView = nil
      panel = nil
      return
    }
    if let panel {
      panel.orderFrontRegardless()
      return
    }
    let frame = initialFrame()
    let panel = CatDesktopPanel(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false
    )
    panel.identifier = NSUserInterfaceItemIdentifier("UsageBarDesktopCat")
    panel.title = "UsageBar 바탕화면 고양이"
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.delegate = self
    panel.contentView = CatDesktopHostingView(
      rootView: CatDesktopView(controller: self, store: store)
    )
    self.panel = panel
    panel.orderFrontRegardless()
  }

  func handleActivity(_ url: URL) {
    guard url.scheme?.lowercased() == "harmon-usagebar", url.host?.lowercased() == "agent",
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
      let state = query.first(where: { $0.name == "state" })?.value.flatMap(CatAgentState.init)
    else { return }

    let sourceValue = query.first(where: { $0.name == "label" })?.value ?? ""
    let source = String(sourceValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
    let text = query.first(where: { $0.name == "message" })?.value ?? ""
    let message = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    expirationTasks[source]?.cancel()
    expirationTasks[source] = nil
    if state == .idle {
      activities[source] = nil
    } else {
      if activities[source] == nil, activities.count >= 12,
        let oldest = activities.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key
      {
        activities[oldest] = nil
        expirationTasks[oldest]?.cancel()
        expirationTasks[oldest] = nil
      }
      let label = source.isEmpty ? state.text : "\(source) · \(state.text)"
      activities[source] = CatAgentActivity(
        state: state, text: message.isEmpty ? label : "\(label)\n\(message)", updatedAt: .now
      )
      if state != .waiting {
        let seconds = state == .done ? 6 : 600
        expirationTasks[source] = Task { @MainActor [weak self] in
          do {
            try await Task.sleep(for: .seconds(seconds))
          } catch {
            return
          }
          guard !Task.isCancelled else { return }
          self?.activities[source] = nil
          self?.expirationTasks[source] = nil
          self?.updateActivity()
        }
      }
    }
    updateActivity()
  }

  func setSize(_ value: CGFloat) {
    guard [96, 128, 160].contains(value), size != value else { return }
    let origin = panel?.frame.origin
    size = value
    preferences.set(Double(value), forKey: "cat.desktop.size")
    if let origin {
      panel?.setFrame(visibleFrame(around: origin), display: true)
    }
  }

  func setLowPower(_ value: Bool) {
    lowPower = value
    preferences.set(value, forKey: "cat.desktop.lowPower")
  }

  func openHome() {
    onOpen()
    NotificationCenter.default.post(name: .catDesktopOpenHome, object: nil)
  }

  func windowDidMove(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window == panel else { return }
    preferences.set(window.frame.origin.x, forKey: "cat.desktop.x")
    preferences.set(window.frame.origin.y, forKey: "cat.desktop.y")
  }

  private func updateActivity() {
    let latestWaiting = activities.values.filter { $0.state == .waiting }.max { $0.updatedAt < $1.updatedAt }
    let latest = activities.values.max { $0.updatedAt < $1.updatedAt }
    activityText = (latestWaiting ?? latest)?.text
  }

  private var panelSize: NSSize { NSSize(width: max(200, size + 22), height: size + 80) }

  private func initialFrame() -> NSRect {
    if let x = preferences.object(forKey: "cat.desktop.x") as? Double,
      let y = preferences.object(forKey: "cat.desktop.y") as? Double, x.isFinite, y.isFinite
    {
      return visibleFrame(around: NSPoint(x: x, y: y))
    }
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    return visibleFrame(around: NSPoint(x: screen.maxX - panelSize.width - 24, y: screen.minY + 24))
  }

  private func visibleFrame(around origin: NSPoint) -> NSRect {
    let candidate = NSRect(origin: origin, size: panelSize)
    let screen =
      NSScreen.screens.first(where: { $0.visibleFrame.intersects(candidate) })?.visibleFrame
      ?? NSScreen.main?.visibleFrame
    guard let screen else { return candidate }
    let x = max(screen.minX, min(screen.maxX - panelSize.width, origin.x))
    let y = max(screen.minY, min(screen.maxY - panelSize.height, origin.y))
    return NSRect(origin: NSPoint(x: x, y: y), size: panelSize)
  }
}

@MainActor
private struct CatDesktopView: View {
  @ObservedObject var controller: CatDesktopController
  @ObservedObject var store: CatCollectionStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false

  private var today: String {
    let tokens = store.state.daily.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.tokens }
    return "오늘 \(tokens.formatted()) 토큰"
  }

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      if let caption = caption {
        Text(caption)
          .font(.caption)
          .multilineTextAlignment(.center)
          .lineLimit(3)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
          .padding(.horizontal, 5)
      }
      Button {
        controller.openHome()
      } label: {
        if reduceMotion || controller.lowPower {
          sprite(frame: hovering ? 1 : 0)
        } else {
          TimelineView(.periodic(from: .now, by: hovering ? 0.25 : 1)) { context in
            sprite(frame: Int(context.date.timeIntervalSince1970 * (hovering ? 4 : 1)) % 4)
          }
        }
      }
      .buttonStyle(.plain)
      .accessibilityLabel(store.displayedCat?.name ?? "고양이 상자")
      .accessibilityHint("고양이 수집 열기")
      .help(today)
      .onHover { hovering = $0 }
      .contextMenu {
        Button("고양이 수집 열기") { controller.openHome() }
        Button("사용량 새로고침") { store.refresh(force: true) }
        Menu("크기") {
          ForEach([96, 128, 160], id: \.self) { size in
            Button {
              controller.setSize(CGFloat(size))
            } label: {
              if Int(controller.size) == size {
                Label("\(size) pt", systemImage: "checkmark")
              } else {
                Text("\(size) pt")
              }
            }
          }
        }
        Toggle("저전력 모드", isOn: Binding(get: { controller.lowPower }, set: { controller.setLowPower($0) }))
        Divider()
        Button("바탕화면 고양이 숨기기") { controller.setVisible(false) }
      }
      CatDesktopDragArea()
        .frame(width: 52, height: 10)
        .accessibilityHidden(true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var caption: String? {
    if let text = controller.activityText { return text }
    return hovering ? today : nil
  }

  private func sprite(frame: Int) -> some View {
    let cat = store.displayedCat
    return CatSpriteView(
      kind: cat.flatMap { CatCatalog.kind($0.kindID) },
      coat: cat?.coat ?? 0,
      adult: store.displayedCatIsAdult,
      shiny: cat?.shiny ?? false,
      frameIndex: frame,
      size: controller.size
    )
  }
}

private struct CatDesktopDragArea: NSViewRepresentable {
  final class Handle: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
      window?.performDrag(with: event)
    }

    override func resetCursorRects() {
      addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
      NSColor.labelColor.withAlphaComponent(0.29).setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 16, dy: 3), xRadius: 2, yRadius: 2).fill()
    }
  }

  func makeNSView(context: Context) -> Handle { Handle() }
  func updateNSView(_ nsView: Handle, context: Context) {}
}

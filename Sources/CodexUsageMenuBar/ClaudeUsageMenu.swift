import AppKit
import Combine
import SwiftUI

let claudeUsageEnabledPreferenceKey = "claudeUsageEnabled"

@MainActor
final class ClaudeUsageMenu: NSObject, ObservableObject, NSPopoverDelegate {
  @Published private(set) var snapshot: ClaudeUsageSnapshot?

  private var statusItem: NSStatusItem?
  private var refreshTimer: AnyCancellable?
  private let popover = NSPopover()

  func setEnabled(_ enabled: Bool) {
    if enabled, statusItem == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      item.autosaveName = "ClaudeUsageMenuBarStatusItem"
      item.button?.target = self
      item.button?.action = #selector(togglePopover)
      statusItem = item
      refresh()
      refreshTimer = Timer.publish(every: 15, on: .main, in: .common)
        .autoconnect()
        .sink { [weak self] _ in self?.refresh() }
    } else if !enabled, let statusItem {
      popover.performClose(nil)
      popover.contentViewController = nil
      refreshTimer = nil
      NSStatusBar.system.removeStatusItem(statusItem)
      self.statusItem = nil
    }
  }

  func refresh() {
    guard let button = statusItem?.button else { return }
    let latest = ClaudeUsageSnapshot.readCache()
    if snapshot != latest {
      snapshot = latest
    }

    if let window = latest?.sevenDay ?? latest?.fiveHour {
      let period = latest?.sevenDay == nil ? "5시간" : "주간"
      button.title = "Claude \(window.remainingPercentage)%"
      button.toolTip = "Claude \(period) 잔여율 \(window.remainingPercentage)%"
    } else {
      button.title = "Claude —"
      button.toolTip = "Claude 사용량 대기 중"
    }
    button.setAccessibilityLabel(button.toolTip)
  }

  @objc private func togglePopover() {
    if popover.isShown {
      popover.performClose(nil)
      return
    }
    guard let button = statusItem?.button else { return }

    refresh()
    popover.behavior = .transient
    popover.delegate = self
    popover.contentViewController = NSHostingController(rootView: ClaudeUsagePopover(menu: self))
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
  }

  func popoverDidClose(_ notification: Notification) {
    popover.contentViewController = nil
  }
}

private struct ClaudeUsagePopover: View {
  @ObservedObject var menu: ClaudeUsageMenu
  @State private var copiedCommand = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Claude 사용량")
        .font(.headline)

      if let snapshot = menu.snapshot {
        if let fiveHour = snapshot.fiveHour {
          usageRow("5시간", window: fiveHour)
        }
        if let sevenDay = snapshot.sevenDay {
          usageRow("주간", window: sevenDay)
        }
        Text("수신 \(snapshot.receivedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text("Claude Code 상태줄을 연결하면 사용량이 표시됩니다. 연결한 뒤 Claude Code에서 응답을 한 번 받아 주세요.")
          .foregroundStyle(.secondary)
      }

      HStack {
        if let executable = Bundle.main.executableURL {
          Button(copiedCommand ? "복사됨" : "상태줄 명령 복사") {
            let path = executable.path.replacingOccurrences(of: "'", with: "'\\''")
            NSPasteboard.general.clearContents()
            copiedCommand = NSPasteboard.general.setString(
              "'\(path)' --capture-claude-usage", forType: .string
            )
          }
        }
        Spacer()
        Link("Usage 열기", destination: URL(string: "https://claude.ai/settings/usage")!)
      }
      .controlSize(.small)

      Text("복사한 명령을 Claude Code 설정의 statusLine.command에 지정하세요.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(width: 320, alignment: .leading)
  }

  private func usageRow(_ title: String, window: ClaudeUsageSnapshot.Window) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text("잔여 \(window.remainingPercentage)%")
          .fontWeight(.semibold)
      }
      ProgressView(value: 100 - window.usedPercentage, total: 100)
      Text("리셋 \(window.resetDate.formatted(date: .abbreviated, time: .shortened))")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

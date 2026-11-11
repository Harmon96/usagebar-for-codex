import AppKit
import Charts
import Combine
import SwiftUI

// 선택 기간과 그래프 집계 간격을 함께 정의한다.
enum AnalyticsPeriod: String, CaseIterable, Identifiable {
  case hour = "1h"
  case sixHours = "6h"
  case day = "1d"
  case week = "7d"
  case month = "30d"
  var id: String { rawValue }
  var hours: Int {
    switch self {
    case .hour: 1
    case .sixHours: 6
    case .day: 24
    case .week: 168
    case .month: 720
    }
  }
  var bucketCount: Int {
    switch self {
    case .hour, .sixHours: 12
    case .day: 24
    case .week: 28
    case .month: 30
    }
  }
}

// 새로고침 중에도 마지막 정상 조회 결과와 기준 시각을 유지한다.
@MainActor
final class UsageAnalyticsStore: ObservableObject {
  @Published private(set) var result: UsageAnalyticsResult?
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var updatedAt: Date?
  @Published var period: AnalyticsPeriod = .day

  func refresh() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let loaded = try await UsageAnalyticsLoader.load()
      result = loaded
      updatedAt = loaded.collectedAt
      errorMessage = nil
    } catch {
      errorMessage = "사용 기록을 읽지 못했습니다. 로컬 기록 폴더의 접근 권한을 확인한 뒤 다시 시도하세요."
    }
  }
}

// 메뉴바 팝오버와 독립된 창을 유지해 긴 사용 내역도 탐색할 수 있게 한다.
@MainActor
final class UsageAnalyticsWindowController: NSWindowController {
  static let shared = UsageAnalyticsWindowController()
  private let store = UsageAnalyticsStore()

  private init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1020, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false
    )
    window.title = "UsageBar · 사용 기록"
    window.minSize = NSSize(width: 850, height: 600)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.contentViewController = NSHostingController(rootView: UsageAnalyticsView(store: store))
    window.center()
  }

  required init?(coder: NSCoder) { nil }

  func present() {
    showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
    Task { await store.refresh() }
  }
}

private struct AnalyticsBucket: Identifiable {
  let id: Int
  let start: Date
  let end: Date
  var input = 0
  var cached = 0
  var output = 0
}

private struct AnalyticsModelRow: Identifiable {
  let id: String
  var input = 0
  var cached = 0
  var output = 0
  var reasoning = 0
  var records = 0
  var efforts: [String: Int] = [:]
  var total: Int { input + output }
}

// 로컬 기록을 선택 기간에 맞춰 토큰 종류와 모델별로 집계해 표시한다.
@MainActor
struct UsageAnalyticsView: View {
  @ObservedObject var store: UsageAnalyticsStore
  var compact = false

  private var end: Date { store.updatedAt ?? Date() }
  private var start: Date { end.addingTimeInterval(-Double(store.period.hours) * 3600) }
  private var records: [UsageAnalyticsRecord] {
    store.result?.records.filter { $0.timestamp >= start && $0.timestamp <= end } ?? []
  }

  private var buckets: [AnalyticsBucket] {
    let width = end.timeIntervalSince(start) / Double(store.period.bucketCount)
    var values = (0..<store.period.bucketCount).map { index in
      AnalyticsBucket(
        id: index, start: start.addingTimeInterval(Double(index) * width),
        end: start.addingTimeInterval(Double(index + 1) * width)
      )
    }
    for record in records {
      let index = min(values.count - 1, Int(record.timestamp.timeIntervalSince(start) / width))
      values[index].input += max(0, record.inputTokens - record.cachedInputTokens)
      values[index].cached += record.cachedInputTokens
      values[index].output += record.outputTokens
    }
    return values
  }

  private var models: [AnalyticsModelRow] {
    var rows: [String: AnalyticsModelRow] = [:]
    for record in records {
      var row = rows[record.model] ?? AnalyticsModelRow(id: record.model)
      row.input += record.inputTokens
      row.cached += record.cachedInputTokens
      row.output += record.outputTokens
      row.reasoning += record.reasoningTokens
      row.records += 1
      row.efforts[record.reasoningEffort ?? "미상", default: 0] += record.inputTokens + record.outputTokens
      rows[record.model] = row
    }
    return rows.values.sorted { $0.total == $1.total ? $0.id < $1.id : $0.total > $1.total }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: compact ? 12 : 22) {
        if !compact { header }
        if compact {
          HStack {
            Label("사용 기록", systemImage: "chart.xyaxis.line")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.secondary)
            Spacer()
            Text(models.reduce(0) { $0 + $1.total }.formatted(.number.notation(.compactName)) + " TOKENS")
              .font(.system(size: 10, weight: .semibold, design: .rounded))
              .foregroundStyle(.secondary)
          }
          HStack(spacing: 4) {
            ForEach(AnalyticsPeriod.allCases) { period in
              Button {
                store.period = period
              } label: {
                Text(period.rawValue)
                  .font(.system(size: 10, weight: .semibold, design: .rounded))
                  .frame(maxWidth: .infinity)
                  .padding(.vertical, 5)
                  .foregroundStyle(store.period == period ? Color.purple : Color.secondary)
                  .background(
                    store.period == period ? Color.purple.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                  )
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityAddTraits(store.period == period ? .isSelected : [])
            }
          }
          .padding(3)
          .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        } else {
          Picker("조회 기간", selection: $store.period) {
            ForEach(AnalyticsPeriod.allCases) { Text($0.rawValue).tag($0) }
          }.pickerStyle(.segmented).frame(maxWidth: 420)
        }

        if let error = store.errorMessage {
          Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        if store.isLoading && store.result == nil {
          ProgressView("최근 30일의 로컬 사용 기록을 읽고 있습니다…")
            .frame(maxWidth: .infinity, minHeight: 300)
        } else if records.isEmpty {
          ContentUnavailableView(
            "이 기간에 읽을 수 있는 기록이 없습니다", systemImage: "chart.bar.xaxis",
            description: Text("이 Mac에 저장된 Codex 세션 기록만 집계합니다. 기록이 없다는 것이 실제 사용량 0을 뜻하지는 않습니다.")
          ).frame(minHeight: 260)
        } else {
          if !compact { summary }
          chart
          if compact {
            ForEach(models) { model in
              HStack {
                Text(model.id).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(model.total.formatted(.number.notation(.compactName))) 토큰").font(.caption.monospacedDigit())
                  .fixedSize()
              }
            }
            Text("로컬 기록 기준 · 캐시 입력 포함 · 구독 잔여율과 별개")
              .font(.caption2).foregroundStyle(.secondary)
          } else {
            modelTable
          }
        }
        if !compact { coverage }
      }
      .padding(compact ? 12 : 28)
    }
    .background(compact ? Color.primary.opacity(0.025) : Color(nsColor: .windowBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: compact ? 12 : 0))
    .overlay {
      if compact {
        RoundedRectangle(cornerRadius: 12).strokeBorder(
          LinearGradient(
            colors: [.purple.opacity(0.22), .mint.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing),
          lineWidth: 1)
      }
    }
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Codex 사용 기록").font(.largeTitle.bold())
        Text("시간대별 토큰과 모델 사용 내역").foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        Task { await store.refresh() }
      } label: {
        Label(store.isLoading ? "읽는 중…" : "새로고침", systemImage: "arrow.clockwise")
      }.disabled(store.isLoading)
    }
  }

  private var summary: some View {
    HStack(spacing: 36) {
      metric("전체 토큰", value: models.reduce(0) { $0 + $1.total })
      metric("입력 토큰", value: models.reduce(0) { $0 + $1.input })
      metric("캐시 입력 · 입력에 포함", value: models.reduce(0) { $0 + $1.cached })
      metric("출력 토큰", value: models.reduce(0) { $0 + $1.output })
    }
  }

  private func metric(_ title: String, value: Int) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value.formatted(.number.notation(.compactName))).font(.title2.bold()).monospacedDigit()
        .help(value.formatted())
    }
  }

  private var chart: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !compact { Text("시간대별 사용량").font(.headline) }
      if !compact {
        Text(
          "\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .abbreviated, time: .shortened))"
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Chart(buckets) { bucket in
        AreaMark(
          x: .value("시각", bucket.start),
          y: .value("전체 토큰", bucket.input + bucket.cached + bucket.output)
        )
        .foregroundStyle(
          LinearGradient(colors: [.purple.opacity(0.18), .mint.opacity(0.015)], startPoint: .top, endPoint: .bottom))
        LineMark(
          x: .value("시각", bucket.start),
          y: .value("전체 토큰", bucket.input + bucket.cached + bucket.output)
        )
        .foregroundStyle(LinearGradient(colors: [.purple, .cyan, .mint], startPoint: .leading, endPoint: .trailing))
        .lineStyle(StrokeStyle(lineWidth: 2))
        PointMark(x: .value("시각", bucket.start), y: .value("전체 토큰", bucket.input + bucket.cached + bucket.output))
          .foregroundStyle(LinearGradient(colors: [.purple, .cyan, .mint], startPoint: .leading, endPoint: .trailing))
          .symbolSize(compact ? 6 : 16)

      }
      .chartXScale(domain: start...end)
      .chartYScale(domain: .automatic(includesZero: true))
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: compact ? 3 : 6)) { _ in
          AxisValueLabel().font(.system(size: 9)).foregroundStyle(Color.secondary.opacity(0.7))
        }
      }
      .chartYAxis {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(Color.primary.opacity(0.08))
          AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.notation(.compactName)).font(.system(size: 9))
            .foregroundStyle(
              Color.secondary.opacity(0.7))
        }
      }
      .frame(height: compact ? 140 : 300)
    }
  }

  private var modelTable: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("모델별 사용 내역").font(.headline)
      Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
        GridRow {
          ForEach(["모델 / 추론 강도", "기록", "입력", "캐시 입력", "출력", "추론 출력"], id: \.self) {
            Text($0).font(.caption).foregroundStyle(.secondary)
          }
        }
        Divider()
        ForEach(models) { model in
          GridRow {
            VStack(alignment: .leading, spacing: 3) {
              Text(model.id).fontWeight(.medium).textSelection(.enabled)
              Text(
                model.efforts.keys.sorted().map { effort in
                  "\(effort) · \((model.efforts[effort] ?? 0).formatted(.number.notation(.compactName))) 토큰"
                }.joined(separator: " / ")
              ).font(.caption).foregroundStyle(.secondary)
            }
            Text(model.records.formatted())
            Text(model.input.formatted())
            Text(model.cached.formatted())
            Text(model.output.formatted())
            Text(model.reasoning.formatted())
          }.monospacedDigit()
        }
      }
      Text("캐시 입력은 입력에, 추론 출력은 출력에 포함됩니다. 기록 수는 사용자 질문 수가 아니며, 도구 호출·하위 에이전트 작업이 포함될 수 있습니다.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var coverage: some View {
    VStack(alignment: .leading, spacing: 6) {
      Divider()
      Text("로컬 기록 기준 · 구독 잔여율 및 실제 청구액과 별개")
        .font(.callout.weight(.medium))
      Text(
        "이 Mac의 sessions와 archived_sessions에서 읽은 최근 30일 기록을 집계합니다. 다른 기기의 사용이나 삭제된 기록은 포함되지 않습니다. 모델·추론 강도가 기록에 없으면 미상으로 표시합니다."
      )
      if let result = store.result, result.skippedFiles > 0 || result.unsupportedFiles > 0 {
        Text("읽지 못한 파일 \(result.skippedFiles)개 · 지원하지 않는 압축 파일 \(result.unsupportedFiles)개. 합계는 일부 기록만 포함할 수 있습니다.")
          .foregroundStyle(.orange)
      }
      if let updatedAt = store.updatedAt {
        Text("마지막 집계: \(updatedAt.formatted(date: .abbreviated, time: .standard))")
      }
    }.font(.caption).foregroundStyle(.secondary)
  }
}

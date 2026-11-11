import Foundation
import Testing

@testable import CodexUsageMenuBar

@Suite("Local usage analytics")
struct UsageAnalyticsTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("Response identifiers deduplicate copied parent and child records")
  func modernDeduplication() throws {
    var parser = UsageAnalyticsParser(cutoff: now.addingTimeInterval(-3600), now: now)
    for file in ["parent", "child"] {
      parser.beginFile(identity: file)
      try feed(&parser, type: "turn_context", payload: ["model": "gpt-example", "effort": "high", "turn_id": "turn"])
      try feed(&parser, type: "token_usage_record", payload: ["response_id": "same", "usage": usage(100, 20)])
    }
    #expect(parser.records.count == 1)
    #expect(parser.records.first?.inputTokens == 100)
    #expect(parser.records.first?.cachedInputTokens == 80)
    #expect(parser.records.first?.outputTokens == 20)
    #expect(parser.records.first?.reasoningTokens == 5)
    #expect(parser.records.first?.reasoningEffort == "high")
  }

  @Test("Modern usage replaces same-turn legacy totals while keeping older turns")
  func modernPrecedence() throws {
    var parser = UsageAnalyticsParser(cutoff: now.addingTimeInterval(-3600), now: now)
    parser.beginFile(identity: "session")
    try feed(&parser, type: "turn_context", payload: ["turn_id": "older", "model": "old-model"])
    try legacy(&parser, total: usage(100, 20), last: usage(100, 20))
    try feed(&parser, type: "turn_context", payload: ["turn_id": "newer", "model": "new-model"])
    try legacy(&parser, total: usage(200, 40), last: usage(100, 20))
    try feed(
      &parser, type: "token_usage_record", payload: ["response_id": "new", "turn_id": "newer", "usage": usage(100, 20)])
    #expect(parser.records.count == 2)
    #expect(parser.records.map(\.inputTokens).reduce(0, +) == 200)
    #expect(Set(parser.records.map(\.model)) == ["old-model", "new-model"])
  }

  @Test("Legacy counters ignore duplicate snapshots and do not count inherited history")
  func legacyDeltas() throws {
    var parser = UsageAnalyticsParser(cutoff: now.addingTimeInterval(-3600), now: now)
    parser.beginFile(identity: "session")
    try legacy(&parser, total: usage(1000, 200), last: usage(100, 20))
    try legacy(&parser, total: usage(1000, 200), last: usage(100, 20))
    try legacy(&parser, total: usage(1150, 240), last: usage(150, 40))
    #expect(parser.records.count == 2)
    #expect(parser.records.map(\.inputTokens).reduce(0, +) == 250)
    #expect(parser.records.map(\.outputTokens).reduce(0, +) == 60)
  }

  @Test("Out-of-window and future observations are excluded")
  func rangeAndMalformed() throws {
    var parser = UsageAnalyticsParser(cutoff: now.addingTimeInterval(-3600), now: now)
    parser.beginFile(identity: "session")
    parser.consume(Data("not json".utf8))
    for offset in [-3601.0, 1.0] {
      try feed(
        &parser, type: "token_usage_record", payload: ["response_id": String(offset), "usage": usage(100, 20)],
        date: now.addingTimeInterval(offset))
    }
    #expect(parser.records.isEmpty)
  }

  @Test("Owner file model wins over copied usage in either traversal order")
  func ownerAttribution() throws {
    for order in [["parent", "child"], ["child", "parent"]] {
      var parser = UsageAnalyticsParser(cutoff: now.addingTimeInterval(-3600), now: now)
      for file in order {
        parser.beginFile(identity: file)
        try feed(&parser, type: "session_meta", payload: ["id": file])
        try feed(
          &parser, type: "turn_context",
          payload: ["turn_id": "shared-turn", "model": file + "-model", "effort": file == "child" ? "high" : "low"])
        try feed(
          &parser, type: "token_usage_record",
          payload: ["thread_id": "child", "turn_id": "shared-turn", "response_id": "copied", "usage": usage(100, 20)])
      }
      #expect(parser.records.count == 1)
      #expect(parser.records.first?.model == "child-model")
      #expect(parser.records.first?.reasoningEffort == "high")
    }
  }

  @Test("Foreign-only usage never inherits the host model or effort")
  func foreignAttribution() throws {
    var parser = UsageAnalyticsParser(cutoff: now.addingTimeInterval(-3600), now: now)
    parser.beginFile(identity: "parent")
    try feed(&parser, type: "session_meta", payload: ["id": "parent"])
    try feed(
      &parser, type: "turn_context", payload: ["turn_id": "shared-turn", "model": "parent-model", "effort": "high"])
    try feed(
      &parser, type: "token_usage_record",
      payload: ["thread_id": "child", "turn_id": "shared-turn", "response_id": "copied", "usage": usage(100, 20)])
    #expect(parser.records.first?.model == "확인 불가")
    #expect(parser.records.first?.reasoningEffort == nil)
    try feed(
      &parser, type: "token_usage_record",
      payload: [
        "thread_id": "child", "turn_id": "shared-turn", "response_id": "explicit", "model": "explicit-model",
        "usage": usage(100, 20),
      ])
    #expect(parser.records.contains { $0.model == "explicit-model" })
  }

  @Test("Reset cumulative counters preserve recurring totals and deduplicate copied files")
  func legacyReset() throws {
    var parser = UsageAnalyticsParser(cutoff: now.addingTimeInterval(-3600), now: now)
    for file in ["original", "copy"] {
      parser.beginFile(identity: file)
      try feed(&parser, type: "session_meta", payload: ["id": "same-session"])
      for (index, total) in [100, 200, 100].enumerated() {
        try feed(
          &parser, type: "event_msg",
          payload: [
            "type": "token_count",
            "info": ["total_token_usage": usage(total, total / 5), "last_token_usage": usage(100, 20)],
          ], date: now.addingTimeInterval(Double(index - 3)))
      }
    }
    #expect(parser.records.count == 3)
    #expect(parser.records.map(\.inputTokens).reduce(0, +) == 300)
  }

  private func usage(_ input: Int, _ output: Int) -> [String: Int] {
    ["input_tokens": input, "cached_input_tokens": 80, "output_tokens": output, "reasoning_output_tokens": 5]
  }

  private func legacy(_ parser: inout UsageAnalyticsParser, total: [String: Int], last: [String: Int]) throws {
    try feed(
      &parser, type: "event_msg",
      payload: ["type": "token_count", "info": ["total_token_usage": total, "last_token_usage": last]])
  }

  private func feed(_ parser: inout UsageAnalyticsParser, type: String, payload: [String: Any], date: Date? = nil)
    throws
  {
    let timestamp = ISO8601DateFormatter().string(from: date ?? now)
    parser.consume(
      try JSONSerialization.data(withJSONObject: ["timestamp": timestamp, "type": type, "payload": payload]))
  }
}

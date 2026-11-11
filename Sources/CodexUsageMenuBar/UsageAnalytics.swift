import Foundation

struct UsageAnalyticsRecord: Sendable {
  let timestamp: Date
  let model: String
  let inputTokens: Int
  let cachedInputTokens: Int
  let outputTokens: Int
  let reasoningTokens: Int
  let reasoningEffort: String?
}

struct UsageAnalyticsResult: Sendable {
  let records: [UsageAnalyticsRecord]
  let skippedFiles: Int
  let unsupportedFiles: Int
  let collectedAt: Date
}

// Reads only local usage metadata; conversation content is never retained or exported.
enum UsageAnalyticsLoader {
  static func load() async throws -> UsageAnalyticsResult {
    try await Task.detached(priority: .utility) {
      try load(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
    }.value
  }

  static func load(directory: URL, now: Date = Date()) throws -> UsageAnalyticsResult {
    let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
    var parser = UsageAnalyticsParser(cutoff: cutoff, now: now)
    var skipped = 0
    var unsupported = 0
    for folder in ["sessions", "archived_sessions"] {
      let root = directory.appendingPathComponent(folder)
      guard FileManager.default.fileExists(atPath: root.path) else { continue }
      guard
        let enumerator = FileManager.default.enumerator(
          at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
          options: [.skipsHiddenFiles],
          errorHandler: { _, _ in
            skipped += 1
            return true
          }
        )
      else {
        skipped += 1
        continue
      }
      for case let url as URL in enumerator {
        try Task.checkCancellation()
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
          values.isRegularFile == true
        else { continue }
        if let modified = values.contentModificationDate, modified < cutoff { continue }
        if url.pathExtension == "zst" {
          unsupported += 1
          continue
        }
        guard url.pathExtension == "jsonl" else { continue }
        do {
          let handle = try FileHandle(forReadingFrom: url)
          defer { try? handle.close() }
          parser.beginFile(identity: url.lastPathComponent)
          let invalidBefore = parser.invalidRecordCount
          var buffer = Data()
          var droppingOversizedLine = false
          while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
              let line = buffer[..<newline]
              if !droppingOversizedLine { parser.consume(Data(line)) }
              droppingOversizedLine = false
              buffer.removeSubrange(...newline)
            }
            // Individual conversation lines can be enormous; skip them without retaining their content.
            if buffer.count > 2 * 1024 * 1024 {
              buffer.removeAll(keepingCapacity: false)
              droppingOversizedLine = true
            }
          }
          if !buffer.isEmpty && !droppingOversizedLine { parser.consume(buffer) }
          if parser.invalidRecordCount > invalidBefore { skipped += 1 }
        } catch is CancellationError { throw CancellationError() } catch { skipped += 1 }
      }
    }
    return UsageAnalyticsResult(
      records: parser.records, skippedFiles: skipped, unsupportedFiles: unsupported, collectedAt: now)
  }
}

// Prefers per-response records and excludes legacy counters for turns containing those records.
struct UsageAnalyticsParser {
  private struct Candidate {
    let record: UsageAnalyticsRecord
    let turn: String
    let identity: String
    let isOwner: Bool
  }
  let cutoff: Date
  let now: Date
  private var modern: [String: Candidate] = [:]
  private var legacy: [String: Candidate] = [:]
  private var modernTurns = Set<String>()
  private var file = ""
  private var session = ""
  private var turn = ""
  private var model = "확인 불가"
  private var effort: String?
  private var previous: [String: Int] = [:]
  private var contexts: [String: (model: String, effort: String?)] = [:]
  private let dateParser = ISO8601DateFormatter()
  private(set) var invalidRecordCount = 0

  init(cutoff: Date, now: Date) {
    self.cutoff = cutoff
    self.now = now
  }

  var records: [UsageAnalyticsRecord] {
    (Array(modern.values) + legacy.values.filter { !modernTurns.contains($0.turn) })
      .map(\.record).sorted { $0.timestamp < $1.timestamp }
  }

  mutating func beginFile(identity: String) {
    file = identity
    session = identity
    turn = identity
    model = "확인 불가"
    effort = nil
    previous = [:]
    contexts = [:]
  }

  mutating func consume(_ data: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = object["type"] as? String,
      let payload = object["payload"] as? [String: Any]
    else { return }
    if type == "session_meta" {
      session = payload["id"] as? String ?? file
      turn = session
      return
    }
    if type == "turn_context" {
      turn = payload["turn_id"] as? String ?? session
      model = payload["model"] as? String ?? "확인 불가"
      effort = payload["effort"] as? String
      contexts[turn] = (model, effort)
      return
    }
    let isModern = type == "token_usage_record" || payload["type"] as? String == "token_usage_record"
    let isLegacy = type == "event_msg" && payload["type"] as? String == "token_count"
    guard isModern || isLegacy else { return }
    guard let timestamp = object["timestamp"] as? String else {
      invalidRecordCount += 1
      return
    }
    dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = dateParser.date(from: timestamp)
    if date == nil {
      dateParser.formatOptions = [.withInternetDateTime]
      date = dateParser.date(from: timestamp)
    }
    guard let date else {
      invalidRecordCount += 1
      return
    }
    let recordTurn = payload["turn_id"] as? String ?? turn
    let owner = isModern ? (payload["thread_id"] as? String ?? session) : session
    let isOwner = owner == session
    let turnKey = owner + ":" + recordTurn
    var usage: [String: Any]
    var identity: String
    if isModern {
      guard let response = payload["response_id"] as? String,
        let measured = payload["usage"] as? [String: Any]
      else {
        invalidRecordCount += 1
        return
      }
      modernTurns.insert(turnKey)
      usage = measured
      identity = response
    } else {
      guard let info = payload["info"] as? [String: Any],
        let totals = info["total_token_usage"] as? [String: Any]
      else { return }
      let keys = ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens"]
      let current = Dictionary(uniqueKeysWithValues: keys.map { ($0, max(0, totals[$0] as? Int ?? 0)) })
      // The first cumulative observation can contain inherited history. Use its last response only.
      if previous.isEmpty || current["input_tokens", default: 0] < previous["input_tokens", default: 0] {
        usage = info["last_token_usage"] as? [String: Any] ?? [:]
      } else {
        usage = Dictionary(
          uniqueKeysWithValues: keys.map { ($0, max(0, current[$0, default: 0] - previous[$0, default: 0])) })
      }
      previous = current
      identity = session + ":" + timestamp + ":" + keys.map { String(current[$0, default: 0]) }.joined(separator: ":")
    }
    guard date >= cutoff, date <= now else { return }
    guard let measuredInput = usage["input_tokens"] as? Int,
      let measuredOutput = usage["output_tokens"] as? Int
    else {
      invalidRecordCount += 1
      return
    }
    let input = max(0, measuredInput)
    let output = max(0, measuredOutput)
    guard input > 0 || output > 0 else { return }
    let record = UsageAnalyticsRecord(
      timestamp: date,
      model: payload["model"] as? String
        ?? (isOwner ? (contexts[recordTurn]?.model ?? (recordTurn == turn ? model : "확인 불가")) : "확인 불가"),
      inputTokens: input, cachedInputTokens: min(input, max(0, usage["cached_input_tokens"] as? Int ?? 0)),
      outputTokens: output, reasoningTokens: min(output, max(0, usage["reasoning_output_tokens"] as? Int ?? 0)),
      reasoningEffort: payload["reasoning_effort"] as? String
        ?? (isOwner ? (contexts[recordTurn]?.effort ?? (recordTurn == turn ? effort : nil)) : nil)
    )
    let candidate = Candidate(record: record, turn: turnKey, identity: identity, isOwner: isOwner)
    if isModern {
      if modern[identity]?.isOwner != true || isOwner { modern[identity] = candidate }
    } else {
      legacy[identity] = candidate
    }
  }
}

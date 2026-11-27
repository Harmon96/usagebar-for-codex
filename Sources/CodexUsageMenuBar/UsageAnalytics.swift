import Foundation

struct UsageAnalyticsRecord: Sendable {
  let timestamp: Date
  let model: String
  let inputTokens: Int
  let cachedInputTokens: Int
  let outputTokens: Int
  let reasoningTokens: Int
  let reasoningEffort: String?
  let growthKey: String
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
    try load(roots: sessionRoots(directory), since: now.addingTimeInterval(-30 * 24 * 60 * 60), now: now)
  }

  private static func sessionRoots(_ directory: URL) -> [URL] {
    ["sessions", "archived_sessions"].map { directory.appendingPathComponent($0) }
  }

  private static let collectionCache = CollectionUsageCache()

  static func loadForCats(extra: [URL], since: Date, now: Date) async -> CatUsageBatch {
    let home = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    let configured = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
    let locations = Array(Set(sessionRoots(home) + (configured.map(sessionRoots) ?? []) + extra))
    return await loadForCats(roots: locations, since: since, now: now)
  }

  static func loadForCats(roots: [URL], since: Date, now: Date) async -> CatUsageBatch {
    do {
      let result = try await collectionCache.load(roots: roots, since: since, now: now)
      // A modern per-request series can replace a previously observed legacy turn.
      // Credit the turn total so that switching formats cannot grant it twice.
      let byTurn = Dictionary(grouping: result.records, by: \.growthKey)
      let samples = byTurn.compactMap { key, records -> CatUsageSample? in
        guard let date = records.last?.timestamp else { return nil }
        let tokens = records.reduce(Int64(0)) {
          $0 + Int64(clamping: min($1.inputTokens, 100_000_000_000))
            + Int64(clamping: min($1.outputTokens, 100_000_000_000))
        }
        return CatUsageSample(id: key, date: date, tokens: tokens)
      }
      let omitted = result.skippedFiles + result.unsupportedFiles
      let status = omitted > 0 ? "읽지 못한 기록 파일 \(omitted)개" : (samples.isEmpty ? "새 기록 대기 중" : nil)
      return CatUsageBatch(samples: samples, status: status)
    } catch {
      return CatUsageBatch(samples: [], status: "Codex 기록을 읽지 못했습니다.")
    }
  }

  private struct FileEntry {
    let modified: Date
    let size: Int
    let identifier: NSObject
    let parser: UsageAnalyticsParser
  }

  private actor CollectionUsageCache {
    private var cutoff: Date?
    private var files: [URL: FileEntry] = [:]

    func load(roots: [URL], since: Date, now: Date) throws -> UsageAnalyticsResult {
      if cutoff != since {
        files.removeAll()
        cutoff = since
      }
      var entries: [URL: FileEntry]? = files
      let result = try UsageAnalyticsLoader.load(roots: roots, since: since, now: now, cache: &entries)
      files = entries ?? [:]
      return result
    }
  }

  private static func load(roots: [URL], since cutoff: Date, now: Date) throws -> UsageAnalyticsResult {
    var disabledCache: [URL: FileEntry]?
    return try load(roots: roots, since: cutoff, now: now, cache: &disabledCache)
  }

  private static func load(
    roots: [URL], since cutoff: Date, now: Date, cache: inout [URL: FileEntry]?
  ) throws -> UsageAnalyticsResult {
    var updatedCache: [URL: FileEntry] = [:]
    var parser = UsageAnalyticsParser(cutoff: cutoff, now: now)
    var skipped = 0
    var unsupported = 0
    let resourceKeys: Set<URLResourceKey> = [
      .isRegularFileKey, .contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey,
    ]
    for root in roots.sorted(by: { $0.path < $1.path }) {
      guard FileManager.default.fileExists(atPath: root.path) else { continue }
      guard
        let enumerator = FileManager.default.enumerator(
          at: root, includingPropertiesForKeys: Array(resourceKeys),
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
        guard let values = try? url.resourceValues(forKeys: resourceKeys),
          values.isRegularFile == true
        else { continue }
        if let modified = values.contentModificationDate, modified < cutoff { continue }
        if url.pathExtension == "zst" {
          unsupported += 1
          continue
        }
        guard url.pathExtension == "jsonl" else { continue }
        do {
          if cache != nil, let modified = values.contentModificationDate, let size = values.fileSize,
            let identifier = values.fileResourceIdentifier as? NSObject
          {
            let entry: FileEntry
            if let saved = cache?[url], saved.modified == modified, saved.size == size,
              saved.identifier == identifier, FileManager.default.isReadableFile(atPath: url.path),
              saved.parser.now <= now, saved.parser.nextTimestamp.map({ now < $0 }) ?? true
            {
              entry = saved
            } else {
              var perFile = UsageAnalyticsParser(cutoff: cutoff, now: now)
              try readFile(url, into: &perFile)
              entry = FileEntry(modified: modified, size: size, identifier: identifier, parser: perFile)
            }
            if updatedCache.count < 1_024 { updatedCache[url] = entry }
            parser.merge(entry.parser)
            if entry.parser.invalidRecordCount > 0 { skipped += 1 }
          } else {
            let invalidBefore = parser.invalidRecordCount
            try readFile(url, into: &parser)
            if parser.invalidRecordCount > invalidBefore { skipped += 1 }
          }
        } catch is CancellationError { throw CancellationError() } catch { skipped += 1 }
      }
    }
    if cache != nil { cache = updatedCache }
    return UsageAnalyticsResult(
      records: parser.records, skippedFiles: skipped, unsupportedFiles: unsupported, collectedAt: now)
  }

  private static func readFile(_ url: URL, into parser: inout UsageAnalyticsParser) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    parser.beginFile(identity: url.lastPathComponent)
    let limit = 2 * 1024 * 1024
    var buffer = Data()
    var droppingOversizedLine = false
    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
      try Task.checkCancellation()
      buffer.append(chunk)
      while let newline = buffer.firstIndex(of: 10) {
        let line = buffer[..<newline]
        if !droppingOversizedLine && line.count <= limit { parser.consume(Data(line)) }
        droppingOversizedLine = false
        buffer.removeSubrange(...newline)
      }
      if buffer.count > limit {
        buffer.removeAll(keepingCapacity: false)
        droppingOversizedLine = true
      }
    }
    if !buffer.isEmpty && !droppingOversizedLine { parser.consume(buffer) }
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
  private(set) var nextTimestamp: Date?

  init(cutoff: Date, now: Date) {
    self.cutoff = cutoff
    self.now = now
  }

  var records: [UsageAnalyticsRecord] {
    (Array(modern.values) + legacy.values.filter { !modernTurns.contains($0.turn) })
      .map(\.record).sorted { $0.timestamp < $1.timestamp }
  }

  fileprivate mutating func merge(_ file: UsageAnalyticsParser) {
    modernTurns.formUnion(file.modernTurns)
    for (key, candidate) in file.modern where modern[key]?.isOwner != true || candidate.isOwner {
      modern[key] = candidate
    }
    legacy.merge(file.legacy) { _, newer in newer }
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
    guard date >= cutoff else { return }
    guard date <= now else {
      nextTimestamp = min(nextTimestamp ?? date, date)
      return
    }
    if isModern { modernTurns.insert(turnKey) }
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
        ?? (isOwner ? (contexts[recordTurn]?.effort ?? (recordTurn == turn ? effort : nil)) : nil),
      growthKey: turnKey
    )
    let candidate = Candidate(record: record, turn: turnKey, identity: identity, isOwner: isOwner)
    if isModern {
      if modern[identity]?.isOwner != true || isOwner { modern[identity] = candidate }
    } else {
      legacy[identity] = candidate
    }
  }
}

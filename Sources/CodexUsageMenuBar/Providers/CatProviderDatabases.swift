import Foundation
import SQLite3

// Local table shapes adapted from PokeTokenBar (MIT), commit 38e3e5532846d407ae1a80fe15c4e49a0c263d65.
extension CatProviderScan {
  mutating func readDatabase(_ url: URL) {
    guard let db = CatProviderDatabase(url) else {
      skipped += 1
      return
    }
    let records: [CatUsageSample]?
    switch provider {
    case .antigravity: records = antigravityRecords(db, url: url)
    case .aside: records = asideRecords(db)
    case .copilot: records = copilotRecords(db)
    case .cursor: records = cursorRecords(db)
    case .devin: records = devinRecords(db)
    case .hermes: records = hermesRecords(db)
    case .openCode:
      if readOpenCode(db) { filesRead += 1 } else { skipped += 1 }
      return
    case .kiro:
      if readKiro(db) { filesRead += 1 } else { skipped += 1 }
      return
    default: return
    }
    guard let records else {
      skipped += 1
      return
    }
    filesRead += 1
    for sample in records { add(sample) }
  }

  private func asideRecords(_ db: CatProviderDatabase) -> [CatUsageSample]? {
    db.rows(
      """
      SELECT id, session_id, token_usage, COALESCE(started_at, finished_at, last_message_timestamp)
      FROM session_turns WHERE COALESCE(started_at, finished_at, last_message_timestamp) >= ?1
      """,
      since.timeIntervalSince1970
    ) { row in
      guard let usage = row.object(2), let date = date(row.number(3)) else { return nil }
      let tokens = Self.sum(usage, ["input", "output", "cacheRead", "cacheWrite"])
      let cost = Self.cost((usage["cost"] as? JSON)?["total"])
      let id = "\(row.text(1) ?? db.identity)|\(row.integer(0))|\(date.timeIntervalSince1970)"
      return .init(id: id, date: date, tokens: tokens == 0 ? Self.count(usage["totalTokens"]) : tokens, costUSD: cost)
    }
  }

  private func copilotRecords(_ db: CatProviderDatabase) -> [CatUsageSample]? {
    db.rows(
      """
      SELECT id, session_id, input_tokens, output_tokens, created_at
      FROM assistant_usage_events WHERE created_at >= ?1
      """,
      self.isoCutoff
    ) { row in
      guard let date = date(row.text(4)) else { return nil }
      let id = "\(row.text(1) ?? db.identity)|\(row.integer(0))|\(date.timeIntervalSince1970)"
      return .init(id: id, date: date, tokens: row.count(2) + row.count(3))
    }
  }

  // A lexical SQLite timestamp prefilter must tolerate zone offsets and both timestamp styles.
  private var isoCutoff: String {
    let seconds = since.addingTimeInterval(-86_400)
    let day = ISO8601DateFormatter().string(from: seconds).prefix(10)
    return String(day)
  }

  private func cursorRecords(_ db: CatProviderDatabase) -> [CatUsageSample]? {
    db.rows("SELECT key, value FROM cursorDiskKV WHERE key GLOB 'bubbleId:*'") { row in
      guard let id = row.text(0), let blob = row.object(1), let date = date(blob["createdAt"]),
        let usage = blob["tokenCount"] as? JSON
      else { return nil }
      return .init(id: id, date: date, tokens: Self.sum(usage, ["inputTokens", "outputTokens"]))
    }
  }

  private func devinRecords(_ db: CatProviderDatabase) -> [CatUsageSample]? {
    db.rows(
      """
      SELECT row_id, chat_message, session_id, created_at
      FROM message_nodes WHERE created_at >= ?1
      """,
      since.addingTimeInterval(-86_400).timeIntervalSince1970
    ) { row in
      guard let object = row.object(1), let metadata = object["metadata"] as? JSON,
        let metrics = metadata["metrics"] as? JSON, let date = date(row.number(3))
      else { return nil }
      let tokens = Self.sum(metrics, ["input_tokens", "output_tokens", "cache_creation_tokens", "cache_read_tokens"])
      let id = Self.string(object["message_id"]) ?? "\(db.identity)|\(row.integer(0))"
      return .init(id: "\(row.text(2) ?? "")|\(id)", date: date, tokens: tokens)
    }
  }

  private func hermesRecords(_ db: CatProviderDatabase) -> [CatUsageSample]? {
    db.rows(
      """
      SELECT id, started_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
             reasoning_tokens, actual_cost_usd, estimated_cost_usd
      FROM sessions WHERE started_at >= ?1
      """,
      since.timeIntervalSince1970
    ) { row in
      guard let id = row.text(0), let date = date(row.number(1)) else { return nil }
      let tokens = (2...6).reduce(Int64(0)) { $0 + row.count(Int32($1)) }
      let actualCost = Self.cost(row.number(7))
      return .init(
        id: id, date: date, tokens: tokens, costUSD: actualCost ?? Self.cost(row.number(8)),
        costEstimated: actualCost == nil)
    }
  }

  private mutating func readOpenCode(_ db: CatProviderDatabase) -> Bool {
    typealias UsageRow = (id: String, date: Date?, message: JSON)
    let cutoff = since.timeIntervalSince1970 * 1_000
    guard let hasProjected = db.hasTable("session_message"), let hasLegacy = db.hasTable("message"),
      hasProjected || hasLegacy
    else { return false }

    let projected: [UsageRow]? =
      hasProjected
      ? db.rows(
        """
        SELECT id, time_created, data FROM session_message
        WHERE type = 'assistant' AND time_created >= ?1
        """, cutoff
      ) { row in
        guard let id = row.text(0), let time = date(row.number(1)), let message = row.object(2) else { return nil }
        return (id, time, message)
      } : []
    func message(_ row: CatProviderDatabase.Row) -> UsageRow? {
      guard let id = row.text(0), let message = row.object(1) else { return nil }
      return (id, nil, message)
    }
    let legacy: [UsageRow]? =
      hasLegacy
      ? db.rows("SELECT id, data FROM message WHERE time_created >= ?1", cutoff, read: message)
        ?? db.rows("SELECT id, data FROM message", read: message)
      : []
    guard let projected, let legacy else { return false }
    for row in projected + legacy {
      addOpenCode(row.message, fallbackID: row.id, v2Date: row.date)
    }
    return true
  }
}

final class CatProviderDatabase {
  let identity: String
  private let db: OpaquePointer

  init?(_ url: URL) {
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
    let wal = url.path + "-wal"
    // Prefer the live read-only state, including any committed pages in the WAL. A
    // checkpointed store can be read immutably when its directory is read-only.
    let candidates =
      FileManager.default.fileExists(atPath: wal)
      ? [url.path]
      : [url.path, url.absoluteString + "?immutable=1"]
    var opened: OpaquePointer?
    for path in candidates {
      if sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle {
        sqlite3_busy_timeout(handle, 400)
        if sqlite3_exec(handle, "SELECT 1 FROM sqlite_schema LIMIT 1", nil, nil, nil) == SQLITE_OK {
          opened = handle
          break
        }
      }
      if let handle { sqlite3_close_v2(handle) }
      handle = nil
    }
    guard let opened else { return nil }
    self.db = opened
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let inode = (attributes?[.systemFileNumber] as? NSNumber)?.stringValue ?? "?"
    identity = url.path + "#" + inode
  }

  deinit { sqlite3_close_v2(db) }

  func hasTable(_ name: String) -> Bool? {
    rows("SELECT 1 FROM sqlite_schema WHERE type IN ('table', 'view') AND name = ?1", name) { $0.integer(0) }
      .map { !$0.isEmpty }
  }

  func rows<Value>(
    _ sql: String, _ parameter: Any? = nil, read: (Row) -> Value?
  ) -> [Value]? {
    var statement: OpaquePointer?
    let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    defer { sqlite3_finalize(statement) }
    guard prepared == SQLITE_OK, let statement else { return nil }
    if let parameter = parameter as? Double {
      sqlite3_bind_double(statement, 1, parameter)
    } else if let parameter = parameter as? String {
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      _ = parameter.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
    }
    var result: [Value] = []
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
      if Task.isCancelled { return nil }
      autoreleasepool {
        if let value = read(Row(statement: statement)) { result.append(value) }
      }
      status = sqlite3_step(statement)
    }
    return status == SQLITE_DONE ? result : nil
  }

  struct Row {
    fileprivate let statement: OpaquePointer

    func text(_ column: Int32) -> String? {
      guard let pointer = sqlite3_column_text(statement, column) else { return nil }
      return String(cString: pointer)
    }

    func object(_ column: Int32) -> CatProviderScan.JSON? {
      data(column).flatMap(CatProviderScan.object)
    }

    func data(_ column: Int32) -> Data? {
      let size = Int(sqlite3_column_bytes(statement, column))
      guard size > 0, size <= 32 * 1024 * 1024, let pointer = sqlite3_column_blob(statement, column) else { return nil }
      return Data(bytes: pointer, count: size)
    }

    func number(_ column: Int32) -> Double? {
      guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
      return sqlite3_column_double(statement, column)
    }

    func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }

    func count(_ column: Int32) -> Int64 { CatProviderScan.count(number(column)) }
  }
}

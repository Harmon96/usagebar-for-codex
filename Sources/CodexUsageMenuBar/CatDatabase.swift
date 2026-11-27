import Foundation
import SQLite3

enum CatSaveError: LocalizedError {
  case invalidSave
  case storage

  var errorDescription: String? {
    switch self {
    case .invalidSave: "고양이 저장 파일을 읽을 수 없습니다. 백업 파일을 선택해 복원하세요."
    case .storage: "고양이 기록을 저장하지 못했습니다. 디스크와 폴더 쓰기 권한을 확인하세요."
    }
  }
}

final class CatDatabase {
  private let handle: OpaquePointer

  init(url: URL, create: Bool, readOnly: Bool = false) throws {
    var pointer: OpaquePointer?
    let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
    guard sqlite3_open_v2(url.path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
      sqlite3_close(pointer)
      throw CatSaveError.storage
    }
    handle = pointer
    sqlite3_busy_timeout(handle, 2_000)
    sqlite3_exec(handle, "PRAGMA trusted_schema=OFF", nil, nil, nil)
    // Keep a single portable file for atomic replacement after validation.
    if create {
      try execute("CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id = 1), payload BLOB NOT NULL)")
      try execute("CREATE TABLE IF NOT EXISTS credits (id TEXT PRIMARY KEY, tokens INTEGER NOT NULL)")
    }
    if !readOnly {
      try execute(
        """
        CREATE TABLE IF NOT EXISTS credited_costs (
          id TEXT PRIMARY KEY, amount REAL, estimated INTEGER NOT NULL
        )
        """)
    }
  }

  deinit { sqlite3_close(handle) }

  func transaction(_ body: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE")
    do {
      try body()
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func load() throws -> CatCollectionState {
    let check = try statement("PRAGMA quick_check")
    defer { sqlite3_finalize(check) }
    guard sqlite3_step(check) == SQLITE_ROW, let result = sqlite3_column_text(check, 0),
      String(cString: result) == "ok"
    else { throw CatSaveError.invalidSave }
    guard let snapshot = try currentState() else { throw CatSaveError.invalidSave }
    let ledger = try statement("SELECT tokens FROM credits WHERE id = ''")
    sqlite3_finalize(ledger)
    return snapshot
  }

  func currentState() throws -> CatCollectionState? {
    let query = try statement("SELECT payload FROM state WHERE id = 1")
    defer { sqlite3_finalize(query) }
    let resultCode = sqlite3_step(query)
    if resultCode == SQLITE_DONE { return nil }
    guard resultCode == SQLITE_ROW, let pointer = sqlite3_column_blob(query, 0) else {
      throw CatSaveError.invalidSave
    }
    let payload = Data(bytes: pointer, count: Int(sqlite3_column_bytes(query, 0)))
    let snapshot = try JSONDecoder().decode(CatCollectionState.self, from: payload)
    try snapshot.validate()
    return snapshot
  }

  func save(_ state: CatCollectionState) throws {
    let query = try statement("INSERT INTO state VALUES(1, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload")
    defer { sqlite3_finalize(query) }
    let data = try JSONEncoder().encode(state)
    let result = data.withUnsafeBytes { bytes in
      guard sqlite3_bind_blob(query, 1, bytes.baseAddress, Int32(bytes.count), nil) == SQLITE_OK else {
        return SQLITE_ERROR
      }
      let result = sqlite3_step(query)
      sqlite3_reset(query)
      sqlite3_clear_bindings(query)
      return result
    }
    guard result == SQLITE_DONE else { throw CatSaveError.storage }
  }

  func credit(id: String, total: Int64) throws -> Int64 {
    let read = try statement("SELECT tokens FROM credits WHERE id = ?")
    defer { sqlite3_finalize(read) }
    let previous: Int64 = try id.withCString { text in
      guard sqlite3_bind_text(read, 1, text, -1, nil) == SQLITE_OK else { throw CatSaveError.storage }
      defer {
        sqlite3_reset(read)
        sqlite3_clear_bindings(read)
      }
      switch sqlite3_step(read) {
      case SQLITE_ROW: return sqlite3_column_int64(read, 0)
      case SQLITE_DONE: return 0
      default: throw CatSaveError.storage
      }
    }
    guard previous >= 0 else { throw CatSaveError.invalidSave }
    guard total > previous else { return 0 }
    let write = try statement("INSERT INTO credits VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET tokens = excluded.tokens")
    defer { sqlite3_finalize(write) }
    let result = id.withCString { text in
      guard sqlite3_bind_text(write, 1, text, -1, nil) == SQLITE_OK,
        sqlite3_bind_int64(write, 2, total) == SQLITE_OK
      else { return SQLITE_ERROR }
      let result = sqlite3_step(write)
      sqlite3_reset(write)
      sqlite3_clear_bindings(write)
      return result
    }
    guard result == SQLITE_DONE else { throw CatSaveError.storage }
    return total - previous
  }

  func creditUsage(id: String, sample: CatUsageSample) throws -> (tokens: Int64, recorded: Double?, estimated: Double?)
  {
    let tokens = try credit(id: id, total: sample.tokens)
    let query = try statement("SELECT amount, estimated FROM credited_costs WHERE id = ?1")
    defer { sqlite3_finalize(query) }
    let previous = try id.withCString { text -> (exists: Bool, cost: Double?, estimated: Bool) in
      guard sqlite3_bind_text(query, 1, text, -1, nil) == SQLITE_OK else { throw CatSaveError.storage }
      defer {
        sqlite3_reset(query)
        sqlite3_clear_bindings(query)
      }
      switch sqlite3_step(query) {
      case SQLITE_DONE: return (false, nil, false)
      case SQLITE_ROW:
        let amount = sqlite3_column_type(query, 0) == SQLITE_NULL ? nil : sqlite3_column_double(query, 0)
        return (true, amount, sqlite3_column_int(query, 1) == 1)
      default: throw CatSaveError.storage
      }
    }
    let amount = sample.costUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    if previous.exists && amount == nil { return (tokens, nil, nil) }
    if previous.exists && previous.cost == amount && previous.estimated == sample.costEstimated {
      return (tokens, nil, nil)
    }
    let write = try statement(
      """
      INSERT INTO credited_costs VALUES(?1, ?2, ?3)
      ON CONFLICT(id) DO UPDATE SET amount = excluded.amount, estimated = excluded.estimated
      """)
    defer { sqlite3_finalize(write) }
    let result = id.withCString { text in
      defer {
        sqlite3_reset(write)
        sqlite3_clear_bindings(write)
      }
      guard sqlite3_bind_text(write, 1, text, -1, nil) == SQLITE_OK,
        sqlite3_bind_int(write, 3, sample.costEstimated ? 1 : 0) == SQLITE_OK
      else { return SQLITE_ERROR }
      let bound = amount.map { sqlite3_bind_double(write, 2, $0) } ?? sqlite3_bind_null(write, 2)
      return bound == SQLITE_OK ? sqlite3_step(write) : bound
    }
    guard result == SQLITE_DONE else { throw CatSaveError.storage }
    // Earlier saves retained daily sums but had no per-record cost. Preserve that
    // history and apply exact corrections starting with the first observation here.
    let oldAmount =
      previous.exists
      ? previous.cost
      : amount.map { $0 * (1 - Double(tokens) / Double(sample.tokens)) }
    let oldEstimate = previous.exists ? previous.estimated : sample.costEstimated
    func delta(_ estimated: Bool) -> Double? {
      let current = estimated == sample.costEstimated ? amount : nil
      let old = estimated == oldEstimate ? oldAmount : nil
      guard current != nil || old != nil else { return nil }
      return (current ?? 0) - (old ?? 0)
    }
    return (tokens, delta(false), delta(true))
  }

  func export(to url: URL) throws {
    let temporary = url.deletingLastPathComponent().appending(path: ".usagebar-\(UUID().uuidString).sqlite")
    let files = FileManager.default
    defer { try? files.removeItem(at: temporary) }
    try writeCopy(to: temporary)
    if files.fileExists(atPath: url.path) {
      _ = try files.replaceItemAt(url, withItemAt: temporary)
    } else {
      try files.moveItem(at: temporary, to: url)
    }
  }

  private func writeCopy(to url: URL) throws {
    var output: OpaquePointer?
    defer { sqlite3_close(output) }
    guard sqlite3_open_v2(url.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
      let backup = sqlite3_backup_init(output, "main", handle, "main")
    else { throw CatSaveError.storage }
    let result = sqlite3_backup_step(backup, -1)
    let finish = sqlite3_backup_finish(backup)
    guard result == SQLITE_DONE, finish == SQLITE_OK else { throw CatSaveError.storage }
  }

  private func execute(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw CatSaveError.storage }
  }

  private func statement(_ sql: String) throws -> OpaquePointer {
    var result: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &result, nil) == SQLITE_OK, let result else {
      throw CatSaveError.storage
    }
    return result
  }
}

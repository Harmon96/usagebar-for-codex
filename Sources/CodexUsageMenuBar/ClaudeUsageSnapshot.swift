import Foundation

struct ClaudeUsageSnapshot: Codable, Equatable {
  struct Window: Codable, Equatable {
    let usedPercentage: Double
    let resetsAt: TimeInterval

    var remainingPercentage: Int { Int((100 - usedPercentage).rounded(.down)) }
    var resetDate: Date { Date(timeIntervalSince1970: resetsAt) }

    fileprivate var isValid: Bool {
      (0...100).contains(usedPercentage) && resetsAt.isFinite && resetsAt > 0
    }
  }

  private struct StatusLineInput: Decodable {
    struct RateLimits: Decodable {
      let fiveHour: Window?
      let sevenDay: Window?
    }

    let rateLimits: RateLimits?
  }

  let fiveHour: Window?
  let sevenDay: Window?
  let receivedAt: Date

  static func parse(_ data: Data, receivedAt: Date = .now) throws -> Self? {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let limits = try decoder.decode(StatusLineInput.self, from: data).rateLimits
    return Self(
      fiveHour: limits?.fiveHour,
      sevenDay: limits?.sevenDay,
      receivedAt: receivedAt
    ).active(at: receivedAt)
  }

  func active(at date: Date) -> Self? {
    let fiveHour = fiveHour.flatMap { $0.isValid && $0.resetDate > date ? $0 : nil }
    let sevenDay = sevenDay.flatMap { $0.isValid && $0.resetDate > date ? $0 : nil }
    guard fiveHour != nil || sevenDay != nil else { return nil }
    return Self(fiveHour: fiveHour, sevenDay: sevenDay, receivedAt: receivedAt)
  }

  private static var cacheURL: URL {
    URL.applicationSupportDirectory.appending(path: "app.usagebar.menubar/claude-usage.json")
  }

  static func readCache() -> Self? {
    guard let data = try? Data(contentsOf: cacheURL) else { return nil }
    return (try? JSONDecoder().decode(Self.self, from: data))?.active(at: .now)
  }

  static func captureStatusLine() throws {
    guard let data = try FileHandle.standardInput.readToEnd(),
      let snapshot = try parse(data)
    else { return }

    let url = cacheURL
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
  }
}

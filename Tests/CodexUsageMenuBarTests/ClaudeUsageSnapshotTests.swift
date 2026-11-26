import Foundation
import Testing

@testable import CodexUsageMenuBar

struct ClaudeUsageSnapshotTests {
  private let receivedAt = Date(timeIntervalSince1970: 1_000)

  @Test func readsBothWindowsAndDropsEachAtItsReset() throws {
    let input = Data(
      """
      {
        "session_id": "discard-me",
        "rate_limits": {
          "five_hour": {"used_percentage": 23.5, "resets_at": 2000},
          "seven_day": {"used_percentage": 41.2, "resets_at": 3000}
        }
      }
      """.utf8
    )

    let parsed = try ClaudeUsageSnapshot.parse(input, receivedAt: receivedAt)
    let snapshot = try #require(parsed)
    #expect(snapshot.fiveHour?.remainingPercentage == 76)
    #expect(snapshot.sevenDay?.remainingPercentage == 58)
    #expect(snapshot.receivedAt == receivedAt)

    let cached = try JSONEncoder().encode(snapshot)
    let restored = try JSONDecoder().decode(ClaudeUsageSnapshot.self, from: cached)
    #expect(restored == snapshot)
    #expect(!String(decoding: cached, as: UTF8.self).contains("discard-me"))

    let afterFirstReset = try #require(restored.active(at: Date(timeIntervalSince1970: 2_000)))
    #expect(afterFirstReset.fiveHour == nil)
    #expect(afterFirstReset.sevenDay == snapshot.sevenDay)
    #expect(restored.active(at: Date(timeIntervalSince1970: 3_000)) == nil)
  }

  @Test func handlesMissingWindowsAndRejectsOutOfRangeValues() throws {
    let input = Data(
      """
      {"rate_limits":{"five_hour":{"used_percentage":101,"resets_at":2000},
                       "seven_day":{"used_percentage":0,"resets_at":3000}}}
      """.utf8
    )
    let parsed = try ClaudeUsageSnapshot.parse(input, receivedAt: receivedAt)
    let snapshot = try #require(parsed)
    #expect(snapshot.fiveHour == nil)
    #expect(snapshot.sevenDay?.remainingPercentage == 100)

    let missing = try ClaudeUsageSnapshot.parse(Data("{}".utf8), receivedAt: receivedAt)
    #expect(missing == nil)
  }
}

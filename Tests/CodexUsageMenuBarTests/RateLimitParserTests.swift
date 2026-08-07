import Foundation
import Testing

@testable import CodexUsageMenuBar

@Suite("Codex rate-limit parsing")
struct RateLimitParserTests {
  @Test("Matching JSON-RPC responses are parsed while notifications are ignored")
  func parsesMatchingJSONRPCResponsesAndIgnoresNotifications() throws {
    let response = """
      {"id":1,"result":{"userAgent":"codex-cli/0.146.1 (macOS)"}}
      {"method":"account/rateLimits/updated","params":{}}
      {"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":"Codex","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1800018000},"secondary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1800604800},"planType":"pro","rateLimitReachedType":null},"rateLimitsByLimitId":null,"rateLimitResetCredits":{"availableCount":1,"credits":[{"status":"available","expiresAt":1801209600}]}}}
      """

    let parsedResponse = try RateLimitParser.parseAppServerResponse(from: Data(response.utf8))

    #expect(parsedResponse.cliVersion == "0.146.1")
    #expect(parsedResponse.rateLimits.rateLimits.planType == "pro")
    #expect(parsedResponse.rateLimits.rateLimits.secondary?.usedPercent == 42)
    #expect(parsedResponse.rateLimits.rateLimitResetCredits?.availableCount == 1)
  }

  @Test("The exact seven-day window is preferred")
  func selectWeeklyWindowPrefersExactSevenDayWindow() throws {
    let shortWindow = RateLimitWindow(
      usedPercent: 18,
      windowDurationMins: 300,
      resetsAt: 1_800_018_000
    )
    let weeklyWindow = RateLimitWindow(
      usedPercent: 43,
      windowDurationMins: 10_080,
      resetsAt: 1_800_604_800
    )
    let snapshot = RateLimitSnapshot(
      limitId: "codex",
      limitName: "Codex",
      primary: shortWindow,
      secondary: weeklyWindow,
      planType: "pro",
      rateLimitReachedType: nil
    )

    let selectedWindow = try RateLimitParser.selectWeeklyWindow(from: snapshot)

    #expect(selectedWindow.usedPercent == 43)
    #expect(selectedWindow.windowDurationMins == 10_080)
  }

  @Test("The longest available window is used as a compatibility fallback")
  func selectWeeklyWindowFallsBackToLongestAvailableWindow() throws {
    let snapshot = RateLimitSnapshot(
      limitId: "custom",
      limitName: "Custom",
      primary: RateLimitWindow(usedPercent: 10, windowDurationMins: 60, resetsAt: nil),
      secondary: RateLimitWindow(usedPercent: 30, windowDurationMins: 180, resetsAt: nil),
      planType: nil,
      rateLimitReachedType: nil
    )

    let selectedWindow = try RateLimitParser.selectWeeklyWindow(from: snapshot)

    #expect(selectedWindow.windowDurationMins == 180)
  }

  @Test("Pace uses deterministic window progress")
  func paceDescriptionUsesDeterministicWindowProgress() {
    let windowStart = Date(timeIntervalSince1970: 1_800_000_000)
    let windowDuration = TimeInterval(7 * 24 * 60 * 60)
    let weeklyWindow = RateLimitWindow(
      usedPercent: 70,
      windowDurationMins: 10_080,
      resetsAt: Int(windowStart.addingTimeInterval(windowDuration).timeIntervalSince1970)
    )

    let description = UsagePaceCalculator.description(
      for: weeklyWindow,
      now: windowStart.addingTimeInterval(windowDuration / 2)
    )

    #expect(description == "기준보다 빠름 · 사용 70% / 경과 50%")
  }

  @Test("An unrelated JSON-RPC result is rejected")
  func invalidResponseFailsWithoutUsingUnrelatedResult() {
    let response = Data("{\"id\":3,\"result\":{}}\n".utf8)

    #expect(throws: (any Error).self) {
      try RateLimitParser.parseAppServerResponse(from: response)
    }
  }
}

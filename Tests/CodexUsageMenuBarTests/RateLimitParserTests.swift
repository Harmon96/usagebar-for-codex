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
  func selectUsageWindowPrefersExactSevenDayWindow() throws {
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

    let selectedWindow = try RateLimitParser.selectUsageWindow(from: snapshot)

    #expect(selectedWindow.usedPercent == 43)
    #expect(selectedWindow.windowDurationMins == 10_080)
  }

  @Test("The longest available window is used as a compatibility fallback")
  func selectUsageWindowFallsBackToLongestAvailableWindow() throws {
    let snapshot = RateLimitSnapshot(
      limitId: "custom",
      limitName: "Custom",
      primary: RateLimitWindow(usedPercent: 10, windowDurationMins: 60, resetsAt: nil),
      secondary: RateLimitWindow(usedPercent: 30, windowDurationMins: 180, resetsAt: nil),
      planType: nil,
      rateLimitReachedType: nil
    )

    let selectedWindow = try RateLimitParser.selectUsageWindow(from: snapshot)

    #expect(selectedWindow.windowDurationMins == 180)
  }

  @Test("Weekly selection is independent of primary and secondary positions")
  func selectsWeeklyWindowInPrimaryPosition() throws {
    let selected = try RateLimitParser.selectUsageWindow(
      from: snapshot(primary: window(used: 42, minutes: 10_080), secondary: window(used: 90, minutes: 20_160))
    )

    #expect(selected.usedPercent == 42)
    #expect(selected.windowDurationMins == 10_080)
  }

  @Test("A five-hour-only response retains its real duration")
  func selectsSingleShortWindow() throws {
    let selected = try RateLimitParser.selectUsageWindow(
      from: snapshot(primary: window(used: 72, minutes: 300))
    )

    #expect(selected.usedPercent == 72)
    #expect(selected.windowDurationMins == 300)
  }

  @Test("Missing, zero, negative, and absent durations cannot become weekly data")
  func rejectsUnknownOrInvalidDurations() {
    for duration: Int? in [nil, 0, -300] {
      #expect(throws: (any Error).self) {
        try RateLimitParser.selectUsageWindow(
          from: snapshot(primary: window(used: 15, minutes: duration))
        )
      }
    }
    #expect(throws: (any Error).self) {
      try RateLimitParser.selectUsageWindow(from: snapshot())
    }
  }

  @Test("A valid short window is selected over an unknown-duration window")
  func ignoresUnknownDurationWhenValidWindowExists() throws {
    let selected = try RateLimitParser.selectUsageWindow(
      from: snapshot(primary: window(used: 80, minutes: nil), secondary: window(used: 10, minutes: 300))
    )

    #expect(selected.windowDurationMins == 300)
    #expect(selected.usedPercent == 10)
  }

  @Test("Model limits expose the exhausted window even when the other window is unused")
  func modelsUseMostConsumedWindow() throws {
    let response = RateLimitsResponse(
      rateLimits: snapshot(),
      rateLimitsByLimitId: [
        "short": snapshot(primary: window(used: 100, minutes: 300), secondary: window(used: 0, minutes: 10_080)),
        "weekly": snapshot(primary: window(used: 0, minutes: 300), secondary: window(used: 75, minutes: 10_080)),
      ],
      rateLimitResetCredits: nil
    )

    let models = RateLimitParser.modelSpecificLimits(from: response)
    let short = try #require(models.first { $0.id == "short" })
    let weekly = try #require(models.first { $0.id == "weekly" })
    #expect(short.remainingPercentage == 0)
    #expect(short.windowDurationMins == 300)
    #expect(short.resetAt == Date(timeIntervalSince1970: 1_800_000_300))
    #expect(weekly.remainingPercentage == 25)
    #expect(weekly.windowDurationMins == 10_080)
  }

  @Test("Model ties prefer the longer window and single-window limits are supported")
  func modelTiesAndSingleWindows() throws {
    let response = RateLimitsResponse(
      rateLimits: snapshot(),
      rateLimitsByLimitId: [
        "tie": snapshot(primary: window(used: 45, minutes: 10_080), secondary: window(used: 45, minutes: 300)),
        "single": snapshot(secondary: window(used: 20, minutes: 300)),
      ],
      rateLimitResetCredits: nil
    )

    let models = RateLimitParser.modelSpecificLimits(from: response)
    #expect(try #require(models.first { $0.id == "tie" }).windowDurationMins == 10_080)
    #expect(try #require(models.first { $0.id == "single" }).remainingPercentage == 80)
  }

  @Test("Base and unused models stay hidden while a reached limit remains visible")
  func filtersBaseAndUnusedModels() {
    let response = RateLimitsResponse(
      rateLimits: snapshot(id: "base"),
      rateLimitsByLimitId: [
        "codex": snapshot(primary: window(used: 80, minutes: 300)),
        "base": snapshot(primary: window(used: 80, minutes: 300)),
        "unused": snapshot(primary: window(used: 0, minutes: 300)),
        "reached": snapshot(primary: window(used: 0, minutes: 300), reached: "primary"),
      ],
      rateLimitResetCredits: nil
    )

    #expect(RateLimitParser.modelSpecificLimits(from: response).map(\.id) == ["reached"])
  }

  private func window(used: Int, minutes: Int?) -> RateLimitWindow {
    RateLimitWindow(usedPercent: used, windowDurationMins: minutes, resetsAt: 1_800_000_300)
  }

  private func snapshot(
    id: String = "codex",
    primary: RateLimitWindow? = nil,
    secondary: RateLimitWindow? = nil,
    reached: String? = nil
  ) -> RateLimitSnapshot {
    RateLimitSnapshot(
      limitId: id, limitName: nil, primary: primary, secondary: secondary,
      planType: nil, rateLimitReachedType: reached
    )
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

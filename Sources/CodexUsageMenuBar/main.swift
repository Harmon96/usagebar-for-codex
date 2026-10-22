import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

private let menuOpenRefreshThreshold: TimeInterval = 60
private let weeklyWindowDurationMinutes = 7 * 24 * 60
private let appServerRequestTimeout: TimeInterval = 15
private let usageDashboardURL = URL(string: "https://chatgpt.com/codex/settings/usage")!
private let persistedUsageSnapshotKey = "persistedUsageSnapshot"
private let refreshPolicyPreferenceKey = "refreshPolicy"
private let menuBarDisplayModePreferenceKey = "menuBarDisplayMode"

// 연속 실패 횟수에 맞는 재시도 간격을 계산하고 성공 시 초기화
struct RetryBackoffPolicy {
  private static let intervals: [TimeInterval] = [30, 2 * 60, 5 * 60]
  private var attempt = 0

  init() {}

  mutating func nextInterval() -> TimeInterval {
    let intervalIndex = min(attempt, Self.intervals.count - 1)
    attempt = min(attempt + 1, Self.intervals.count - 1)
    return Self.intervals[intervalIndex]
  }

  mutating func reset() {
    attempt = 0
  }
}

// 자동 갱신 간격 설정
enum RefreshPolicy: String, CaseIterable, Identifiable {
  case adaptive
  case oneMinute
  case twoMinutes
  case fiveMinutes
  case fifteenMinutes

  var id: String { rawValue }

  var title: String {
    switch self {
    case .adaptive: return "Adaptive"
    case .oneMinute: return "1분"
    case .twoMinutes: return "2분"
    case .fiveMinutes: return "5분"
    case .fifteenMinutes: return "15분"
    }
  }

  // 최근 사용량 변화 여부에 맞는 다음 갱신 간격 반환
  func interval(usageChanged: Bool) -> TimeInterval {
    switch self {
    case .adaptive: return usageChanged ? 60 : 5 * 60
    case .oneMinute: return 60
    case .twoMinutes: return 2 * 60
    case .fiveMinutes: return 5 * 60
    case .fifteenMinutes: return 15 * 60
    }
  }
}

// 메뉴바에 표시할 정보 밀도 설정
enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
  case full
  case gaugeOnly
  case percentageOnly

  var id: String { rawValue }

  var title: String {
    switch self {
    case .full: return "게이지 + %"
    case .gaugeOnly: return "게이지만"
    case .percentageOnly: return "%만"
    }
  }
}

// Codex 앱 서버 응답의 사용량 창
struct RateLimitWindow: Decodable, Sendable {
  let usedPercent: Int
  let windowDurationMins: Int?
  let resetsAt: Int?
}

// Codex 앱 서버 응답의 사용량 요약
struct RateLimitSnapshot: Decodable, Sendable {
  let limitId: String?
  let limitName: String?
  let primary: RateLimitWindow?
  let secondary: RateLimitWindow?
  let planType: String?
  let rateLimitReachedType: String?
}

// Codex 사용량 전체 리셋 크레딧
struct RateLimitResetCredit: Decodable, Sendable {
  let status: String
  let expiresAt: Int?
}

// 사용 가능한 전체 리셋 크레딧 요약
struct RateLimitResetCredits: Decodable, Sendable {
  let availableCount: Int?
  let credits: [RateLimitResetCredit]?
}

// Codex 앱 서버의 사용량 응답
struct RateLimitsResponse: Decodable, Sendable {
  let rateLimits: RateLimitSnapshot
  let rateLimitsByLimitId: [String: RateLimitSnapshot]?
  let rateLimitResetCredits: RateLimitResetCredits?
}

// Codex 앱 서버 초기화 결과
struct InitializeResult: Decodable {
  let userAgent: String?
}

// JSON-RPC 초기화 응답 래퍼
struct InitializeResponse: Decodable {
  let id: Int?
  let result: InitializeResult?
}

// JSON-RPC 사용량 응답 래퍼
struct RateLimitResponseEnvelope: Decodable {
  let id: Int?
  let result: RateLimitsResponse?
}

// 필요할 때 메뉴에 표시할 모델별 제한
struct ModelSpecificLimit: Codable, Sendable, Identifiable {
  let id: String
  let windowDurationMins: Int?
  let name: String
  let remainingPercentage: Int
  let resetAt: Date?
}

// 앱 재실행 시 복원할 마지막 정상 사용량
struct PersistedUsageSnapshot: Codable {
  let windowDurationMins: Int
  let remainingPercentage: Int
  let lastRefreshedAt: Date
  let resetAt: Date?
  let paceDescription: String
  let planType: String?
  let cliVersion: String?
  let availableResetCredits: Int
  let nearestResetCreditExpiry: Date?
  let modelSpecificLimits: [ModelSpecificLimit]
}

// 메뉴바에 반영할 Codex 사용량 스냅샷
struct CodexUsageSnapshot: Sendable {
  let usageWindow: RateLimitWindow
  let planType: String?
  let cliVersion: String?
  let availableResetCredits: Int
  let nearestResetCreditExpiry: Date?
  let modelSpecificLimits: [ModelSpecificLimit]
}

// 프로세스 I/O와 분리해 테스트할 수 있는 app-server 응답 해석
enum RateLimitParser {
  static func parseAppServerResponse(
    from outputData: Data
  ) throws -> (rateLimits: RateLimitsResponse, cliVersion: String?) {
    let decoder = JSONDecoder()
    var cliVersion: String?
    var rateLimitsResponse: RateLimitsResponse?
    for responseData in outputData.split(separator: 0x0A) {
      if let initializeResponse = try? decoder.decode(InitializeResponse.self, from: responseData),
        initializeResponse.id == 1,
        let userAgent = initializeResponse.result?.userAgent
      {
        cliVersion = parseCLIVersion(from: userAgent)
      }

      if let response = try? decoder.decode(RateLimitResponseEnvelope.self, from: responseData),
        response.id == 2,
        let responseResult = response.result
      {
        rateLimitsResponse = responseResult
      }
    }

    guard let rateLimitsResponse else {
      throw RateLimitFetchError.invalidResponse
    }
    return (rateLimitsResponse, cliVersion)
  }

  // 앱 서버 user agent에서 Codex CLI 버전 추출
  static func parseCLIVersion(from userAgent: String) -> String? {
    guard let firstComponent = userAgent.split(separator: " ").first,
      let version = firstComponent.split(separator: "/").last,
      version.first?.isNumber == true
    else {
      return nil
    }
    return String(version)
  }

  // 주간 창을 우선하고, 없으면 기간이 확인되는 가장 긴 창 선택
  static func selectUsageWindow(from rateLimitSnapshot: RateLimitSnapshot) throws -> RateLimitWindow {
    let availableWindows = [rateLimitSnapshot.primary, rateLimitSnapshot.secondary]
      .compactMap { $0 }
      .filter { ($0.windowDurationMins ?? 0) > 0 }
    if let usageWindow = availableWindows.first(where: { $0.windowDurationMins == weeklyWindowDurationMinutes }) {
      return usageWindow
    }

    if let longestWindow = availableWindows.max(by: { ($0.windowDurationMins ?? 0) < ($1.windowDurationMins ?? 0) }) {
      return longestWindow
    }

    throw RateLimitFetchError.usageWindowNotFound
  }

  // 모델별로 가장 많이 소진된 창을 표시하고, 동률이면 더 긴 창 선택
  static func modelSpecificLimits(from response: RateLimitsResponse) -> [ModelSpecificLimit] {
    response.rateLimitsByLimitId?.compactMap { limitId, snapshot -> ModelSpecificLimit? in
      guard limitId != response.rateLimits.limitId, limitId != "codex",
        let window = [snapshot.primary, snapshot.secondary].compactMap({ $0 }).max(by: {
          if $0.usedPercent == $1.usedPercent {
            return ($0.windowDurationMins ?? 0) < ($1.windowDurationMins ?? 0)
          }
          return $0.usedPercent < $1.usedPercent
        }),
        window.usedPercent > 0 || snapshot.rateLimitReachedType != nil
      else {
        return nil
      }
      return ModelSpecificLimit(
        id: limitId,
        windowDurationMins: window.windowDurationMins,
        name: snapshot.limitName ?? limitId,
        remainingPercentage: max(0, min(100, 100 - window.usedPercent)),
        resetAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
      )
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } ?? []
  }
}

// 선택된 창의 경과율과 실제 사용률을 비교하는 순수 계산 로직
enum UsagePaceCalculator {
  static func description(for usageWindow: RateLimitWindow, now: Date = Date()) -> String {
    guard let resetsAt = usageWindow.resetsAt,
      let windowDurationMins = usageWindow.windowDurationMins
    else {
      return "사용 속도 계산 불가"
    }

    let windowDuration = TimeInterval(windowDurationMins * 60)
    let windowStart = Date(timeIntervalSince1970: TimeInterval(resetsAt)).addingTimeInterval(-windowDuration)
    let elapsedDuration = now.timeIntervalSince(windowStart)
    guard elapsedDuration >= 60 * 60, windowDuration > 0 else {
      return "사용 속도 판단 중"
    }

    let elapsedPercent = max(0, min(100, elapsedDuration / windowDuration * 100))
    let paceDifference = Double(usageWindow.usedPercent) - elapsedPercent
    if paceDifference > 5 {
      return "기준보다 빠름 · 사용 \(usageWindow.usedPercent)% / 경과 \(Int(elapsedPercent.rounded()))%"
    }
    if paceDifference < -5 {
      return "여유 · 사용 \(usageWindow.usedPercent)% / 경과 \(Int(elapsedPercent.rounded()))%"
    }
    return "적정 · 사용 \(usageWindow.usedPercent)% / 경과 \(Int(elapsedPercent.rounded()))%"
  }
}

// 앱 서버 stdout을 스레드 안전하게 수집하고 사용량 응답 도착을 알림
private final class AppServerOutputBuffer: @unchecked Sendable {
  let rateLimitResponseReceived = DispatchSemaphore(value: 0)

  private let lock = NSLock()
  private var outputData = Data()
  private var didSignalResponse = false

  func append(_ responseData: Data) {
    lock.lock()
    outputData.append(responseData)
    let hasRateLimitResponse = containsRateLimitResponse(in: outputData)
    let shouldSignalResponse = hasRateLimitResponse && !didSignalResponse
    if shouldSignalResponse {
      didSignalResponse = true
    }
    lock.unlock()

    if shouldSignalResponse {
      rateLimitResponseReceived.signal()
    }
  }

  // JSON Lines를 구조적으로 해석해 사용량 응답 도착 여부 확인
  private func containsRateLimitResponse(in responseData: Data) -> Bool {
    responseData.split(separator: 0x0A).contains { responseLine in
      guard let responseObject = try? JSONSerialization.jsonObject(with: Data(responseLine)) as? [String: Any],
        let responseId = responseObject["id"] as? NSNumber
      else {
        return false
      }
      return responseId.intValue == 2
    }
  }

  func snapshot() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return outputData
  }
}

// Codex 앱 서버 사용량 조회 오류
enum RateLimitFetchError: LocalizedError, Sendable {
  case codexExecutableNotFound
  case appServerFailed
  case invalidResponse
  case usageWindowNotFound

  var errorDescription: String? {
    switch self {
    case .codexExecutableNotFound:
      return "Codex CLI를 찾을 수 없습니다."
    case .appServerFailed:
      return "Codex 사용량 조회에 실패했습니다."
    case .invalidResponse:
      return "Codex 사용량 응답을 해석할 수 없습니다."
    case .usageWindowNotFound:
      return "기간을 확인할 수 있는 사용량 창을 찾을 수 없습니다."
    }
  }
}

// 설치된 Codex 앱 서버에서 사용량을 조회
private enum CodexRateLimitClient {
  static func fetchUsage() async -> Result<CodexUsageSnapshot, RateLimitFetchError> {
    await Task.detached(priority: .utility) {
      do {
        return .success(try readUsage())
      } catch let fetchError as RateLimitFetchError {
        return .failure(fetchError)
      } catch {
        return .failure(.appServerFailed)
      }
    }.value
  }

  // Codex 앱 서버 JSON-RPC 요청 실행
  private static func readUsage() throws -> CodexUsageSnapshot {
    let appServerProcess = Process()
    appServerProcess.executableURL = try resolveCodexExecutableURL()
    appServerProcess.arguments = ["app-server", "--stdio"]
    appServerProcess.environment = processEnvironment()

    let standardInput = Pipe()
    let standardOutput = Pipe()
    let outputBuffer = AppServerOutputBuffer()
    appServerProcess.standardInput = standardInput
    appServerProcess.standardOutput = standardOutput
    appServerProcess.standardError = FileHandle.nullDevice
    standardOutput.fileHandleForReading.readabilityHandler = { outputHandle in
      let responseData = outputHandle.availableData
      if !responseData.isEmpty {
        outputBuffer.append(responseData)
      }
    }

    try appServerProcess.run()
    standardInput.fileHandleForWriting.write(appServerRequests())
    let responseWaitResult = outputBuffer.rateLimitResponseReceived.wait(
      timeout: .now() + appServerRequestTimeout
    )
    try? standardInput.fileHandleForWriting.close()

    let terminationDeadline = Date().addingTimeInterval(appServerRequestTimeout)
    while appServerProcess.isRunning, Date() < terminationDeadline {
      Thread.sleep(forTimeInterval: 0.05)
    }

    if appServerProcess.isRunning {
      appServerProcess.terminate()
      throw RateLimitFetchError.appServerFailed
    }

    standardOutput.fileHandleForReading.readabilityHandler = nil
    let outputData = outputBuffer.snapshot()
    guard responseWaitResult == .success, appServerProcess.terminationStatus == 0 else {
      throw RateLimitFetchError.appServerFailed
    }

    let parsedResponse = try RateLimitParser.parseAppServerResponse(from: outputData)
    let usageWindow = try RateLimitParser.selectUsageWindow(from: parsedResponse.rateLimits.rateLimits)
    let resetCredits = parsedResponse.rateLimits.rateLimitResetCredits
    let availableCredits =
      resetCredits?.credits?.filter {
        $0.status == "available"
      } ?? []

    return CodexUsageSnapshot(
      usageWindow: usageWindow,
      planType: parsedResponse.rateLimits.rateLimits.planType,
      cliVersion: parsedResponse.cliVersion,
      availableResetCredits: max(availableCredits.count, resetCredits?.availableCount ?? 0),
      nearestResetCreditExpiry:
        availableCredits
        .compactMap { $0.expiresAt }
        .min()
        .map { Date(timeIntervalSince1970: TimeInterval($0)) },
      modelSpecificLimits: RateLimitParser.modelSpecificLimits(from: parsedResponse.rateLimits)
    )
  }

  // Codex 앱 서버 초기화와 사용량 요청 생성
  private static func appServerRequests() -> Data {
    let initializeRequest = """
      {"id":1,"method":"initialize","params":{"clientInfo":{"name":"UsageBar","version":"1.0.0"},"capabilities":null}}
      """
    let initializedNotification = """
      {"method":"initialized"}
      """
    let rateLimitRequest = """
      {"id":2,"method":"account/rateLimits/read","params":null}
      """
    return Data("\(initializeRequest)\n\(initializedNotification)\n\(rateLimitRequest)\n".utf8)
  }

  // 일반 설치 경로와 현재 PATH에서 Codex CLI 확인
  private static func resolveCodexExecutableURL() throws -> URL {
    let fileManager = FileManager.default
    let homeDirectory = fileManager.homeDirectoryForCurrentUser
    let pathCandidateURLs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
      .split(separator: ":")
      .map { URL(fileURLWithPath: String($0), isDirectory: true).appending(path: "codex") }
    let candidateURLs =
      [
        homeDirectory.appending(path: ".hermes/node/bin/codex"),
        homeDirectory.appending(path: ".local/bin/codex"),
        URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        URL(fileURLWithPath: "/usr/local/bin/codex"),
      ] + pathCandidateURLs

    var visitedPaths = Set<String>()
    for candidateURL in candidateURLs {
      let standardizedURL = candidateURL.standardizedFileURL
      guard visitedPaths.insert(standardizedURL.path).inserted else {
        continue
      }
      if fileManager.isExecutableFile(atPath: standardizedURL.path) {
        return standardizedURL
      }
    }

    throw RateLimitFetchError.codexExecutableNotFound
  }

  // Finder 실행 환경에서도 일반적인 Codex 설치 경로를 찾도록 PATH 구성
  private static func processEnvironment() -> [String: String] {
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    var environment = ProcessInfo.processInfo.environment
    let defaultPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let commonBinaryDirectories = [
      "\(homeDirectory)/.hermes/node/bin",
      "\(homeDirectory)/.local/bin",
      "/opt/homebrew/bin",
      "/usr/local/bin",
    ]
    environment["PATH"] = (commonBinaryDirectories + [defaultPath]).joined(separator: ":")
    environment["HOME"] = homeDirectory
    return environment
  }
}

// 선택된 사용량 창의 기간을 숫자와 함께 표시
struct UsageWindowPresentation {
  let durationMinutes: Int?

  var period: String {
    guard let durationMinutes, durationMinutes > 0 else { return "기간 미상" }
    if durationMinutes == weeklyWindowDurationMinutes { return "주간" }
    if durationMinutes.isMultiple(of: 60) { return "\(durationMinutes / 60)시간" }
    return "\(durationMinutes)분"
  }

  var remainingTitle: String {
    guard durationMinutes != nil else { return "사용량 확인 중" }
    return durationMinutes == weeklyWindowDurationMinutes ? "WEEKLY REMAINING" : "\(period) 잔여 사용량"
  }

  var resetTitle: String {
    guard durationMinutes != nil else { return "Reset" }
    return durationMinutes == weeklyWindowDurationMinutes ? "Weekly Reset" : "\(period) 리셋"
  }
}

enum UsageDataStatus {
  case loading
  case unavailable
  case live
  case stale
}

// Codex 잔여율을 메뉴바 상태로 관리
@MainActor
final class UsageStore: ObservableObject {
  @Published private(set) var remainingPercentage: Int?
  @Published private(set) var windowDurationMins: Int?
  @Published private(set) var lastRefreshedAt: Date?
  @Published private(set) var resetAt: Date?
  @Published private(set) var paceDescription = "사용 속도 계산 중"
  @Published private(set) var planType: String?
  @Published private(set) var cliVersion: String?
  @Published private(set) var availableResetCredits = 0
  @Published private(set) var nearestResetCreditExpiry: Date?
  @Published private(set) var modelSpecificLimits: [ModelSpecificLimit] = []
  @Published private(set) var isStale = false
  @Published private(set) var lastErrorMessage: String?
  @Published private(set) var isRefreshing = false
  @Published private(set) var launchAtLoginEnabled = false
  @Published private(set) var launchAtLoginRequiresApproval = false
  @Published var refreshPolicy: RefreshPolicy
  @Published var menuBarDisplayMode: MenuBarDisplayMode

  private let userDefaults: UserDefaults
  private let fetchUsage: @Sendable () async -> Result<CodexUsageSnapshot, RateLimitFetchError>

  var windowPresentation: UsageWindowPresentation {
    UsageWindowPresentation(durationMinutes: windowDurationMins)
  }

  var dataStatus: UsageDataStatus {
    guard remainingPercentage != nil else {
      return isRefreshing || lastErrorMessage == nil ? .loading : .unavailable
    }
    return isStale ? .stale : .live
  }

  private var refreshTimer: Timer?
  private var retryTimer: Timer?
  private var retryBackoffPolicy = RetryBackoffPolicy()

  init(
    userDefaults: UserDefaults = .standard,
    fetchUsage: @escaping @Sendable () async -> Result<CodexUsageSnapshot, RateLimitFetchError> = {
      await CodexRateLimitClient.fetchUsage()
    },
    automaticallyRefresh: Bool = true
  ) {
    self.userDefaults = userDefaults
    self.fetchUsage = fetchUsage
    refreshPolicy =
      RefreshPolicy(
        rawValue: userDefaults.string(forKey: refreshPolicyPreferenceKey) ?? ""
      ) ?? .fiveMinutes
    menuBarDisplayMode =
      MenuBarDisplayMode(
        rawValue: userDefaults.string(forKey: menuBarDisplayModePreferenceKey) ?? ""
      ) ?? .full
    restorePersistedSnapshot()
    if automaticallyRefresh { refreshUsage() }
  }

  // Codex 앱 서버에서 최신 잔여율 조회
  @discardableResult
  func refreshUsage() -> Task<Void, Never>? {
    guard !isRefreshing else {
      return nil
    }

    isRefreshing = true
    let fetchUsage = self.fetchUsage
    return Task { [weak self] in
      let fetchResult = await fetchUsage()
      guard let self else {
        return
      }

      self.isRefreshing = false
      switch fetchResult {
      case .success(let usageSnapshot):
        let usageWindow = usageSnapshot.usageWindow
        let remainingPercentage = max(0, min(100, 100 - usageWindow.usedPercent))
        let usageChanged = self.remainingPercentage != nil && self.remainingPercentage != remainingPercentage
        self.retryTimer?.invalidate()
        self.retryTimer = nil
        self.retryBackoffPolicy.reset()
        self.remainingPercentage = remainingPercentage
        self.windowDurationMins = usageWindow.windowDurationMins
        self.lastRefreshedAt = Date()
        self.resetAt = usageWindow.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        self.paceDescription = UsagePaceCalculator.description(for: usageWindow)
        self.planType = usageSnapshot.planType
        self.cliVersion = usageSnapshot.cliVersion
        self.availableResetCredits = usageSnapshot.availableResetCredits
        self.nearestResetCreditExpiry = usageSnapshot.nearestResetCreditExpiry
        self.modelSpecificLimits = usageSnapshot.modelSpecificLimits
        self.isStale = false
        self.lastErrorMessage = nil
        self.persistCurrentSnapshot()
        self.scheduleNextRefresh(usageChanged: usageChanged)
      case .failure(let error):
        self.isStale = true
        self.lastErrorMessage = error.localizedDescription
        self.scheduleRetry()
      }
    }
  }

  // 메뉴를 열 때 최신성 기준을 넘긴 데이터인지 확인
  var shouldRefreshOnMenuOpen: Bool {
    guard !isRefreshing else {
      return false
    }
    guard let lastRefreshedAt else {
      return true
    }
    return Date().timeIntervalSince(lastRefreshedAt) >= menuOpenRefreshThreshold
  }

  // 잠자기 복귀 시 기존 값을 보존한 채 즉시 재검증
  func refreshAfterWake() {
    isStale = true
    refreshUsage()
  }

  // 사용자가 선택한 자동 갱신 정책 저장 및 적용
  func setRefreshPolicy(_ refreshPolicy: RefreshPolicy) {
    self.refreshPolicy = refreshPolicy
    userDefaults.set(refreshPolicy.rawValue, forKey: refreshPolicyPreferenceKey)
    scheduleNextRefresh(usageChanged: false)
  }

  // 사용자가 선택한 메뉴바 표시 모드 저장
  func setMenuBarDisplayMode(_ menuBarDisplayMode: MenuBarDisplayMode) {
    self.menuBarDisplayMode = menuBarDisplayMode
    userDefaults.set(menuBarDisplayMode.rawValue, forKey: menuBarDisplayModePreferenceKey)
  }

  // 시스템 로그인 항목 상태를 상세 화면에 반영
  func updateLaunchAtLoginState(enabled: Bool, requiresApproval: Bool) {
    launchAtLoginEnabled = enabled
    launchAtLoginRequiresApproval = requiresApproval
  }

  // 성공한 갱신 이후 선택한 정책으로 다음 조회 예약
  private func scheduleNextRefresh(usageChanged: Bool) {
    refreshTimer?.invalidate()
    let nextRefreshInterval = refreshPolicy.interval(usageChanged: usageChanged)
    refreshTimer = Timer.scheduledTimer(withTimeInterval: nextRefreshInterval, repeats: false) { [weak self] _ in
      Task { @MainActor in
        self?.refreshUsage()
      }
    }
  }

  // 일시적인 조회 실패에 단계형 간격으로 재시도 예약
  private func scheduleRetry() {
    guard retryTimer == nil else {
      return
    }
    let retryInterval = retryBackoffPolicy.nextInterval()
    retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: false) { [weak self] _ in
      Task { @MainActor in
        self?.retryTimer = nil
        self?.refreshUsage()
      }
    }
  }

  // 마지막 정상 사용량을 앱 재실행용 캐시에 저장
  private func persistCurrentSnapshot() {
    guard let remainingPercentage, let lastRefreshedAt, let windowDurationMins else {
      return
    }
    let persistedSnapshot = PersistedUsageSnapshot(
      windowDurationMins: windowDurationMins,
      remainingPercentage: remainingPercentage,
      lastRefreshedAt: lastRefreshedAt,
      resetAt: resetAt,
      paceDescription: paceDescription,
      planType: planType,
      cliVersion: cliVersion,
      availableResetCredits: availableResetCredits,
      nearestResetCreditExpiry: nearestResetCreditExpiry,
      modelSpecificLimits: modelSpecificLimits
    )
    guard let snapshotData = try? JSONEncoder().encode(persistedSnapshot) else {
      return
    }
    userDefaults.set(snapshotData, forKey: persistedUsageSnapshotKey)
  }

  // 앱 시작 시 마지막 정상 사용량을 stale 상태로 복원
  private func restorePersistedSnapshot() {
    guard let snapshotData = userDefaults.data(forKey: persistedUsageSnapshotKey),
      let persistedSnapshot = try? JSONDecoder().decode(PersistedUsageSnapshot.self, from: snapshotData),
      persistedSnapshot.windowDurationMins > 0
    else {
      return
    }
    remainingPercentage = persistedSnapshot.remainingPercentage
    windowDurationMins = persistedSnapshot.windowDurationMins
    lastRefreshedAt = persistedSnapshot.lastRefreshedAt
    resetAt = persistedSnapshot.resetAt
    paceDescription = persistedSnapshot.paceDescription
    planType = persistedSnapshot.planType
    cliVersion = persistedSnapshot.cliVersion
    availableResetCredits = persistedSnapshot.availableResetCredits
    nearestResetCreditExpiry = persistedSnapshot.nearestResetCreditExpiry
    modelSpecificLimits = persistedSnapshot.modelSpecificLimits
    isStale = true
  }

}

// 메뉴바 버튼에 표시할 중립적인 사용량 게이지 생성
@MainActor
private enum StatusGaugeImage {
  static func make(remainingPercentage: Int?, isStale: Bool) -> NSImage {
    makeUsageRail(
      remainingPercentage: remainingPercentage,
      isStale: isStale,
      iconColor: .white
    )
  }

  // 앱 마크와 프리즘 글라스 프레임을 결합한 정적 게이지 생성
  private static func makeUsageRail(
    remainingPercentage: Int?,
    isStale: Bool,
    iconColor: NSColor
  ) -> NSImage {
    let imageSize = NSSize(width: 114, height: 18)
    let image = NSImage(size: imageSize, flipped: false) { drawingRect in
      let accentGradientColors = [
        NSColor(calibratedRed: 0.68, green: 0.24, blue: 1, alpha: 1),
        NSColor(calibratedRed: 0.1, green: 0.63, blue: 1, alpha: 1),
      ]
      let coreRect = NSRect(x: 0.5, y: 0.5, width: 17, height: 17)
      let innerCoreRect = coreRect.insetBy(dx: 1.25, dy: 1.25)
      let corePath = NSBezierPath(roundedRect: coreRect, xRadius: 5, yRadius: 5)
      let innerCorePath = NSBezierPath(roundedRect: innerCoreRect, xRadius: 3.75, yRadius: 3.75)
      NSGradient(colors: accentGradientColors.map { $0.withAlphaComponent(0.86) })?.draw(in: corePath, angle: 0)
      NSColor(calibratedWhite: 0.08, alpha: 0.94).setFill()
      innerCorePath.fill()
      NSColor.labelColor.withAlphaComponent(0.5).setStroke()
      corePath.lineWidth = 0.75
      corePath.stroke()

      drawUsageMark(in: NSRect(x: 2.9, y: 2.9, width: 12.2, height: 12.2), color: iconColor)

      let connectorPath = NSBezierPath(ovalIn: NSRect(x: 19.1, y: drawingRect.midY - 1.3, width: 2.6, height: 2.6))
      let connectorColors =
        isStale
        ? [NSColor.systemOrange.withAlphaComponent(0.92), NSColor.systemYellow.withAlphaComponent(0.82)]
        : accentGradientColors.map { $0.withAlphaComponent(0.72) }
      NSGradient(colors: connectorColors)?.draw(in: connectorPath, angle: 0)
      let connectorCorePath = NSBezierPath(
        ovalIn: NSRect(x: 19.85, y: drawingRect.midY - 0.55, width: 1.1, height: 1.1)
      )
      iconColor.withAlphaComponent(0.8).setFill()
      connectorCorePath.fill()

      let outerRect = NSRect(x: 24, y: 1.5, width: 89.5, height: 15)
      let middleRect = outerRect.insetBy(dx: 1.2, dy: 1.2)
      let innerRect = outerRect.insetBy(dx: 3, dy: 3)
      let outerPath = NSBezierPath(roundedRect: outerRect, xRadius: 7.5, yRadius: 7.5)
      let middlePath = NSBezierPath(roundedRect: middleRect, xRadius: 6.3, yRadius: 6.3)
      let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: 4.5, yRadius: 4.5)

      NSGradient(colors: accentGradientColors.map { $0.withAlphaComponent(0.46) })?.draw(in: outerPath, angle: 0)
      NSColor.windowBackgroundColor.withAlphaComponent(0.82).setFill()
      middlePath.fill()
      NSColor.labelColor.withAlphaComponent(0.17).setFill()
      innerPath.fill()

      if let remainingPercentage, remainingPercentage > 0 {
        let fillWidth = innerRect.width * CGFloat(remainingPercentage) / 100
        let fillRect = NSRect(x: innerRect.minX, y: innerRect.minY, width: fillWidth, height: innerRect.height)
        let fillRadius = min(innerRect.height / 2, fillWidth / 2)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: fillRadius, yRadius: fillRadius)
        let gradientColors = gradientColors(for: remainingPercentage)

        NSGraphicsContext.saveGraphicsState()
        innerPath.addClip()
        fillPath.addClip()
        let fillGlow = NSShadow()
        fillGlow.shadowColor = gradientColors.last?.withAlphaComponent(0.78)
        fillGlow.shadowBlurRadius = 5
        fillGlow.shadowOffset = .zero
        fillGlow.set()
        NSGradient(colors: gradientColors)?.draw(
          from: NSPoint(x: innerRect.minX, y: drawingRect.midY),
          to: NSPoint(x: fillRect.maxX, y: drawingRect.midY),
          options: []
        )
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        innerPath.addClip()
        fillPath.addClip()
        NSGradient(
          colors: [
            NSColor.white.withAlphaComponent(0.25),
            NSColor.clear,
            NSColor.black.withAlphaComponent(0.2),
          ]
        )?.draw(
          from: NSPoint(x: drawingRect.midX, y: innerRect.maxY),
          to: NSPoint(x: drawingRect.midX, y: innerRect.minY),
          options: []
        )
        NSGraphicsContext.restoreGraphicsState()

        let sheenEndX = min(fillRect.maxX - 2.5, innerRect.maxX - 3)
        if sheenEndX > innerRect.minX + 4 {
          NSGraphicsContext.saveGraphicsState()
          innerPath.addClip()
          let sheenPath = NSBezierPath()
          sheenPath.move(to: NSPoint(x: innerRect.minX + 4, y: innerRect.maxY - 1.15))
          sheenPath.line(to: NSPoint(x: sheenEndX, y: innerRect.maxY - 1.15))
          sheenPath.lineWidth = 0.7
          NSColor.white.withAlphaComponent(0.62).setStroke()
          sheenPath.stroke()
          NSGraphicsContext.restoreGraphicsState()
        }

        if fillWidth >= 9 {
          let energyHeadX = min(fillRect.maxX - 3.25, innerRect.maxX - 3.25)
          let haloPath = NSBezierPath(ovalIn: NSRect(x: energyHeadX - 3, y: drawingRect.midY - 3, width: 6, height: 6))
          NSColor.white.withAlphaComponent(0.18).setFill()
          haloPath.fill()

          NSGraphicsContext.saveGraphicsState()
          let energyHeadPath = NSBezierPath(
            ovalIn: NSRect(x: energyHeadX - 1.35, y: drawingRect.midY - 1.35, width: 2.7, height: 2.7)
          )
          let energyHeadGlow = NSShadow()
          energyHeadGlow.shadowColor = NSColor.white.withAlphaComponent(0.95)
          energyHeadGlow.shadowBlurRadius = 4
          energyHeadGlow.shadowOffset = .zero
          energyHeadGlow.set()
          NSColor.white.setFill()
          energyHeadPath.fill()
          NSGraphicsContext.restoreGraphicsState()
        }
      }

      NSColor.labelColor.withAlphaComponent(0.42).setStroke()
      outerPath.lineWidth = 0.8
      outerPath.stroke()
      NSColor.white.withAlphaComponent(0.17).setStroke()
      middlePath.lineWidth = 0.55
      middlePath.stroke()

      let upperAccentPath = NSBezierPath()
      upperAccentPath.move(to: NSPoint(x: outerRect.minX + 10, y: outerRect.maxY - 1.15))
      upperAccentPath.line(to: NSPoint(x: outerRect.maxX - 10, y: outerRect.maxY - 1.15))
      upperAccentPath.lineWidth = 0.55
      NSColor.white.withAlphaComponent(0.2).setStroke()
      upperAccentPath.stroke()

      let lowerAccentPath = NSBezierPath()
      lowerAccentPath.move(to: NSPoint(x: outerRect.minX + 8, y: outerRect.minY + 1.15))
      lowerAccentPath.line(to: NSPoint(x: outerRect.maxX - 8, y: outerRect.minY + 1.15))
      lowerAccentPath.lineWidth = 0.5
      NSColor.labelColor.withAlphaComponent(0.16).setStroke()
      lowerAccentPath.stroke()
      return true
    }
    image.isTemplate = false
    return image
  }

  // Apple SF Symbol로 중립적인 사용량 마크 렌더링
  private static func drawUsageMark(in iconRect: NSRect, color: NSColor) {
    let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
    guard
      let symbolImage = NSImage(
        systemSymbolName: "gauge.with.dots.needle.50percent",
        accessibilityDescription: nil
      )?.withSymbolConfiguration(symbolConfiguration)
    else {
      return
    }

    let tintedSymbolImage = NSImage(size: iconRect.size, flipped: false) { drawingRect in
      color.setFill()
      drawingRect.fill()
      symbolImage.draw(in: drawingRect, from: .zero, operation: .destinationIn, fraction: 1)
      return true
    }
    tintedSymbolImage.draw(in: iconRect)
  }

  // 잔여율에 맞는 게이지 그라데이션 반환
  private static func gradientColors(for remainingPercentage: Int) -> [NSColor] {
    if remainingPercentage <= 20 {
      return [.systemOrange, .systemRed]
    }

    return [
      NSColor(calibratedRed: 0.68, green: 0.24, blue: 1, alpha: 1),
      NSColor(calibratedRed: 0.2, green: 0.43, blue: 1, alpha: 1),
      NSColor(calibratedRed: 0.03, green: 0.78, blue: 1, alpha: 1),
      NSColor(calibratedRed: 0.18, green: 1, blue: 0.68, alpha: 1),
    ]
  }
}

// 선택된 기간의 잔여율을 정적인 프리즘 바 형태로 표시
private struct UsageGauge: View {
  let remainingPercentage: Int?
  let period: String

  private var gaugeColors: [Color] {
    if let remainingPercentage, remainingPercentage <= 20 {
      return [.orange, .red]
    }
    return [
      Color(red: 0.68, green: 0.24, blue: 1),
      Color(red: 0.20, green: 0.43, blue: 1),
      Color(red: 0.03, green: 0.78, blue: 1),
      Color(red: 0.18, green: 1, blue: 0.68),
    ]
  }

  var body: some View {
    GeometryReader { geometry in
      let normalizedPercentage = CGFloat(max(0, min(100, remainingPercentage ?? 0))) / 100
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.primary.opacity(0.08))
          .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))

        Capsule()
          .fill(LinearGradient(colors: gaugeColors, startPoint: .leading, endPoint: .trailing))
          .frame(width: max(0, geometry.size.width * normalizedPercentage))
          .shadow(color: (gaugeColors.last ?? .clear).opacity(0.5), radius: 7)
          .overlay(alignment: .top) {
            Capsule()
              .fill(Color.white.opacity(0.28))
              .frame(height: 1)
              .padding(.horizontal, 5)
              .padding(.top, 2)
          }
          .clipShape(Capsule())
      }
    }
    .frame(height: 12)
    .accessibilityLabel("\(period) 잔여율")
    .accessibilityValue(remainingPercentage.map { "\($0)%" } ?? "확인 중")
  }
}

// reset과 pace 정보를 동일한 시각 위계의 카드로 표시
private struct UsageMetricCard: View {
  let title: String
  let value: String
  let symbolName: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Label(title.uppercased(), systemImage: symbolName)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.primary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
    .padding(11)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(tint.opacity(0.08))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(tint.opacity(0.18), lineWidth: 1)
        )
    )
  }
}

// Codex 사용량과 설정을 보여주는 compact popover
@MainActor
private struct UsagePopoverView: View {
  @ObservedObject var usageStore: UsageStore
  let onToggleLaunchAtLogin: () -> Void
  let onOpenDashboard: () -> Void
  let onQuit: () -> Void

  private var planDescription: String {
    guard let planType = usageStore.planType, !planType.isEmpty else {
      return "확인 중"
    }
    return planType.prefix(1).uppercased() + planType.dropFirst()
  }

  private var paceTint: Color {
    if usageStore.paceDescription.hasPrefix("기준보다 빠름") {
      return .orange
    }
    if usageStore.paceDescription.hasPrefix("여유") {
      return .mint
    }
    return .blue
  }

  var body: some View {
    VStack(spacing: 13) {
      header
      usageCard

      HStack(alignment: .top, spacing: 9) {
        UsageMetricCard(
          title: usageStore.windowPresentation.resetTitle,
          value: usageStore.resetAt.map(formatDate) ?? "확인 중",
          symbolName: "calendar.badge.clock",
          tint: .purple
        )
        UsageMetricCard(
          title: "Pace",
          value: usageStore.paceDescription,
          symbolName: "gauge.with.dots.needle.50percent",
          tint: paceTint
        )
      }

      if usageStore.availableResetCredits > 0 || !usageStore.modelSpecificLimits.isEmpty {
        supplementalUsage
      }

      statusFooter
      Divider().opacity(0.55)
      settings
      actions
    }
    .padding(16)
    .frame(width: 344)
    .background(.ultraThinMaterial)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "gauge.with.dots.needle.50percent")
        .font(.system(size: 19, weight: .semibold))
        .frame(width: 21, height: 21)
        .foregroundStyle(.primary)
      VStack(alignment: .leading, spacing: 1) {
        Text("USAGEBAR")
          .font(.system(size: 13, weight: .bold, design: .rounded))
          .tracking(1.3)
        Text("Unofficial Codex usage monitor")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(planDescription.uppercased())
        .font(.system(size: 9, weight: .bold, design: .rounded))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.purple.opacity(0.14)))
        .overlay(Capsule().stroke(Color.purple.opacity(0.3), lineWidth: 1))
    }
  }

  private var usageCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(usageStore.windowPresentation.remainingTitle)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
          HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(usageStore.remainingPercentage.map(String.init) ?? "—")
              .font(.system(size: 38, weight: .bold, design: .rounded))
            Text("%")
              .font(.system(size: 17, weight: .bold, design: .rounded))
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        staleBadge
      }
      UsageGauge(remainingPercentage: usageStore.remainingPercentage, period: usageStore.windowPresentation.period)
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 15, style: .continuous)
        .fill(Color.primary.opacity(0.045))
        .overlay(
          RoundedRectangle(cornerRadius: 15, style: .continuous)
            .stroke(
              LinearGradient(
                colors: [Color.purple.opacity(0.38), Color.cyan.opacity(0.22), Color.mint.opacity(0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              ),
              lineWidth: 1
            )
        )
    )
  }

  @ViewBuilder
  private var staleBadge: some View {
    switch usageStore.dataStatus {
    case .loading:
      Label("확인 중", systemImage: "clock")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
    case .unavailable:
      Label("조회 실패", systemImage: "exclamationmark.circle.fill")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.orange)
    case .stale:
      Label("STALE", systemImage: "exclamationmark.circle.fill")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.orange)
    case .live:
      Label("LIVE", systemImage: "checkmark.circle.fill")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.mint)
    }
  }

  private var supplementalUsage: some View {
    VStack(alignment: .leading, spacing: 8) {
      if usageStore.availableResetCredits > 0 {
        HStack {
          Label("무료 전체 리셋", systemImage: "arrow.counterclockwise.circle.fill")
          Spacer()
          Text("\(usageStore.availableResetCredits)회")
            .fontWeight(.bold)
        }
        .font(.system(size: 11, weight: .medium))
        if let expiry = usageStore.nearestResetCreditExpiry {
          Text("가장 가까운 만료 · \(formatDate(expiry))")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
      }

      ForEach(usageStore.modelSpecificLimits) { modelLimit in
        HStack {
          Text("\(modelLimit.name) · \(UsageWindowPresentation(durationMinutes: modelLimit.windowDurationMins).period)")
          Spacer()
          Text("\(modelLimit.remainingPercentage)%")
            .fontWeight(.bold)
        }
        .font(.system(size: 11, weight: .medium))
      }
    }
    .padding(11)
    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
  }

  private var statusFooter: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Label(lastRefreshDescription(), systemImage: "clock")
        Spacer()
        if let cliVersion = usageStore.cliVersion {
          Text("CLI \(cliVersion)")
        }
      }
      if let lastErrorMessage = usageStore.lastErrorMessage {
        Text(lastErrorMessage)
          .foregroundStyle(.orange)
          .lineLimit(2)
      }
    }
    .font(.system(size: 10, weight: .medium))
    .foregroundStyle(.secondary)
  }

  private var settings: some View {
    VStack(spacing: 9) {
      HStack {
        Label("자동 갱신", systemImage: "arrow.triangle.2.circlepath")
        Spacer()
        Picker("", selection: refreshPolicyBinding) {
          ForEach(RefreshPolicy.allCases) { refreshPolicy in
            Text(refreshPolicy.title).tag(refreshPolicy)
          }
        }
        .labelsHidden()
        .frame(width: 104)
      }

      HStack {
        Label("메뉴바 표시", systemImage: "menubar.rectangle")
        Spacer()
        Picker("", selection: displayModeBinding) {
          ForEach(MenuBarDisplayMode.allCases) { displayMode in
            Text(displayMode.title).tag(displayMode)
          }
        }
        .labelsHidden()
        .frame(width: 104)
      }

      Button(action: onToggleLaunchAtLogin) {
        HStack {
          Label("로그인 시 자동 실행", systemImage: "power")
          Spacer()
          Image(systemName: usageStore.launchAtLoginEnabled ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(usageStore.launchAtLoginEnabled ? Color.mint : Color.secondary)
        }
      }
      .buttonStyle(.plain)

      if usageStore.launchAtLoginRequiresApproval {
        Text("macOS 시스템 설정에서 로그인 항목 승인이 필요합니다.")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .font(.system(size: 11, weight: .medium))
  }

  private var actions: some View {
    HStack(spacing: 8) {
      Button(usageStore.isRefreshing ? "갱신 중" : "새로고침") {
        usageStore.refreshUsage()
      }
      .disabled(usageStore.isRefreshing)
      Button("Usage 열기", action: onOpenDashboard)
      Spacer()
      Button("종료", action: onQuit)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  private var refreshPolicyBinding: Binding<RefreshPolicy> {
    Binding(
      get: { usageStore.refreshPolicy },
      set: { usageStore.setRefreshPolicy($0) }
    )
  }

  private var displayModeBinding: Binding<MenuBarDisplayMode> {
    Binding(
      get: { usageStore.menuBarDisplayMode },
      set: { usageStore.setMenuBarDisplayMode($0) }
    )
  }

  // 날짜를 현재 시간대의 명확한 시각으로 표시
  private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy.MM.dd (E) HH:mm"
    return formatter.string(from: date)
  }

  // 마지막 정상 갱신 시각 문구 생성
  private func lastRefreshDescription() -> String {
    guard let lastRefreshedAt = usageStore.lastRefreshedAt else {
      return "마지막 갱신 확인 중"
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ko_KR")
    formatter.timeZone = .current
    formatter.dateFormat = "MM.dd HH:mm:ss"
    return "마지막 갱신 \(formatter.string(from: lastRefreshedAt))"
  }

}

// 앱 실행과 메뉴바 상태 항목을 관리
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let usageStore = UsageStore()
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let usagePopover = NSPopover()
  private var gaugeStateCancellable: AnyCancellable?
  private var appearanceObservation: NSKeyValueObservation?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    configureStatusItem()
    configurePopover()
    observeUsageStore()
    configureSystemObservers()
    updateLaunchAtLoginState()
  }

  func applicationWillTerminate(_ notification: Notification) {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    NotificationCenter.default.removeObserver(self)
    appearanceObservation?.invalidate()
  }

  // 게이지와 숫자가 포함된 메뉴바 항목 구성
  private func configureStatusItem() {
    statusItem.autosaveName = "CodexUsageMenuBarStatusItem"
    guard let statusButton = statusItem.button else {
      return
    }

    statusButton.target = self
    statusButton.action = #selector(handleStatusItemClick)
    statusButton.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusButton.imagePosition = .imageLeft
    updateStatusItem(
      remainingPercentage: usageStore.remainingPercentage,
      windowDurationMins: usageStore.windowDurationMins,
      isStale: usageStore.isStale,
      displayMode: usageStore.menuBarDisplayMode
    )
    statusItem.isVisible = true
  }

  // 사용량 상세 화면을 정적인 compact popover로 구성
  private func configurePopover() {
    usagePopover.behavior = .transient
    usagePopover.animates = false
    usagePopover.contentSize = NSSize(width: 344, height: 520)
    usagePopover.contentViewController = NSHostingController(
      rootView: UsagePopoverView(
        usageStore: usageStore,
        onToggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
        onOpenDashboard: { NSWorkspace.shared.open(usageDashboardURL) },
        onQuit: { NSApp.terminate(nil) }
      )
    )
  }

  // 사용량 변경을 메뉴바 게이지에 반영
  private func observeUsageStore() {
    gaugeStateCancellable = Publishers.CombineLatest4(
      usageStore.$remainingPercentage,
      usageStore.$windowDurationMins,
      usageStore.$isStale,
      usageStore.$menuBarDisplayMode
    )
    .receive(on: RunLoop.main)
    .sink { [weak self] remainingPercentage, windowDurationMins, isStale, displayMode in
      self?.updateStatusItem(
        remainingPercentage: remainingPercentage,
        windowDurationMins: windowDurationMins,
        isStale: isStale,
        displayMode: displayMode
      )
    }
  }

  // 게이지 이미지와 오른쪽 잔여율 숫자 갱신
  private func updateStatusItem(
    remainingPercentage: Int?,
    windowDurationMins: Int?,
    isStale: Bool,
    displayMode: MenuBarDisplayMode
  ) {
    guard let statusButton = statusItem.button else {
      return
    }

    let percentageText = remainingPercentage.map { "\($0)%" } ?? "—"
    let staleDescription = isStale && remainingPercentage != nil ? " · 데이터가 오래됨" : ""
    statusButton.effectiveAppearance.performAsCurrentDrawingAppearance {
      switch displayMode {
      case .full:
        statusButton.imagePosition = .imageLeft
        statusButton.image = StatusGaugeImage.make(
          remainingPercentage: remainingPercentage,
          isStale: isStale
        )
        statusButton.attributedTitle = makePercentageTitle(
          remainingPercentage: remainingPercentage,
          foregroundColor: .white
        )
      case .gaugeOnly:
        statusButton.imagePosition = .imageOnly
        statusButton.image = StatusGaugeImage.make(
          remainingPercentage: remainingPercentage,
          isStale: isStale
        )
        statusButton.attributedTitle = NSAttributedString(string: "")
      case .percentageOnly:
        statusButton.imagePosition = .noImage
        statusButton.image = nil
        statusButton.attributedTitle = makePercentageTitle(
          remainingPercentage: remainingPercentage,
          foregroundColor: .white
        )
      }
    }
    let period = windowDurationMins.map { UsageWindowPresentation(durationMinutes: $0).period + " " } ?? ""
    let usageDescription = "Codex \(period)잔여 사용률 \(percentageText)\(staleDescription)"
    statusButton.toolTip = usageDescription
    statusButton.setAccessibilityLabel(usageDescription)
  }

  // 잔여율 숫자와 퍼센트 기호의 위계를 분리한 메뉴바 타이포 생성
  private func makePercentageTitle(
    remainingPercentage: Int?,
    foregroundColor: NSColor
  ) -> NSAttributedString {
    let textShadow = NSShadow()
    textShadow.shadowColor = NSColor.black.withAlphaComponent(0.72)
    textShadow.shadowBlurRadius = 1.5
    textShadow.shadowOffset = .zero

    guard let remainingPercentage else {
      return NSAttributedString(
        string: " —",
        attributes: [
          .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
          .foregroundColor: foregroundColor,
          .shadow: textShadow,
        ]
      )
    }

    let percentageTitle = NSMutableAttributedString(
      string: " \(remainingPercentage)",
      attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
        .foregroundColor: foregroundColor,
        .kern: 0.1,
        .shadow: textShadow,
      ]
    )
    percentageTitle.append(
      NSAttributedString(
        string: "%",
        attributes: [
          .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
          .foregroundColor: foregroundColor.withAlphaComponent(0.92),
          .baselineOffset: 1,
          .shadow: textShadow,
        ]
      )
    )
    return percentageTitle
  }

  // 잠자기·디스플레이·appearance 변경을 받아 상태 항목 갱신
  private func configureSystemObservers() {
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(handleDidWake),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleScreenParametersChanged),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )
    appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
      Task { @MainActor in
        self?.redrawStatusItem()
      }
    }
  }

  // 메뉴바 클릭 시 사용량 상세 popover 표시 전환
  @objc private func handleStatusItemClick() {
    guard let statusButton = statusItem.button else {
      return
    }
    if usagePopover.isShown {
      usagePopover.performClose(nil)
      return
    }
    if usageStore.shouldRefreshOnMenuOpen {
      usageStore.refreshUsage()
    }
    NSApp.activate(ignoringOtherApps: true)
    usagePopover.show(relativeTo: statusButton.bounds, of: statusButton, preferredEdge: .minY)
  }

  // 잠자기 복귀 후 마지막 값을 stale로 표시하고 즉시 갱신
  @objc private func handleDidWake() {
    usageStore.refreshAfterWake()
  }

  // 디스플레이 재구성 후 메뉴바 항목 가시성 복구
  @objc private func handleScreenParametersChanged() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      guard let self else {
        return
      }
      self.statusItem.isVisible = true
      self.redrawStatusItem()
    }
  }

  // 현재 appearance에서 메뉴바 게이지 다시 렌더링
  private func redrawStatusItem() {
    updateStatusItem(
      remainingPercentage: usageStore.remainingPercentage,
      windowDurationMins: usageStore.windowDurationMins,
      isStale: usageStore.isStale,
      displayMode: usageStore.menuBarDisplayMode
    )
  }

  // 시스템 로그인 자동 실행 등록 상태 전환
  private func toggleLaunchAtLogin() {
    do {
      if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      } else {
        try SMAppService.mainApp.register()
      }
    } catch {
      // 시스템 설정에서 승인이 필요한 경우 기존 상태를 유지
    }
    updateLaunchAtLoginState()
  }

  // 시스템 등록 상태와 승인 필요 여부를 상세 화면에 반영
  private func updateLaunchAtLoginState() {
    let launchStatus = SMAppService.mainApp.status
    usageStore.updateLaunchAtLoginState(
      enabled: launchStatus == .enabled,
      requiresApproval: launchStatus == .requiresApproval
    )
  }
}

@main
struct CodexUsageMenuBarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
  }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
  static let catDesktopOpenHome = Notification.Name("UsageBar.catDesktopOpenHome")
}

private enum CatUsagePage: String, CaseIterable {
  case codex = "Codex 한도"
  case activity = "로컬 활동"
}

private enum CatTab: String, CaseIterable {
  case home = "홈"
  case usage = "사용량"
  case collection = "도감"
  case bag = "가방"
  case shop = "상점"
  case settings = "설정"

  var icon: String {
    switch self {
    case .home: "house"
    case .usage: "chart.bar"
    case .collection: "books.vertical"
    case .bag: "bag"
    case .shop: "basket"
    case .settings: "gearshape"
    }
  }
}

@MainActor
struct CatCollectionShell: View {
  @ObservedObject var store: CatCollectionStore
  let usage: AnyView
  let onToggleDesktop: () -> Void
  @State private var tab = CatTab.home
  @State private var usagePage = CatUsagePage.codex

  var body: some View {
    VStack(spacing: 0) {
      header
      navigation
      Divider()
      if tab == .collection {
        CatEncyclopediaView(store: store)
      } else {
        ScrollView {
          if tab == .usage {
            usageContent
          } else {
            content.padding(14)
          }
        }
        .id(tab)
      }
      if let error = store.error {
        Label(error, systemImage: "exclamationmark.circle")
          .font(.footnote)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
          .accessibilityAddTraits(.updatesFrequently)
      }
    }
    .frame(width: 344, height: 610)
    .background(.ultraThinMaterial)
    .onReceive(NotificationCenter.default.publisher(for: .catDesktopOpenHome)) { _ in
      tab = .home
    }
  }

  private var usageContent: some View {
    VStack(spacing: 0) {
      Picker("사용량 보기", selection: $usagePage) {
        ForEach(CatUsagePage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      if usagePage == .codex {
        usage
      } else {
        CatActivityView(days: store.state.daily, providers: store.state.providers, statuses: store.state.statuses)
          .padding(14)
      }
    }
  }

  private var header: some View {
    HStack(spacing: 7) {
      Label("고양이 수집", systemImage: "pawprint.fill")
        .font(.system(size: 15, weight: .semibold, design: .rounded))
      Spacer()
      Label(store.state.coins.formatted(), systemImage: "circle.hexagongrid.fill")
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .foregroundStyle(.secondary)
        .accessibilityLabel("보유 코인")
        .accessibilityValue(store.state.coins.formatted())
      Button {
        store.refresh(force: true)
      } label: {
        Image(systemName: "arrow.clockwise").frame(width: 18, height: 20)
      }
      .buttonStyle(.borderless)
      .disabled(store.scanning)
      .accessibilityLabel("토큰 기록 새로고침")
      .help("토큰 기록 새로고침")
    }
    .padding(14)
  }

  private var navigation: some View {
    HStack(spacing: 0) {
      ForEach(CatTab.allCases, id: \.self) { item in
        Button {
          tab = item
        } label: {
          VStack(spacing: 4) {
            Image(systemName: item.icon)
              .font(.system(size: 13, weight: .medium))
            Text(item.rawValue)
              .font(.system(size: 10, weight: .medium))
          }
          .frame(maxWidth: .infinity, minHeight: 42)
          .contentShape(Rectangle())
          .foregroundStyle(tab == item ? Color.accentColor : Color.secondary)
          .background(alignment: .bottom) {
            if tab == item {
              Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 12)
            }
          }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == item ? [.isSelected] : [])
      }
    }
    .padding(.horizontal, 8)
  }

  @ViewBuilder
  private var content: some View {
    switch tab {
    case .home: CatHomeView(store: store, onOpenCollection: { tab = .collection })
    case .usage, .collection: EmptyView()
    case .bag: CatBagView(store: store, onOpenShop: { tab = .shop })
    case .shop: CatShopView(store: store)
    case .settings: CatSettingsView(store: store, onToggleDesktop: onToggleDesktop)
    }
  }
}

private struct CatCard<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.075)))
  }
}

@MainActor
struct CatSpriteView: View {
  var kind: CatKind?
  var coat: Int = 0
  var adult = false
  var shiny = false
  var frameIndex = 0
  var size: CGFloat

  var body: some View {
    Image(nsImage: CatArt.image(kind: kind, coat: coat, adult: adult, shiny: shiny, frame: frameIndex, size: size))
      .interpolation(.none)
      .resizable()
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

@MainActor
private struct CatHomeView: View {
  @ObservedObject var store: CatCollectionStore
  let onOpenCollection: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var active: CatPet? { store.state.pets.first { $0.id == store.state.activeID } }

  private var title: String {
    switch store.state.phase {
    case .box: "새 고양이 발견까지"
    case .kitten: "성묘로 성장까지"
    case .adult: "정착까지"
    }
  }

  private var progress: Double {
    min(1, Double(store.state.progress) / Double(max(1, store.state.target)))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      CatCard {
        scene
        HStack(alignment: .firstTextBaseline) {
          Text(active?.name ?? "새 고양이")
            .font(.system(size: 19, weight: .semibold, design: .rounded))
          Spacer()
          if let active {
            Text(CatCatalog.kind(active.kindID)?.name ?? "").font(.caption).foregroundStyle(.secondary)
          }
        }
        ProgressView(value: progress)
          .tint(.teal)
          .accessibilityLabel(title)
        HStack {
          Text(title)
          Spacer()
          Text("\(store.state.progress.formatted()) / \(store.state.target.formatted())")
            .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      if store.scanning {
        ViewThatFits(in: .horizontal) {
          Label("로컬 사용 기록을 읽는 중", systemImage: "clock.arrow.circlepath")
          Text("기록을 읽는 중")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      CatCard {
        HStack {
          Label("도감", systemImage: "books.vertical")
            .font(.system(.subheadline, weight: .semibold))
          Spacer()
          Button("도감 열기", action: onOpenCollection).buttonStyle(.borderless)
        }
        Text("\(Set(store.state.pets.map(\.kindID)).count.formatted()) / \(CatCatalog.all.count.formatted())종 발견")
          .font(.caption)
          .foregroundStyle(.secondary)
        if let recent = store.state.pets.filter({ $0.settledAt != nil }).last,
          let date = recent.settledAt
        {
          Text("\(recent.name) 정착 · \(date.formatted(date: .abbreviated, time: .omitted))")
            .font(.caption)
        }
      }
    }
  }

  private var scene: some View {
    ZStack(alignment: .bottom) {
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.teal.opacity(0.115).gradient)
      Rectangle()
        .fill(Color.teal.opacity(0.13))
        .frame(height: 24)
      if reduceMotion {
        sprite(frame: 0)
      } else {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          sprite(frame: Int(context.date.timeIntervalSince1970) % 4)
        }
      }
    }
    .frame(height: 142)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .accessibilityHidden(true)
  }

  private func sprite(frame: Int) -> some View {
    CatSpriteView(
      kind: active.flatMap { CatCatalog.kind($0.kindID) },
      coat: active?.coat ?? 0,
      adult: store.state.phase == .adult,
      shiny: active?.shiny ?? false,
      frameIndex: frame,
      size: 128
    )
    .padding(.bottom, 4)
  }
}

@MainActor
private struct CatEncyclopediaView: View {
  @ObservedObject var store: CatCollectionStore
  @State private var query = ""
  @State private var group: String? = nil
  @State private var rarity: CatRarity? = nil
  @State private var coat: String? = nil
  @State private var selected: CatKind?
  @State private var gridScrollID: String?

  private var pets: [String: [CatPet]] { Dictionary(grouping: store.state.pets, by: \.kindID) }

  private var filtersActive: Bool { group != nil || rarity != nil || coat != nil || !query.isEmpty }

  private var results: [CatKind] {
    let keywords = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return CatCatalog.all.filter { kind in
      (group == nil || kind.group == group)
        && (rarity == nil || kind.rarity == rarity)
        && (coat == nil || kind.coats.contains(coat ?? ""))
        && (keywords.isEmpty
          || kind.name.localizedStandardContains(keywords)
          || kind.englishName.localizedStandardContains(keywords)
          || (pets[kind.id] ?? []).contains { $0.name.localizedStandardContains(keywords) })
    }
  }

  var body: some View {
    if let selected {
      ScrollView {
        details(selected).padding(14)
      }
    } else {
      ScrollView {
        grid.padding(14)
      }
      .scrollPosition(id: $gridScrollID)
    }
  }

  private var grid: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !filtersActive {
        completion
      }
      TextField("품종 또는 이름 검색", text: $query)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("품종 또는 이름 검색")
      filters
      if results.isEmpty {
        Text("검색 조건에 맞는 고양이가 없습니다.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
          ForEach(results) { kind in tile(kind).id(kind.id) }
        }
        .scrollTargetLayout()
      }
    }
  }

  private var completion: some View {
    CatCard {
      ForEach(CatCatalog.groups, id: \.self) { collection in
        let kinds = CatCatalog.all.filter { $0.group == collection }
        let count = kinds.filter { pets[$0.id] != nil }.count
        HStack {
          Text(collection)
          Spacer()
          if count > 0, count == kinds.count {
            Label("완성", systemImage: "checkmark.seal.fill")
              .foregroundStyle(.teal)
          }
          Text("\(count) / \(kinds.count)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
      }
    }
  }

  private var filters: some View {
    HStack(spacing: 6) {
      Picker("종류", selection: $group) {
        Text("모든 종류").tag(nil as String?)
        ForEach(CatCatalog.groups, id: \.self) { Text($0).tag(Optional($0)) }
      }
      Picker("등급", selection: $rarity) {
        Text("모든 등급").tag(nil as CatRarity?)
        ForEach(CatRarity.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
      }
      Picker("무늬", selection: $coat) {
        Text("모든 무늬").tag(nil as String?)
        ForEach(Set(CatCatalog.all.flatMap(\.coats)).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
      }
    }
    .controlSize(.small)
    .labelsHidden()
  }

  private func tile(_ kind: CatKind) -> some View {
    let selectedCoat = coat.flatMap { kind.coats.firstIndex(of: $0) }
    let shownPets = (pets[kind.id] ?? []).filter { pet in
      selectedCoat.map { pet.coat == $0 } ?? true
    }
    let pet = shownPets.first
    return Button {
      selected = kind
    } label: {
      VStack(spacing: 4) {
        CatSpriteView(
          kind: kind, coat: pet?.coat ?? selectedCoat ?? 0, adult: true, shiny: pet?.shiny ?? false, size: 46
        )
        .opacity(pet == nil ? 0.28 : 1)
        Text(kind.name)
          .font(.system(size: 10, weight: .medium))
          .lineLimit(2, reservesSpace: true)
          .multilineTextAlignment(.center)
        Text(shownPets.isEmpty ? "미발견" : "\(shownPets.count)마리")
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
      .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
  }

  private func details(_ kind: CatKind) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        selected = nil
      } label: {
        Label("도감", systemImage: "chevron.left")
      }
      .buttonStyle(.borderless)
      CatCard {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text(kind.name).font(.headline)
            Text(kind.rarity.title + " · " + kind.group).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          CatSpriteView(kind: kind, adult: true, size: 60)
        }
        Text("모습 \(Set((pets[kind.id] ?? []).map(\.coat)).count) / \(kind.coats.count)")
          .font(.caption)
          .foregroundStyle(.secondary)
        if pets[kind.id] == nil {
          Text("아직 만나지 못한 고양이입니다.").font(.caption)
        }
      }
      ForEach(pets[kind.id] ?? []) { pet in
        CatIndividualView(store: store, pet: pet, kind: kind)
      }
    }
  }
}

@MainActor
private struct CatIndividualView: View {
  @ObservedObject var store: CatCollectionStore
  let pet: CatPet
  let kind: CatKind
  @State private var editedName: String?

  var body: some View {
    CatCard {
      HStack {
        CatSpriteView(
          kind: kind, coat: pet.coat,
          adult: pet.isAdult || (store.state.activeID == pet.id && store.state.phase == .adult),
          shiny: pet.shiny, size: 52
        )
        VStack(alignment: .leading, spacing: 4) {
          if let editedName {
            TextField(
              "고양이 이름",
              text: Binding(
                get: { self.editedName ?? editedName }, set: { self.editedName = $0 }
              )
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit(saveName)
          } else {
            Text(pet.name).font(.subheadline.bold())
          }
          Text([coatName, pet.personality, pet.shiny ? "반짝" : nil].compactMap { $0 }.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          if editedName == nil { editedName = pet.name } else { saveName() }
        } label: {
          Image(systemName: editedName == nil ? "pencil" : "checkmark")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(editedName == nil ? "이름 편집" : "이름 저장")
      }
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("발견 \(pet.discoveredAt.formatted(date: .abbreviated, time: .omitted))")
          if let date = pet.settledAt {
            Text("정착 \(date.formatted(date: .abbreviated, time: .omitted))")
          }
        }
        .foregroundStyle(.secondary)
        Spacer()
        Button(store.state.pinnedID == pet.id ? "대표 해제" : "대표로 선택") {
          store.pin(store.state.pinnedID == pet.id ? nil : pet.id)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      .font(.caption)
    }
  }

  private var coatName: String? { kind.coats.indices.contains(pet.coat) ? kind.coats[pet.coat] : nil }

  private func saveName() {
    guard let name = editedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
    store.rename(pet.id, to: name)
    editedName = nil
  }
}

extension CatItem {
  fileprivate var detail: String {
    switch self {
    case .treat: "성장에 500,000 토큰을 더합니다."
    case .toy: "돌보는 고양이의 성격을 다시 뽑습니다."
    case .charm: "반짝이는 외형의 등장 확률을 3%로 올립니다."
    case .normalBox: "일반 등급 이상인 고양이를 만납니다."
    case .uncommonBox: "고급 등급 이상인 고양이를 만납니다."
    case .rareBox: "희귀 등급 이상인 고양이를 만납니다."
    }
  }

  fileprivate var symbol: String {
    switch self {
    case .treat: "fish"
    case .toy: "tennisball"
    case .charm: "sparkles"
    case .normalBox, .uncommonBox, .rareBox: "shippingbox"
    }
  }

  fileprivate var isBox: Bool { self == .normalBox || self == .uncommonBox || self == .rareBox }
}

@MainActor
private struct CatShopView: View {
  @ObservedObject var store: CatCollectionStore
  @State private var amount = 1

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("100만 토큰당 1코인").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Stepper("수량 \(amount)", value: $amount, in: 1...99)
          .fixedSize()
          .controlSize(.small)
      }
      ForEach(CatItem.allCases) { item in
        let count = item == .charm ? 1 : amount
        let price = item.price(percent: store.state.prices) * Int64(count)
        CatCard {
          Label(item.title, systemImage: item.symbol).font(.subheadline.bold())
          Text(item.detail).font(.caption).foregroundStyle(.secondary)
          HStack {
            Text("\(price.formatted())코인")
              .font(.system(.caption, design: .monospaced))
            Spacer()
            if item == .charm, store.state.shinyCharm || (store.state.inventory[item.rawValue] ?? 0) > 0 {
              Text("보유 중").font(.caption).foregroundStyle(.secondary)
            } else {
              Button(count == 1 ? "구매" : "\(count)개 구매") { store.buy(item, count: count) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.state.coins < price)
            }
          }
        }
      }
    }
  }
}

@MainActor
private struct CatBagView: View {
  @ObservedObject var store: CatCollectionStore
  let onOpenShop: () -> Void
  @State private var amount = 1
  @State private var replacingBox: CatItem?

  private var items: [CatItem] { CatItem.allCases.filter { store.state.inventory[$0.rawValue, default: 0] > 0 } }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if items.isEmpty {
        CatCard {
          Text("가방이 비어 있습니다.").font(.subheadline)
          Button("상점 열기", action: onOpenShop).buttonStyle(.bordered)
        }
      }
      ForEach(items) { item in
        CatCard {
          HStack {
            Label(item.title, systemImage: item.symbol).font(.subheadline.bold())
            Spacer()
            Text("\(store.state.inventory[item.rawValue, default: 0])개")
              .font(.caption)
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          if item == .treat {
            treats
          } else {
            Text(item.detail).font(.caption).foregroundStyle(.secondary)
            if replacingBox == item {
              Text("현재 성장은 종료됩니다. 만난 고양이는 도감에 남습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
              HStack {
                Button("취소") { replacingBox = nil }
                Spacer()
                Button("상자 바꾸기") {
                  store.use(item, count: 1)
                  replacingBox = nil
                }
                .buttonStyle(.borderedProminent)
              }
              .controlSize(.small)
            } else {
              Button("사용") {
                if item.isBox {
                  replacingBox = item
                } else {
                  store.use(item, count: 1)
                }
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .disabled(item == .toy && store.state.activeID == nil)
            }
          }
        }
      }
    }
  }

  private var limit: Int {
    guard store.state.phase != .box else { return 0 }
    let adult = store.state.phase == .kitten ? store.state.target(for: .adult) : 0
    let total = max(0, store.state.target - store.state.progress + adult)
    return min(store.state.inventory[CatItem.treat.rawValue, default: 0], Int((total + 499_999) / 500_000))
  }

  @ViewBuilder
  private var treats: some View {
    if limit == 0 {
      Text("고양이를 만난 뒤 간식을 줄 수 있습니다.").font(.caption).foregroundStyle(.secondary)
    } else {
      let count = min(amount, limit)
      Stepper("수량 \(count)", value: Binding(get: { count }, set: { amount = $0 }), in: 1...limit)
        .controlSize(.small)
      Text(preview(count: count)).font(.caption).foregroundStyle(.secondary)
      Button("\(count)개 먹이기") { store.use(.treat, count: count) }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }
  }

  private func preview(count: Int) -> String {
    let progress = store.state.progress + Int64(count) * 500_000
    let target = store.state.target
    guard progress >= target else { return "사용 후 \(progress.formatted()) / \(target.formatted())" }
    let adult = store.state.target(for: .adult)
    if store.state.phase == .kitten, progress - target < adult {
      return "성묘로 성장 · \((progress - target).formatted()) / \(adult.formatted())"
    }
    return "정착하고 새 상자가 시작됩니다."
  }
}

@MainActor
private struct CatSettingsView: View {
  @ObservedObject var store: CatCollectionStore
  let onToggleDesktop: () -> Void
  @State private var selectedProvider: CatProvider?
  @State private var confirmRestore = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      CatCard {
        Text("고양이").font(.subheadline.bold())
        Picker("메뉴바 표시", selection: Binding(get: { store.state.display }, set: { store.setDisplay($0) })) {
          Text("기존 표시").tag(CatDisplay.original)
          Text("고양이와 잔여율").tag(CatDisplay.catAndPercentage)
          Text("고양이만").tag(CatDisplay.catOnly)
        }
        Picker("성장 속도", selection: Binding(get: { store.state.difficulty }, set: { store.setDifficulty($0) })) {
          Text("빠르게").tag(50)
          Text("보통").tag(100)
          Text("느리게").tag(200)
        }
        Picker("상점 가격", selection: Binding(get: { store.state.prices }, set: { store.setPrices($0) })) {
          ForEach([50, 100, 200], id: \.self) { Text("\($0)%").tag($0) }
        }
        Button("바탕화면 고양이 표시 전환", action: onToggleDesktop)
          .buttonStyle(.bordered)
        Button("수집 끄기") { store.setEnabled(false) }
          .buttonStyle(.bordered)
      }
      CatCard {
        Text("추적할 도구").font(.subheadline.bold())
        ForEach(CatProvider.allCases) { provider in
          VStack(alignment: .leading, spacing: 4) {
            Toggle(
              provider.title,
              isOn: Binding(
                get: { store.state.providers.contains(provider) },
                set: { store.setProvider(provider, $0) }
              ))
            if let status = store.state.statuses[provider.rawValue], store.state.providers.contains(provider) {
              Text(status).font(.caption2).foregroundStyle(.secondary)
            }
          }
        }
        Divider()
        Picker("추가 폴더", selection: $selectedProvider) {
          Text("도구 선택").tag(nil as CatProvider?)
          ForEach(CatProvider.allCases) { Text($0.title).tag(Optional($0)) }
        }
        if let provider = selectedProvider {
          ForEach(store.state.roots[provider.rawValue] ?? [], id: \.self) { path in
            HStack {
              Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .help(path)
              Spacer()
              Button {
                store.removeRoot(path, for: provider)
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.borderless)
              .accessibilityLabel("폴더 제외")
            }
          }
          Button("폴더 추가") { chooseFolder(provider) }.buttonStyle(.bordered)
        }
      }
      CatCard {
        Text("수집 저장").font(.subheadline.bold())
        HStack {
          Button("지금 백업") { store.backup() }
          Button("내보내기") { exportSave() }
          Button("복원") { confirmRestore = true }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        if confirmRestore {
          Text("선택한 백업 시점의 수집 기록으로 돌아갑니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
          HStack {
            Button("취소") { confirmRestore = false }
            Spacer()
            Button("백업 파일 선택") { restoreSave() }
              .buttonStyle(.borderedProminent)
          }
          .controlSize(.small)
        }
      }
    }
    .controlSize(.small)
  }

  private func chooseFolder(_ provider: CatProvider) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.begin { result in
      if result == .OK, let url = panel.url { store.addRoot(url, for: provider) }
    }
  }

  private func exportSave() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
    panel.nameFieldStringValue = "UsageBar-Cats.sqlite"
    panel.begin { result in
      if result == .OK, let url = panel.url { store.export(to: url) }
    }
  }

  private func restoreSave() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
    panel.begin { result in
      if result == .OK, let url = panel.url {
        store.restore(from: url)
        confirmRestore = false
      }
    }
  }
}

private enum CatActivityPeriod: String, CaseIterable {
  case week = "주"
  case month = "월"
  case year = "연"

  var component: Calendar.Component {
    switch self {
    case .week: .weekOfYear
    case .month: .month
    case .year: .year
    }
  }
}

@MainActor
private struct CatActivityView: View {
  let days: [CatUsageDay]
  let providers: Set<CatProvider>
  let statuses: [String: String]
  @State private var period = CatActivityPeriod.week

  private let calendar = Calendar.current
  private let now = Date.now

  private var today: [CatUsageDay] { days.filter { calendar.isDate($0.date, inSameDayAs: now) } }
  private var dailyTotals: [Date: Int64] {
    Dictionary(grouping: days, by: { calendar.startOfDay(for: $0.date) }).mapValues { values in
      values.reduce(0) { $0 + $1.tokens }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      todayCard
      activityCard
      recapCard
    }
  }

  private var todayCard: some View {
    let rowsByProvider = Dictionary(grouping: today, by: \.provider)
    let visibleProviders = providers.union(rowsByProvider.keys)
    return CatCard {
      HStack {
        Text("오늘의 토큰").font(.subheadline.bold())
        Spacer()
        Text(today.reduce(0) { $0 + $1.tokens }.formatted())
          .monospacedDigit()
          .font(.subheadline.bold())
      }
      if visibleProviders.isEmpty {
        Text("추적할 도구를 설정에서 선택할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
      }
      ForEach(CatProvider.allCases.filter { visibleProviders.contains($0) }) { provider in
        let rows = rowsByProvider[provider] ?? []
        let total = rows.reduce(Int64(0)) { $0 + $1.tokens }
        let estimated = rows.reduce(Int64(0)) { $0 + $1.estimatedTokens }
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text(provider.title)
            if let status = providers.contains(provider) ? statuses[provider.rawValue] : "추적 중지" {
              Text(status).font(.caption2).foregroundStyle(.secondary)
            }
          }
          Spacer()
          if estimated > 0 {
            Text("추정").foregroundStyle(.secondary)
          }
          Text(rows.isEmpty ? "—" : total.formatted()).monospacedDigit()
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
      }
    }
  }

  private var activityCard: some View {
    let end = calendar.startOfDay(for: now)
    let dates = (0..<84).compactMap { calendar.date(byAdding: .day, value: $0 - 83, to: end) }
    let totals = dailyTotals
    let maximum = max(1, dates.compactMap { totals[$0] }.max() ?? 0)
    let streak = streakDays(in: totals)
    return CatCard {
      HStack {
        Text("최근 12주 활동").font(.subheadline.bold())
        Spacer()
        if streak > 0 {
          Label("\(streak)일 연속", systemImage: "flame").font(.caption)
        }
      }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 12), spacing: 3) {
        ForEach(0..<dates.count, id: \.self) { index in
          let offset = index / 12 + index % 12 * 7
          let date = dates[offset]
          let value = totals[date, default: 0]
          let label = date.formatted(date: .abbreviated, time: .omitted) + " · " + value.formatted() + " 토큰"
          RoundedRectangle(cornerRadius: 2)
            .fill(
              value > 0 ? Color.teal.opacity(0.24 + 0.76 * Double(value) / Double(maximum)) : .secondary.opacity(0.15)
            )
            .aspectRatio(1, contentMode: .fit)
            .help(label)
            .accessibilityLabel(label)
        }
      }
    }
  }

  private var recapCard: some View {
    CatCard {
      HStack {
        Text("사용량 회고").font(.subheadline.bold())
        Spacer()
        Picker("회고 기간", selection: $period) {
          ForEach(CatActivityPeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 114)
      }
      if let interval = calendar.dateInterval(of: period.component, for: now) {
        let rows = days.filter { $0.date >= interval.start && $0.date < interval.end }
        let recorded = rows.compactMap(\.recordedCostUSD)
        let estimated = rows.compactMap(\.estimatedCostUSD)
        Text("\(rows.reduce(0) { $0 + $1.tokens }.formatted()) 토큰")
          .font(.system(.title3, design: .monospaced, weight: .medium))
        if let previous = calendar.date(byAdding: period.component, value: -1, to: interval.start) {
          let total = days.filter { $0.date >= previous && $0.date < interval.start }.reduce(0) { $0 + $1.tokens }
          Text("지난 기간 \(total.formatted()) 토큰").font(.caption).foregroundStyle(.secondary)
        }
        costRow("기록 비용", values: recorded)
        costRow("추정 비용", values: estimated)
      }
    }
  }

  private func costRow(_ title: String, values: [Double]) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(values.isEmpty ? "—" : values.reduce(0, +).formatted(.currency(code: "USD")))
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func streakDays(in totals: [Date: Int64]) -> Int {
    let today = calendar.startOfDay(for: now)
    let start = totals[today, default: 0] > 0 ? 0 : 1
    for distance in start..<(start + totals.count) {
      guard let day = calendar.date(byAdding: .day, value: -distance, to: today), totals[day, default: 0] > 0 else {
        return distance - start
      }
    }
    return totals.count
  }
}

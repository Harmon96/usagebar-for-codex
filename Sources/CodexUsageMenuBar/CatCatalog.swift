import Foundation

enum CatRarity: Int, CaseIterable, Codable, Sendable {
  case common, uncommon, rare, special

  var title: String {
    switch self {
    case .common: "일반"
    case .uncommon: "고급"
    case .rare: "희귀"
    case .special: "특별"
    }
  }
}

struct CatTraits: OptionSet, Sendable {
  let rawValue: UInt16

  static let fluffy = Self(rawValue: 1 << 0)
  static let round = Self(rawValue: 1 << 1)
  static let slender = Self(rawValue: 1 << 2)
  static let folded = Self(rawValue: 1 << 3)
  static let curledEars = Self(rawValue: 1 << 4)
  static let bobtail = Self(rawValue: 1 << 5)
  static let tailless = Self(rawValue: 1 << 6)
  static let shortLegs = Self(rawValue: 1 << 7)
  static let flatFace = Self(rawValue: 1 << 8)
  static let bare = Self(rawValue: 1 << 9)
  static let curly = Self(rawValue: 1 << 10)
  static let tufted = Self(rawValue: 1 << 11)
  static let mittenPaws = Self(rawValue: 1 << 12)
}

enum CatPattern: Sendable {
  case solid, ticked, tabby, spots, rosettes, point, gloves, tuxedo, calico, tortie, bicolor, van, smoke, waves
}

enum CatFantasy: Sendable {
  case moon, ghost, cloud, mushroom, ember, frost, aurora, constellation
}

struct CatCoat: Sendable {
  let name: String
  let color: UInt32
  let markings: UInt32
  let pattern: CatPattern
  let eyes: UInt32

  init(
    _ name: String,
    _ color: UInt32,
    _ markings: UInt32,
    _ pattern: CatPattern = .solid,
    eyes: UInt32 = 0xBAA25E
  ) {
    self.name = name
    self.color = color
    self.markings = markings
    self.pattern = pattern
    self.eyes = eyes
  }

  static let blue = Self("블루", 0x8298BB, 0xBBC9DF, eyes: 0x96CEA0)
  static let slate = Self("슬레이트 블루", 0x687A9D, 0xA2B1CF, eyes: 0xAEC373)
  static let black = Self("검정", 0x4A4965, 0x777592, eyes: 0xE9B651)
  static let white = Self("흰색", 0xF3E7D3, 0xFFFFFF, eyes: 0x8DBDFF)
  static let cream = Self("크림", 0xEDCCA0, 0xFBE8CF)
  static let orange = Self("치즈 태비", 0xF4AE61, 0xBA683D, .tabby)
  static let red = Self("레드 태비", 0xDD8056, 0x9A4A41, .tabby)
  static let brownTabby = Self("브라운 태비", 0xB89476, 0x6F5460, .tabby, eyes: 0xAFD18D)
  static let grayTabby = Self("고등어 태비", 0x9F9FAF, 0x65637F, .tabby, eyes: 0xA9CB8A)
  static let silverTabby = Self("실버 태비", 0xCECCDA, 0x7A7B98, .tabby, eyes: 0x92CCAB)
  static let cinnamon = Self("시나몬", 0xD28760, 0xEAA886, .ticked, eyes: 0xB6CE8A)
  static let ruddy = Self("러디", 0xCC784C, 0x784658, .ticked, eyes: 0xAACF8F)
  static let fawn = Self("폰", 0xDAC5AD, 0xA48E88, .ticked)
  static let sepia = Self("세피아", 0x9A6E66, 0x654B61)
  static let lilac = Self("라일락", 0xCBA9B6, 0x957993)
  static let mink = Self("밍크", 0xC99C7E, 0x765D72, .point, eyes: 0x8ABDD4)
  static let sealPoint = Self("씰 포인트", 0xE9C495, 0x6D5266, .point, eyes: 0x88C4FE)
  static let bluePoint = Self("블루 포인트", 0xE4D3C8, 0x7183A8, .point, eyes: 0x91C7FF)
  static let sealGloves = Self("씰 포인트와 흰 양말", 0xE9C495, 0x6D5266, .gloves, eyes: 0x88C4FE)
  static let blueGloves = Self("블루 포인트와 흰 양말", 0xE4D3C8, 0x7183A8, .gloves, eyes: 0x91C7FF)
  static let calico = Self("삼색", 0xF3E6D5, 0xD58154, .calico)
  static let diluteCalico = Self("희석 삼색", 0xF4E7DE, 0xC8A28C, .calico)
  static let tortie = Self("카오스", 0x514655, 0xD1855D, .tortie)
  static let diluteTortie = Self("희석 카오스", 0x8C899E, 0xD2AA9C, .tortie)
  static let tuxedo = Self("턱시도", 0x4E4A63, 0xF5E9DB, .tuxedo, eyes: 0xC0D48B)
  static let grayTuxedo = Self("회색 턱시도", 0x8589A0, 0xF6E7DA, .tuxedo, eyes: 0xAED29E)
  static let cow = Self("젖소 무늬", 0xEEE4DB, 0x51506B, .bicolor, eyes: 0xBCCF8E)
  static let grayCow = Self("회색 얼룩", 0xF1E5DE, 0x868BA8, .bicolor)
  static let orangeVan = Self("레드 밴", 0xF7EBD8, 0xCF7F51, .van, eyes: 0x85BFFF)
  static let creamVan = Self("크림 밴", 0xF4E9D7, 0xDAAE80, .van, eyes: 0x83BBE6)
  static let smoke = Self("스모크", 0x827890, 0xCEC3D1, .smoke)
  static let silverSmoke = Self("실버 스모크", 0xA9A8BB, 0xE3D7D7, .smoke, eyes: 0xACD295)
  static let brownSpots = Self("브라운 스폿", 0xCCA17B, 0x755361, .spots, eyes: 0xB2CE7E)
  static let silverSpots = Self("실버 스폿", 0xD4CBD2, 0x726C89, .spots, eyes: 0x9CCF8B)
  static let brownRosettes = Self("브라운 로제트", 0xD4A173, 0x81565A, .rosettes, eyes: 0xAFCB73)
  static let snowRosettes = Self("스노 로제트", 0xE7DAC6, 0xA08178, .rosettes, eyes: 0x93C8F5)
  static let rose = Self("장밋빛", 0xD9A6A5, 0xA8748A)
  static let warmSkin = Self("복숭앗빛", 0xE6AE99, 0xB77F7C)
  static let honeyWaves = Self("허니 웨이브", 0xE2B07D, 0xAE765C, .waves)
  static let silverWaves = Self("실버 웨이브", 0xD9C6CC, 0x967C9C, .waves, eyes: 0x9CC8A1)
}

struct CatKind: Identifiable, Sendable {
  let id: String
  let name: String
  let englishName: String
  let group: String
  let rarity: CatRarity
  let traits: CatTraits
  let artworkCoats: [CatCoat]
  let fantasy: CatFantasy?

  var coats: [String] { artworkCoats.map(\.name) }
}

enum CatCatalog {
  static let groups = ["생활 고양이", "실제 품종", "판타지"]
  static let all: [CatKind] = everyday + breeds + fantasy
  private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

  static func kind(_ id: String) -> CatKind? { byID[id] }

  private static func home(
    _ id: String, _ name: String, _ englishName: String, _ traits: CatTraits, _ coats: [CatCoat]
  ) -> CatKind {
    CatKind(
      id: "home-\(id)", name: name, englishName: englishName, group: groups[0], rarity: .common,
      traits: traits, artworkCoats: coats, fantasy: nil)
  }

  private static func breed(
    _ code: String, _ name: String, _ englishName: String, _ traits: CatTraits, _ coats: [CatCoat]
  ) -> CatKind {
    CatKind(
      id: "tica-\(code.lowercased())", name: name, englishName: englishName, group: groups[1],
      rarity: .uncommon, traits: traits, artworkCoats: coats, fantasy: nil)
  }

  private static func makeFantasy(
    _ id: String, _ name: String, _ englishName: String, _ rarity: CatRarity, _ effect: CatFantasy,
    _ traits: CatTraits, _ coats: [CatCoat]
  ) -> CatKind {
    CatKind(
      id: "fantasy-\(id)", name: name, englishName: englishName, group: groups[2], rarity: rarity,
      traits: traits, artworkCoats: coats, fantasy: effect)
  }

  private static let everyday: [CatKind] = [
    home("mackerel", "고등어 태비", "Mackerel Tabby", [], [.grayTabby, .silverTabby]),
    home("ginger", "치즈 태비", "Ginger Tabby", [], [.orange, .red]),
    home("brown-tabby", "갈색 태비", "Brown Tabby", [], [.brownTabby, .cinnamon]),
    home("calico", "삼색이", "Calico", [], [.calico, .diluteCalico]),
    home("tortie", "카오스", "Tortoiseshell", [], [.tortie, .diluteTortie]),
    home("tuxedo", "턱시도", "Tuxedo", [], [.tuxedo, .grayTuxedo]),
    home("cow", "젖소 고양이", "Cow Cat", [.round], [.cow, .grayCow]),
    home("black", "검은 고양이", "Black Cat", [], [.black, .init("흑갈색", 0x5E4E5C, 0x8C7480)]),
    home("white", "흰 고양이", "White Cat", [], [.white, .init("상앗빛", 0xF6DFBA, 0xFFF7E4)]),
    home("gray", "회색 고양이", "Gray Cat", [], [.blue, .slate]),
    home("longhair-tabby", "장모 태비", "Longhair Tabby", [.fluffy], [.brownTabby, .grayTabby]),
    home("longhair-calico", "장모 삼색이", "Longhair Calico", [.fluffy], [.calico, .diluteCalico]),
  ]

  // TICA Standing Rules, version C (3 June 2026), §701.4.1, pp. 54–55.
  // Codes stay stable even if a translated name or sprite changes.
  private static let breeds: [CatKind] = [
    breed("AB", "아비시니안", "Abyssinian", [.slender], [.ruddy, .cinnamon]),
    breed("ABT", "아메리칸 밥테일", "American Bobtail", [.bobtail, .fluffy], [.brownTabby, .orange]),
    breed("ABS", "아메리칸 밥테일 단모", "American Bobtail Shorthair", [.bobtail], [.brownTabby, .silverTabby]),
    breed("AC", "아메리칸 컬", "American Curl", [.curledEars], [.calico, .silverTabby]),
    breed("ACL", "아메리칸 컬 장모", "American Curl Longhair", [.curledEars, .fluffy], [.calico, .cream]),
    breed("AS", "아메리칸 쇼트헤어", "American Shorthair", [.round], [.silverTabby, .brownTabby]),
    breed("AW", "아메리칸 와이어헤어", "American Wirehair", [.curly], [.silverWaves, .grayTabby]),
    breed("AUM", "오스트레일리안 미스트", "Australian Mist", [.round], [.brownSpots, .silverSpots]),
    breed("BA", "발리니즈", "Balinese", [.fluffy, .slender], [.sealPoint, .bluePoint]),
    breed("BG", "벵갈", "Bengal", [.slender], [.brownRosettes, .snowRosettes]),
    breed("BGL", "벵갈 장모", "Bengal Longhair", [.fluffy], [.brownRosettes, .snowRosettes]),
    breed("BI", "버만", "Birman", [.fluffy], [.sealGloves, .blueGloves]),
    breed("BO", "봄베이", "Bombay", [.round], [.black]),
    breed("BL", "브리티시 롱헤어", "British Longhair", [.fluffy, .round], [.blue, .cream]),
    breed("BS", "브리티시 쇼트헤어", "British Shorthair", [.round], [.blue, .lilac]),
    breed("BU", "버미즈", "Burmese", [.round], [.sepia, .lilac]),
    breed("BM", "버밀라", "Burmilla", [.round], [.silverSmoke, .smoke]),
    breed("BML", "버밀라 장모", "Burmilla Longhair", [.fluffy, .round], [.silverSmoke, .smoke]),
    breed(
      "CX", "샤르트뢰", "Chartreux", [.round],
      [
        .init("블루", 0x8694AD, 0xB3BCCB, eyes: 0xEDAA51),
        .init("진한 블루", 0x687991, 0x98A1BB, eyes: 0xEDA653),
      ]),
    breed("CU", "쇼지", "Chausie", [.slender, .tufted], [.fawn, .black]),
    breed("CB", "체루빔", "Cherubim", [.fluffy], [.sealPoint, .mink]),
    breed("CR", "코니시 렉스", "Cornish Rex", [.slender, .curly], [.honeyWaves, .silverWaves]),
    breed("CY", "킴릭", "Cymric", [.fluffy, .round, .tailless], [.grayTabby, .calico]),
    breed("CYT", "꼬리 있는 킴릭", "Cymric Tailed", [.fluffy, .round], [.brownTabby, .orange]),
    breed("DR", "데본 렉스", "Devon Rex", [.curly, .slender, .flatFace], [.silverWaves, .honeyWaves]),
    breed("DSK", "돈스코이", "Donskoy", [.slender, .bare], [.rose, .warmSkin]),
    breed("EM", "이집션 마우", "Egyptian Mau", [.slender], [.silverSpots, .brownSpots]),
    breed("ES", "엑조틱 쇼트헤어", "Exotic Shorthair", [.round, .flatFace], [.cream, .calico]),
    breed(
      "HB", "하바나", "Havana", [.slender],
      [
        .init("초콜릿", 0x956555, 0xBA8E76, eyes: 0xA8D780),
        .init("라일락", 0xBC9BAB, 0xD4B6BE, eyes: 0xACCB80),
      ]),
    breed("HG", "하이랜더", "Highlander", [.curledEars, .fluffy, .bobtail], [.brownSpots, .silverSpots]),
    breed("HGS", "하이랜더 단모", "Highlander Shorthair", [.curledEars, .bobtail], [.brownSpots, .silverSpots]),
    breed("HI", "히말라얀", "Himalayan", [.flatFace, .fluffy, .round], [.sealPoint, .bluePoint]),
    breed("JB", "재패니즈 밥테일", "Japanese Bobtail", [.bobtail, .slender], [.calico, .orangeVan]),
    breed("JBL", "재패니즈 밥테일 장모", "Japanese Bobtail Longhair", [.bobtail, .slender, .fluffy], [.calico, .orangeVan]),
    breed(
      "KM", "카오마니", "Khaomanee", [.slender],
      [
        .init("흰색과 금빛 눈", 0xF6E9DB, 0xFFFFFF, eyes: 0xE8BF66),
        .init("흰색과 푸른 눈", 0xF6E9DB, 0xFFFFFF, eyes: 0x89BFFE),
      ]),
    breed(
      "KT", "코랏", "Korat", [.slender, .round],
      [
        .init("실버 팁 블루", 0x7B87AE, 0xBEBDD5, .smoke, eyes: 0xA1E3A0),
        .init("딥 실버 블루", 0x636B90, 0xA8ACC7, .smoke, eyes: 0xA8DB8F),
      ]),
    breed("KB", "쿠릴리안 밥테일", "Kurilian Bobtail", [.bobtail, .round], [.brownTabby, .calico]),
    breed("KBL", "쿠릴리안 밥테일 장모", "Kurilian Bobtail Longhair", [.bobtail, .round, .fluffy], [.brownTabby, .calico]),
    breed("LP", "라팜", "LaPerm", [.fluffy, .curly], [.honeyWaves, .silverWaves]),
    breed("LPS", "라팜 단모", "LaPerm Shorthair", [.curly], [.honeyWaves, .silverWaves]),
    breed("LY", "라이코이", "Lykoi", [.slender], [.smoke, .silverSmoke]),
    breed("MC", "메인쿤", "Maine Coon", [.fluffy, .tufted], [.brownTabby, .smoke]),
    breed("MCP", "메인쿤 다지증", "Maine Coon Polydactyl", [.fluffy, .tufted, .mittenPaws], [.brownTabby, .red]),
    breed("MX", "맹크스", "Manx", [.tailless, .round], [.orange, .grayTabby]),
    breed("MXT", "꼬리 있는 맹크스", "Manx Tailed", [.round], [.orange, .grayTabby]),
    breed("MNT", "미뉴에트", "Minuet", [.shortLegs, .round, .flatFace], [.cream, .grayTabby]),
    breed("MNL", "미뉴에트 장모", "Minuet Longhair", [.shortLegs, .fluffy, .round, .flatFace], [.cream, .grayTabby]),
    breed("MTT", "미뉴에트 긴다리", "Minuet Tall", [.round, .flatFace], [.grayTabby, .white]),
    breed("MTL", "미뉴에트 긴다리 장모", "Minuet Tall Longhair", [.fluffy, .round, .flatFace], [.cream, .grayTabby]),
    breed("MK", "먼치킨", "Munchkin", [.shortLegs], [.orange, .calico]),
    breed("MKL", "먼치킨 장모", "Munchkin Longhair", [.shortLegs, .fluffy], [.orange, .calico]),
    breed("NB", "네벨룽", "Nebelung", [.fluffy, .slender], [.slate, .blue]),
    breed("NF", "노르웨이 숲", "Norwegian Forest", [.fluffy, .tufted, .round], [.grayTabby, .tuxedo]),
    breed("OC", "오시캣", "Ocicat", [.slender], [.brownSpots, .silverSpots]),
    breed("OL", "오리엔탈 롱헤어", "Oriental Longhair", [.fluffy, .slender], [.lilac, .tuxedo]),
    breed("OS", "오리엔탈 쇼트헤어", "Oriental Shorthair", [.slender], [.lilac, .black]),
    breed("PS", "페르시안", "Persian", [.round, .fluffy, .flatFace], [.white, .silverSmoke]),
    breed("PD", "피터볼드", "Peterbald", [.slender, .bare], [.warmSkin, .lilac]),
    breed("PB", "픽시밥", "Pixiebob", [.bobtail, .tufted, .mittenPaws], [.brownSpots]),
    breed("PBL", "픽시밥 장모", "Pixiebob Longhair", [.bobtail, .tufted, .mittenPaws, .fluffy], [.brownSpots]),
    breed("RD", "랙돌", "Ragdoll", [.fluffy, .round], [.sealGloves, .blueGloves]),
    breed("RB", "러시안 블루", "Russian Blue", [.slender], [.blue, .slate]),
    breed("SV", "사바나", "Savannah", [.slender, .tufted], [.brownSpots, .silverSpots]),
    breed("SCS", "스코티시 스트레이트", "Scottish Straight", [.round], [.grayTabby, .calico]),
    breed("SC", "스코티시 스트레이트 장모", "Scottish Straight Longhair", [.round, .fluffy], [.grayTabby, .calico]),
    breed("SF", "스코티시 폴드", "Scottish Fold", [.folded, .round], [.grayTabby, .blue]),
    breed("SFL", "스코티시 폴드 장모", "Scottish Fold Longhair", [.folded, .round, .fluffy], [.grayTabby, .blue]),
    breed("SR", "셀커크 렉스", "Selkirk Rex", [.curly, .round], [.silverWaves, .honeyWaves]),
    breed("SRL", "셀커크 렉스 장모", "Selkirk Rex Longhair", [.curly, .fluffy, .round], [.silverWaves, .honeyWaves]),
    breed("SI", "샴", "Siamese", [.slender], [.sealPoint, .bluePoint]),
    breed("SB", "시베리안", "Siberian", [.fluffy, .round, .tufted], [.brownTabby, .sealPoint]),
    breed("SG", "싱가푸라", "Singapura", [.slender], [CatCoat("세피아 아구티", 0xDBBC8F, 0x8B6B61, .ticked)]),
    breed("SN", "스노슈", "Snowshoe", [.round], [.sealGloves, .blueGloves]),
    breed("SO", "소말리", "Somali", [.slender, .fluffy], [.ruddy, .cinnamon]),
    breed("SX", "스핑크스", "Sphynx", [.bare, .slender, .round], [.rose, .warmSkin]),
    breed(
      "TR", "테네시 렉스 장모", "Tennessee Rex Longhair", [.fluffy, .curly],
      [
        .init("골든 새틴", 0xD9A579, 0xF8D6A9, .waves),
        .init("크림 새틴", 0xE7BCAB, 0xFAE7C9, .waves),
      ]),
    breed(
      "TRS", "테네시 렉스 단모", "Tennessee Rex Shorthair", [.curly],
      [
        .init("레드 새틴", 0xC58173, 0xF3C4AD, .waves),
        .init("크림 새틴", 0xE7BCAB, 0xFAE7C9, .waves),
      ]),
    breed("TH", "타이", "Thai", [.round], [.sealPoint, .bluePoint]),
    breed("TO", "통키니즈", "Tonkinese", [], [.mink, .bluePoint]),
    breed("TG", "토이거", "Toyger", [.slender], [.orange, .red]),
    breed("TA", "터키시 앙고라", "Turkish Angora", [.fluffy, .slender], [.white, .smoke]),
    breed("TV", "터키시 밴", "Turkish Van", [.fluffy], [.orangeVan, .creamVan]),
  ]

  private static let fantasy: [CatKind] = [
    makeFantasy(
      "moon", "달빛 고양이", "Moonlight Cat", .rare, .moon, [.slender],
      [
        .init("초승달", 0x796FA7, 0xE7D7AB, .smoke, eyes: 0xF7DE7A),
        .init("보름달", 0xAA93C4, 0xF8DF9F, .smoke, eyes: 0xFFF0A4),
      ]),
    makeFantasy(
      "ghost", "유령 고양이", "Ghost Cat", .rare, .ghost, [.tailless],
      [
        .init("안개", 0xBEC9DD, 0xEDFAF7, .smoke, eyes: 0xA7EEE2),
        .init("야광", 0xA7ADDA, 0xEBDAFA, .smoke, eyes: 0xCBA8FF),
      ]),
    makeFantasy(
      "cloud", "구름 고양이", "Cloud Cat", .rare, .cloud, [.fluffy, .round],
      [
        .init("새벽구름", 0xC4D6EC, 0xFBFAF4, .smoke, eyes: 0x89CBEA),
        .init("노을구름", 0xE5B8CA, 0xFFF1D6, .smoke, eyes: 0xB7A7E6),
      ]),
    makeFantasy(
      "mushroom", "버섯숲 고양이", "Mushroom Grove Cat", .rare, .mushroom, [.round, .shortLegs],
      [
        .init("단풍 숲", 0xD2AA82, 0xAD685D, .spots, eyes: 0xADDB83),
        .init("이끼 숲", 0xACBA86, 0x689378, .spots, eyes: 0xF1C571),
      ]),
    makeFantasy(
      "ember", "불씨 고양이", "Ember Cat", .rare, .ember, [.tufted],
      [
        .init("숯불", 0x8F5362, 0xFCA54D, .tabby, eyes: 0xFFE050),
        .init("푸른 불씨", 0x5E5F97, 0x78C9F2, .tabby, eyes: 0xA7F5FF),
      ]),
    makeFantasy(
      "frost", "서리 고양이", "Frost Cat", .rare, .frost, [.tufted, .fluffy],
      [
        .init("얼음꽃", 0xA5D8DB, 0xE8FCFF, .point, eyes: 0x84B9FF),
        .init("눈 결정", 0xA5B9E7, 0xF7E8F6, .point, eyes: 0x9AE8F9),
      ]),
    makeFantasy(
      "aurora", "오로라 고양이", "Aurora Cat", .special, .aurora, [.slender, .fluffy],
      [
        .init("에메랄드 오로라", 0x6767A6, 0x7BE4AE, .waves, eyes: 0xC6F6A0),
        .init("분홍 오로라", 0x7862A4, 0xED94CB, .waves, eyes: 0xABF3DB),
      ]),
    makeFantasy(
      "constellation", "별자리 고양이", "Constellation Cat", .special, .constellation, [.round, .tufted],
      [
        .init("남빛 밤하늘", 0x545184, 0xEBCE91, .spots, eyes: 0xFFD979),
        .init("보랏빛 밤하늘", 0x775492, 0xD7B6E6, .spots, eyes: 0x9EE6F2),
      ]),
  ]
}

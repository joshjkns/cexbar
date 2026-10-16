// CeX Bar — a macOS menu bar app that watches CeX UK stock for anything you search for.
// Build with ./build.sh (needs Xcode or the Command Line Tools: `xcode-select --install`).
//
// It queries the same search service (Algolia at search.webuy.io) that uk.webuy.com's own
// search page uses, with the public search-only key the site gives every browser. This is
// unofficial, so it may break if CeX changes their site. Keep auto-refresh modest.
//
// Filters aren't hard-coded: departments, categories and attributes (RAM, Capacity, Network,
// Platform, Grade, …) come from the facets CeX returns for the current search.

import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement

// MARK: - Preferences

enum Prefs {
    static let search = "search"
    static let refreshMinutes = "refreshMinutes"
    static let notify = "notify"

    static let defaults: [String: Any] = [
        refreshMinutes: 30,
        notify: true,
    ]

    static func register() { UserDefaults.standard.register(defaults: defaults) }
}

enum SortOrder: String, Codable, CaseIterable, Identifiable {
    case priceLow, priceHigh, priceDrop, name
    var id: String { rawValue }
    var label: String {
        switch self {
        case .priceLow: return "Price: low to high"
        case .priceHigh: return "Price: high to low"
        case .priceDrop: return "Biggest price drop"
        case .name: return "Name"
        }
    }
}

/// Selected values for one facet. Values within a facet are OR'd; facets are AND'd together.
struct AttributeFilter: Codable, Hashable {
    var values: [String] = []
    /// For numeric facets (RAM, Capacity, screen size…): treat the smallest selected value as a minimum.
    var orMore = false
}

struct Search: Codable, Equatable {
    var query = ""
    var department = ""     // superCatFriendlyName, "" = any
    var category = ""       // categoryFriendlyName, "" = any
    var attributes: [String: AttributeFilter] = [:]
    var mustContain = ""
    var exclude = ""
    var minPrice = ""
    var maxPrice = ""
    var stores = ""
    var onlineOnly = false
    var sort: SortOrder = .priceLow

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Search()
        query = try c.decodeIfPresent(String.self, forKey: .query) ?? d.query
        department = try c.decodeIfPresent(String.self, forKey: .department) ?? d.department
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? d.category
        attributes = try c.decodeIfPresent([String: AttributeFilter].self, forKey: .attributes) ?? d.attributes
        mustContain = try c.decodeIfPresent(String.self, forKey: .mustContain) ?? d.mustContain
        exclude = try c.decodeIfPresent(String.self, forKey: .exclude) ?? d.exclude
        minPrice = try c.decodeIfPresent(String.self, forKey: .minPrice) ?? d.minPrice
        maxPrice = try c.decodeIfPresent(String.self, forKey: .maxPrice) ?? d.maxPrice
        stores = try c.decodeIfPresent(String.self, forKey: .stores) ?? d.stores
        onlineOnly = try c.decodeIfPresent(Bool.self, forKey: .onlineOnly) ?? d.onlineOnly
        sort = (try? c.decodeIfPresent(SortOrder.self, forKey: .sort)) ?? d.sort
    }

    private static func list(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    var mustContainList: [String] { Self.list(mustContain) }
    var excludeList: [String] { Self.list(exclude) }
    var storeList: [String] { Self.list(stores) }
    var minPriceValue: Int? { Int(minPrice.filter { $0.isNumber }) }
    var maxPriceValue: Int? { Int(maxPrice.filter { $0.isNumber }) }
    var activeAttributes: [(name: String, filter: AttributeFilter)] {
        attributes.filter { !$0.value.values.isEmpty }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Nothing to search for yet — don't pull the whole catalogue.
    var isEmpty: Bool { trimmedQuery.isEmpty && department.isEmpty && category.isEmpty }

    var summary: String {
        var bits: [String] = []
        if !trimmedQuery.isEmpty { bits.append("“\(trimmedQuery)”") }
        if !category.isEmpty { bits.append(category) } else if !department.isEmpty { bits.append(department) }
        if !mustContainList.isEmpty { bits.append(mustContainList.joined(separator: " / ")) }
        for (_, f) in activeAttributes {
            if f.orMore, let floor = f.values.min(by: { (measure($0) ?? 0) < (measure($1) ?? 0) }) {
                bits.append("≥" + floor)
            } else {
                bits.append(f.values.joined(separator: "/"))
            }
        }
        switch (minPriceValue, maxPriceValue) {
        case let (lo?, hi?): bits.append("£\(lo)–£\(hi)")
        case let (lo?, nil): bits.append("≥£\(lo)")
        case let (nil, hi?): bits.append("≤£\(hi)")
        default: break
        }
        if !storeList.isEmpty { bits.append(storeList.joined(separator: ", ")) }
        if onlineOnly { bits.append("online") }
        return bits.isEmpty ? "No search set" : bits.joined(separator: " · ")
    }

    func matches(_ item: Item) -> Bool {
        let n = item.name.lowercased()
        if !mustContainList.isEmpty && !mustContainList.contains(where: { n.contains($0.lowercased()) }) { return false }
        if excludeList.contains(where: { n.contains($0.lowercased()) }) { return false }
        if onlineOnly && !item.online { return false }
        if !storeList.isEmpty {
            let hit = item.stores.contains { st in storeList.contains { st.lowercased().contains($0.lowercased()) } }
            if !hit { return false }
        }
        for (name, f) in activeAttributes {
            let have = item.attributes[name] ?? []
            if f.orMore, let floor = f.values.compactMap(measure).min() {
                guard have.contains(where: { (measure($0) ?? -.infinity) >= floor }) else { return false }
            } else {
                let wanted = Set(f.values.map(facetKey))
                guard have.contains(where: { wanted.contains(facetKey($0)) }) else { return false }
            }
        }
        return true
    }

    func sorted(_ items: [Item]) -> [Item] {
        switch sort {
        case .priceLow: return items.sorted { ($0.price ?? .infinity) < ($1.price ?? .infinity) }
        case .priceHigh: return items.sorted { ($0.price ?? 0) > ($1.price ?? 0) }
        case .priceDrop: return items.sorted { $0.priceDrop > $1.priceDrop }
        case .name: return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    // Persistence

    static func load() -> Search {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Prefs.search), let s = try? JSONDecoder().decode(Search.self, from: data) {
            return s
        }
        return migrateLegacy() ?? Search()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Prefs.search) }
    }

    /// Carries over settings from the MacBook-only version of the app (which also had these defaults).
    private static func migrateLegacy() -> Search? {
        let d = UserDefaults.standard
        let keys = ["query", "mustContain", "exclude", "minRAM", "screen", "grades", "maxPrice", "stores", "onlineOnly", "laptopsOnly"]
        guard keys.contains(where: { d.object(forKey: $0) != nil }) else { return nil }
        var s = Search()
        s.query = d.string(forKey: "query") ?? "macbook pro m4"
        s.mustContain = d.string(forKey: "mustContain") ?? "M4 Pro, M4 Max"
        s.exclude = d.string(forKey: "exclude") ?? ""
        s.maxPrice = d.string(forKey: "maxPrice") ?? ""
        s.stores = d.string(forKey: "stores") ?? ""
        s.onlineOnly = d.object(forKey: "onlineOnly") != nil && d.bool(forKey: "onlineOnly")
        let minRAM = d.object(forKey: "minRAM") != nil ? d.integer(forKey: "minRAM") : 36
        if minRAM > 0 { s.attributes["RAM"] = AttributeFilter(values: ["\(minRAM)GB"], orMore: true) }
        let screen = d.string(forKey: "screen") ?? "14"
        if !screen.isEmpty { s.attributes["Screen Size 'Inches'"] = AttributeFilter(values: [screen]) }
        let grades = (d.string(forKey: "grades") ?? "ABC").map { String($0) }
        if !grades.isEmpty && grades.count < 3 { s.attributes["Grade"] = AttributeFilter(values: grades) }
        let laptopsOnly = d.object(forKey: "laptopsOnly") == nil || d.bool(forKey: "laptopsOnly")
        if laptopsOnly && s.query.lowercased().contains("mac") { s.category = "Laptops - Apple Mac" }
        s.save()
        for k in keys { d.removeObject(forKey: k) }
        return s
    }
}

// MARK: - Helpers

func match(_ pattern: String, _ s: String, group: Int = 1, caseInsensitive: Bool = true) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return nil }
    let range = NSRange(s.startIndex..., in: s)
    guard let m = re.firstMatch(in: s, options: [], range: range),
          m.numberOfRanges > group,
          let r = Range(m.range(at: group), in: s) else { return nil }
    return String(s[r])
}

func firstString(_ v: Any?) -> String? { strings(v).first }

func strings(_ v: Any?) -> [String] {
    if let a = v as? [Any] { return a.compactMap { $0 is NSNull ? nil : "\($0)" } }
    if let s = v as? String { return [s] }
    if let n = v as? NSNumber { return [n.stringValue] }
    return []
}

func number(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

/// Numeric reading of a facet value, so sizes compare properly: "48GB RAM" -> 48, "1TB" -> 1024,
/// "14" -> 14, "13.3\"" -> 13.3. Nil for anything that isn't just a number (+ unit).
func measure(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces)
    guard let n = match(#"^(\d+(?:\.\d+)?)\s*(?:TB|GB|MB|"|″|in|inch|inches)?(?:\s*(?:RAM|SSD|HDD))?$"#, t),
          var v = Double(n) else { return nil }
    let unit = match(#"^\d+(?:\.\d+)?\s*(TB|MB)"#, t)?.uppercased()
    if unit == "TB" { v *= 1024 } else if unit == "MB" { v /= 1024 }
    return v
}

/// Facet values are messy ("48GB" vs "48GB RAM", "Apple" vs "apple"), so compare on this key.
func facetKey(_ s: String) -> String {
    if let m = measure(s) { return "#\(m)" }
    return s.trimmingCharacters(in: .whitespaces).lowercased()
}

/// "Screen Size 'Inches'" -> "Screen Size (inches)"
func facetTitle(_ name: String) -> String {
    name.replacingOccurrences(of: #"\s*'(.+?)'"#, with: " ($1)", options: .regularExpression)
        .replacingOccurrences(of: "(Inches)", with: "(inches)")
}

func money(_ v: Double?) -> String {
    guard let v else { return "£?" }
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "GBP"
    f.locale = Locale(identifier: "en_GB")
    f.maximumFractionDigits = v.rounded() == v ? 0 : 2
    return f.string(from: NSNumber(value: v)) ?? "£\(Int(v))"
}

// MARK: - Model

struct Item: Identifiable, Hashable {
    let id: String
    let name: String
    let title: String
    let specs: String
    let grade: String?
    let stores: [String]
    let online: Bool
    let price: Double?
    let previousPrice: Double?
    let imageURL: URL?
    let category: String
    let department: String
    /// Every facet attribute retrieved for this hit, e.g. ["RAM": ["48GB"], "Network": ["Unlocked"]].
    let attributes: [String: [String]]

    var inStock: Bool { online || !stores.isEmpty }
    var priceText: String { money(price) }
    var priceDrop: Double {
        guard let p = price, let prev = previousPrice, prev > 0 else { return 0 }
        return prev - p
    }
    var wasText: String? {
        guard let p = price, let prev = previousPrice, prev > 0, prev != p else { return nil }
        return "\(p > prev ? "↑" : "↓") was \(money(prev))"
    }
    var stockText: String {
        guard inStock else { return "Out of stock" }
        let shown = stores.prefix(2).joined(separator: ", ")
        let more = stores.count > 2 ? " +\(stores.count - 2)" : ""
        if online && !stores.isEmpty { return "Online · \(shown)\(more)" }
        return online ? "Online" : "In store · \(shown)\(more)"
    }
    var url: URL { CeXAPI.productURL(id) }

    init?(hit h: [String: Any]) {
        guard let name = h["boxName"] as? String,
              let id = (h["boxId"] as? String) ?? (h["objectID"] as? String) else { return nil }
        self.id = id
        self.name = name

        var attrs: [String: [String]] = [:]
        for (k, v) in h where !CeXAPI.baseFields.contains(k) && !k.hasPrefix("_") {
            let s = strings(v)
            if !s.isEmpty { attrs[k] = s }
        }
        self.attributes = attrs

        let parts = name.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }

        // Grade: facet first, then the end of the title ("…/SB/B", "…/C(Greek)", "… Unlocked A")
        var g = firstString(h["Grade"]).flatMap { match(#"^([A-F])$"#, $0, caseInsensitive: false) }
        var gradeExtra: String? = nil
        if g == nil, parts.count > 2, let last = parts.last {
            g = match(#"^([A-C])(?:\(|$)"#, last, caseInsensitive: false)
            gradeExtra = match(#"\((.+)\)"#, last)
        }
        if g == nil { g = match(#"\s([A-C])$"#, name, caseInsensitive: false) }
        self.grade = g

        self.stores = h["stores"] as? [String] ?? []
        let availability = h["availability"] as? [String] ?? []
        self.online = (number(h["inStockOnline"]) ?? 0) > 0 || availability.contains("In Stock Online")
        self.price = number(h["sellPrice"])
        self.previousPrice = number(h["previousPrice"])
        self.category = h["categoryFriendlyName"] as? String ?? ""
        self.department = h["superCatFriendlyName"] as? String ?? ""

        let images = h["imageUrls"] as? [String: Any]
        let rawImage = (images?["medium"] as? String) ?? (images?["small"] as? String)
        self.imageURL = rawImage
            .flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) }
            .flatMap { URL(string: $0) }

        // Friendlier title + spec line for "Model/CPU/RAM/SSD/Screen/Colour/Grade" style names (computers)
        if parts.count > 2 {
            var title = parts[0].replacingOccurrences(of: #"\s+\d+,\d+$"#, with: "", options: .regularExpression)
            var specs: [String] = []
            let colours = ["SB": "Space Black", "SG": "Space Grey", "Blk": "Black", "Slv": "Silver"]
            for (i, p) in parts.dropFirst().enumerated() {
                let isLast = i == parts.count - 2
                if isLast && match(#"^([A-C])(?:\(|$)"#, p, caseInsensitive: false) != nil { continue }
                if match(#"^(\d+(?:\.\d+)?)""#, p) != nil {
                    title += " " + (match(#"^(\d+(?:\.\d+)?)""#, p) ?? "") + "″"
                    if p.uppercased().contains("NTD") { specs.append("Nano-texture") }
                    continue
                }
                var s = colours[p] ?? p
                s = s.replacingOccurrences(of: " Ram", with: " RAM")
                s = s.replacingOccurrences(of: "-CPU", with: "-core CPU")
                s = s.replacingOccurrences(of: "-GPU", with: "-core GPU")
                specs.append(s)
            }
            if let gradeExtra { specs.append(gradeExtra) }
            self.title = title
            self.specs = specs.joined(separator: " · ")
        } else {
            // e.g. "Apple iPhone 15 128GB Black, Unlocked A" — drop the trailing grade letter, it has a badge
            self.title = g == nil ? name : name.replacingOccurrences(of: #"\s[A-C]$"#, with: "", options: .regularExpression)
            self.specs = category
        }
    }
}

struct FacetValue: Identifiable, Hashable {
    let label: String
    let count: Int
    var key: String { facetKey(label) }
    var id: String { key }
}

struct Facet: Identifiable {
    let name: String
    let values: [FacetValue]
    let numeric: Bool
    var id: String { name }
}

struct FacetSet {
    var total = 0
    var departments: [FacetValue] = []
    var categories: [FacetValue] = []
    var attributes: [Facet] = []
}

// MARK: - CeX search

enum CeXError: LocalizedError {
    case http(Int)
    case badResponse
    var errorDescription: String? {
        switch self {
        case .http(let code): return "CeX search returned HTTP \(code)"
        case .badResponse: return "Unexpected response from CeX"
        }
    }
}

enum CeXAPI {
    static let searchURL = URL(string: "https://search.webuy.io/1/indexes/prod_cex_uk/query")!
    static let appID = "LNNFEEWZVA"
    static let apiKey = "bf79f2b6699e60a18ae330a1248b452c"   // public search-only key used by uk.webuy.com
    static let maxResults = 1000                              // Algolia won't page past this
    static let baseFields: Set<String> = [
        "boxId", "boxName", "sellPrice", "previousPrice", "stores", "inStockOnline", "availability",
        "categoryFriendlyName", "superCatFriendlyName", "imageUrls", "objectID",
    ]
    /// Facets that are bookkeeping, prices or handled elsewhere — never offered as attribute filters.
    static let hiddenFacets: Set<String> = [
        "scId", "stores", "outOfStock", "sellPrice", "cashPriceCalculated", "exchangePriceCalculated",
        "productImage", "inStockOnline", "availability", "categoryId", "categoryFriendlyName",
        "superCatFriendlyName", "productLineName", "Model Number", "Meta Title", "Barcode",
        "boxId", "boxName", "new", "rating", "buyPerc", "firstPrice", "previousPrice", "timestamp",
        "boxDeleted", "showOnWeb", "origin", "operatorId", "gradeId",
    ]
    static let inStock = ["availability:In Stock Online", "availability:In Stock In Store"]

    static func productURL(_ id: String) -> URL {
        URL(string: "https://uk.webuy.com/product-detail?id=\(id)")!
    }

    static func searchPageURL(_ query: String) -> URL {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://uk.webuy.com/search?stext=\(q)")!
    }

    /// Department/category go to the server (every product has them); attributes are matched
    /// locally because many listings are missing them or spell them differently.
    private static func baseBody(_ s: Search, department: Bool = true, category: Bool = true) -> [String: Any] {
        var facetFilters: [Any] = [inStock]
        if department && !s.department.isEmpty { facetFilters.append("superCatFriendlyName:\(s.department)") }
        if category && !s.category.isEmpty { facetFilters.append("categoryFriendlyName:\(s.category)") }
        var numeric: [String] = []
        if let lo = s.minPriceValue { numeric.append("sellPrice>=\(lo)") }
        if let hi = s.maxPriceValue { numeric.append("sellPrice<=\(hi)") }
        var body: [String: Any] = [
            "query": s.trimmedQuery,
            "facetFilters": facetFilters,
            "attributesToHighlight": [String](),
        ]
        if !numeric.isEmpty { body["numericFilters"] = numeric }
        return body
    }

    private static func post(_ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: searchURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue(apiKey, forHTTPHeaderField: "X-Algolia-API-Key")
        req.setValue(appID, forHTTPHeaderField: "X-Algolia-Application-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://uk.webuy.com", forHTTPHeaderField: "Origin")
        req.setValue("https://uk.webuy.com/", forHTTPHeaderField: "Referer")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw CeXError.http(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CeXError.badResponse }
        return json
    }

    /// Returns the raw hits plus the total number of matches CeX reported.
    static func search(_ s: Search) async throws -> (hits: [[String: Any]], total: Int) {
        var hits: [[String: Any]] = []
        var total = 0
        var page = 0
        let fields = Array(baseFields) + ["Grade"] + s.attributes.keys
        while hits.count < maxResults {
            var body = baseBody(s)
            body["hitsPerPage"] = min(100, maxResults - hits.count)
            body["page"] = page
            body["attributesToRetrieve"] = fields
            let json = try await post(body)
            let batch = json["hits"] as? [[String: Any]] ?? []
            total = (json["nbHits"] as? NSNumber)?.intValue ?? total
            hits.append(contentsOf: batch)
            page += 1
            let pages = (json["nbPages"] as? NSNumber)?.intValue ?? 0
            if batch.isEmpty || page >= pages { break }
        }
        return (hits, total)
    }

    /// What's available to filter on for this search. Each level ignores its own selection so you
    /// can still see the alternatives; attributes ignore attribute selections for the same reason.
    static func facets(_ s: Search) async throws -> FacetSet {
        func facetBody(_ facets: [String], department: Bool, category: Bool, max: Int) -> [String: Any] {
            var b = baseBody(s, department: department, category: category)
            b["hitsPerPage"] = 0
            b["facets"] = facets
            b["maxValuesPerFacet"] = max
            return b
        }
        let deptBody = facetBody(["superCatFriendlyName"], department: false, category: false, max: 50)
        let catBody = facetBody(["categoryFriendlyName"], department: true, category: false, max: 300)
        let attrBody = facetBody(["*"], department: true, category: true, max: 100)
        async let deptJSON = post(deptBody)
        async let catJSON = post(catBody)
        async let attrJSON = post(attrBody)
        let (d, c, a) = try await (deptJSON, catJSON, attrJSON)

        func values(_ raw: Any?) -> [FacetValue] {
            let dict = raw as? [String: Any] ?? [:]
            // Merge spellings that mean the same thing, keeping the most common label.
            var merged: [String: (label: String, best: Int, count: Int)] = [:]
            for (label, n) in dict {
                let count = (n as? NSNumber)?.intValue ?? 0
                let key = facetKey(label)
                if let m = merged[key] {
                    merged[key] = (count > m.best ? label : m.label, max(count, m.best), m.count + count)
                } else {
                    merged[key] = (label, count, count)
                }
            }
            return merged.values.map { FacetValue(label: $0.label, count: $0.count) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
        }

        var set = FacetSet()
        set.total = (a["nbHits"] as? NSNumber)?.intValue ?? 0
        set.departments = values((d["facets"] as? [String: Any])?["superCatFriendlyName"])
        set.categories = values((c["facets"] as? [String: Any])?["categoryFriendlyName"])

        let all = a["facets"] as? [String: Any] ?? [:]
        var attrs: [(facet: Facet, coverage: Int)] = []
        for (name, raw) in all where !hiddenFacets.contains(name) {
            var vals = values(raw)
            let coverage = vals.reduce(0) { $0 + $1.count }
            let selected = !(s.attributes[name]?.values.isEmpty ?? true)
            // Skip facets that barely apply to these results, or that are basically unique per product.
            let relevant = vals.count >= 2 && vals.count < 100 && coverage * 5 >= set.total
            guard relevant || selected else { continue }
            let numericCount = vals.filter { measure($0.label) != nil }.reduce(0) { $0 + $1.count }
            let numeric = coverage > 0 && numericCount * 5 >= coverage * 4
            if numeric {
                vals.sort { (measure($0.label) ?? .infinity) < (measure($1.label) ?? .infinity) }
            }
            attrs.append((Facet(name: name, values: vals, numeric: numeric), coverage))
        }
        // Grade first (it's on almost everything), then by how much of the result set each covers.
        set.attributes = attrs.sorted {
            if ($0.facet.name == "Grade") != ($1.facet.name == "Grade") { return $0.facet.name == "Grade" }
            return $0.coverage != $1.coverage ? $0.coverage > $1.coverage : $0.facet.name < $1.facet.name
        }.map { $0.facet }
        return set
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var search = Search.load()
    @Published var items: [Item] = []
    @Published var isLoading = false
    @Published var lastUpdated: Date?
    @Published var error: String?
    @Published var newIDs: Set<String> = []
    /// CeX had more matches than we can page through, so results may be incomplete.
    @Published var truncated = false

    private var seen: Set<String> = []
    private var hasLoaded = false
    private var timer: Task<Void, Never>?

    func update(_ s: Search) {
        guard s != search else { return }
        search = s
        s.save()
        filtersChanged()
    }

    func refresh(notify: Bool) async {
        if isLoading { return }
        let s = search
        guard !s.isEmpty else {
            items = []
            newIDs = []
            truncated = false
            error = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let (raw, total) = try await CeXAPI.search(s)
            guard s == search else { return }   // filters changed mid-flight; a fresh refresh is queued
            let parsed = s.sorted(raw.compactMap { Item(hit: $0) }.filter { $0.inStock && s.matches($0) })
            let ids = Set(parsed.map { $0.id })
            let fresh = hasLoaded ? ids.subtracting(seen) : []
            seen.formUnion(ids)
            hasLoaded = true
            newIDs = newIDs.intersection(ids).union(fresh)
            items = parsed
            truncated = total > raw.count
            lastUpdated = Date()
            error = nil
            if notify && !fresh.isEmpty {
                Notifier.post(parsed.filter { fresh.contains($0.id) })
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Call after filters change: forget what we've "seen" so nothing is wrongly flagged as new.
    func filtersChanged() {
        seen = []
        hasLoaded = false
        newIDs = []
        Task {
            while isLoading { try? await Task.sleep(nanoseconds: 100_000_000) }
            await refresh(notify: false)
            reschedule()
        }
    }

    func reschedule() {
        timer?.cancel()
        let minutes = UserDefaults.standard.integer(forKey: Prefs.refreshMinutes)
        guard minutes > 0 else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                await self.refresh(notify: UserDefaults.standard.bool(forKey: Prefs.notify))
            }
        }
    }
}

// MARK: - Notifications

enum Notifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ items: [Item]) {
        guard available, let first = items.first else { return }
        let content = UNMutableNotificationContent()
        content.title = items.count == 1 ? "New on CeX" : "\(items.count) new listings on CeX"
        content.subtitle = [first.title, first.priceText, first.grade.map { "Grade \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
        content.body = first.specs
        content.sound = .default
        content.userInfo = ["id": first.id]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Prefs.register()
        if Notifier.available {
            UNUserNotificationCenter.current().delegate = self
            Notifier.requestAuthorization()
        }
        Task { @MainActor in
            await Store.shared.refresh(notify: false)
            Store.shared.reschedule()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["id"] as? String {
            NSWorkspace.shared.open(CeXAPI.productURL(id))
        }
        completionHandler()
    }
}

@main
struct CeXBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(store)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: store.newIDs.isEmpty ? "bag" : "bag.fill")
                if !store.items.isEmpty { Text("\(store.items.count)") }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var showFilters = false
    @State private var draft = Search()
    @AppStorage(Prefs.refreshMinutes) private var refreshMinutes = 30

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showFilters {
                FiltersView(draft: $draft) { closeFilters() }
            } else {
                results
            }
            Divider()
            footer
        }
        .frame(width: 400)
        .onAppear {
            if let t = store.lastUpdated, Date().timeIntervalSince(t) > 300 {
                Task { await store.refresh(notify: false) }
            }
        }
    }

    private func openFilters() {
        draft = store.search
        showFilters = true
    }

    private func closeFilters() {
        showFilters = false
        store.update(draft)
    }

    private var subtitle: String {
        if showFilters { return "Department, category, attributes, price and stock" }
        var s = store.search.summary
        if let t = store.lastUpdated {
            s += " · " + t.formatted(date: .omitted, time: .shortened)
        }
        return s
    }

    private var headline: String {
        if showFilters { return "Search filters" }
        if store.search.isEmpty { return "CeX Bar" }
        if store.items.isEmpty { return "No matches" }
        return "\(store.items.count)\(store.truncated ? "+" : "") in stock"
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
                .padding(-2)

            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if !showFilters && !store.search.isEmpty {
                if store.isLoading {
                    ProgressView().controlSize(.small).frame(width: 22)
                } else {
                    iconButton("arrow.clockwise", help: "Refresh now") {
                        Task { await store.refresh(notify: false) }
                    }
                }
            }
            iconButton(showFilters ? "xmark" : "slider.horizontal.3",
                       help: showFilters ? "Close filters" : "Filters") {
                if showFilters { closeFilters() } else { openFilters() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var results: some View {
        if store.search.isEmpty {
            VStack(spacing: 10) {
                placeholder(icon: "magnifyingglass", title: "What are you looking for?",
                            detail: "Search for anything on CeX — games, phones, laptops, DVDs — and narrow it down by category, specs, grade, price or store.")
                Button("Set up a search") { openFilters() }
                    .keyboardShortcut(.defaultAction)
                    .padding(.bottom, 16)
            }
        } else if let err = store.error, store.items.isEmpty {
            placeholder(icon: "wifi.exclamationmark", title: "Couldn't reach CeX", detail: err)
        } else if store.items.isEmpty {
            if store.isLoading || store.lastUpdated == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else {
                placeholder(icon: "magnifyingglass", title: "Nothing matches right now",
                            detail: "You'll get a notification when something turns up.")
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.items) { item in
                        ItemRow(item: item, isNew: store.newIDs.contains(item.id))
                    }
                }
                .padding(6)
            }
            .frame(height: min(CGFloat(store.items.count) * 68 + 12, 440))
            if store.truncated {
                Text("CeX has more matches than it will return — narrow the search to see them all.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
            if let err = store.error {
                Text("Last refresh failed: \(err)")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.bottom, 6)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open CeX") { NSWorkspace.shared.open(CeXAPI.searchPageURL(store.search.trimmedQuery)) }
            Spacer()
            Text(refreshMinutes > 0 ? "Checks every \(refreshMinutes) min" : "Auto-refresh off")
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func placeholder(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

struct ItemRow: View {
    let item: Item
    let isNew: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(item.url)
        } label: {
            HStack(spacing: 10) {
                Thumbnail(url: item.imageURL, department: item.department)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if isNew {
                            Text("NEW")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor))
                        }
                    }
                    Text(item.specs)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(item.stockText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(item.priceText)
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                    if let grade = item.grade { GradeBadge(grade: grade) }
                    if let was = item.wasText {
                        Text(was)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.07) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.name + (item.stores.isEmpty ? "" : "\nIn: " + item.stores.joined(separator: ", ")))
    }
}

struct Thumbnail: View {
    let url: URL?
    let department: String

    private var symbol: String {
        switch department {
        case "Phones": return "iphone"
        case "Computing": return "laptopcomputer"
        case "Gaming": return "gamecontroller"
        case "Film & TV": return "film"
        case "Music": return "music.note"
        case "Electronics": return "tv"
        default: return "shippingbox"
        }
    }

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 38, height: 38)
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct GradeBadge: View {
    let grade: String
    private var color: Color {
        switch grade {
        case "A": return .green
        case "B": return .orange
        case "C": return .red
        default: return .gray
        }
    }
    var body: some View {
        Text("Grade \(grade)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// Lays chips out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(width, subviews)
        let height = rows.reduce(0) { $0 + ($1.map { $0.size.height }.max() ?? 0) } + spacing * CGFloat(max(rows.count - 1, 0))
        let used = rows.map { $0.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max($0.count - 1, 0)) }.max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            let h = row.map { $0.size.height }.max() ?? 0
            for (i, size) in row {
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += h + spacing
        }
    }
}

struct Chip: View {
    let label: String
    let count: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label).lineLimit(1)
                if let count {
                    Text("\(count)").foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
                }
            }
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct FiltersView: View {
    @Binding var draft: Search
    var onDone: () -> Void

    @AppStorage(Prefs.refreshMinutes) private var refreshMinutes = 30
    @AppStorage(Prefs.notify) private var notify = true
    @State private var facets = FacetSet()
    @State private var loadingFacets = false
    @State private var facetError: String?
    @State private var expanded: Set<String> = []

    /// Facets only depend on these, so typing in "Exclude" etc. doesn't refetch them.
    private struct FacetQuery: Hashable {
        let query, department, category, minPrice, maxPrice: String
    }
    private var facetQuery: FacetQuery {
        FacetQuery(query: draft.trimmedQuery, department: draft.department, category: draft.category,
                   minPrice: draft.minPrice, maxPrice: draft.maxPrice)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Search", text: $draft.query, prompt: Text("e.g. ps5, iphone 15 pro, macbook pro m4"))
                    Picker("Department", selection: $draft.department) {
                        Text("Any").tag("")
                        ForEach(options(facets.departments, selected: draft.department)) { v in
                            Text(label(v)).tag(v.label)
                        }
                    }
                    Picker("Category", selection: $draft.category) {
                        Text("Any").tag("")
                        ForEach(options(facets.categories, selected: draft.category)) { v in
                            Text(label(v)).tag(v.label)
                        }
                    }
                } header: {
                    HStack {
                        Text("Search")
                        Spacer()
                        if loadingFacets {
                            ProgressView().controlSize(.mini)
                        } else if !draft.isEmpty {
                            Text("\(facets.total.formatted()) in stock").foregroundStyle(.secondary)
                        }
                    }
                }
                .onChange(of: draft.department) { _ in
                    if !draft.category.isEmpty { draft.category = "" }
                }

                attributesSection

                Section("Keywords in the listing name") {
                    TextField("Must contain any of", text: $draft.mustContain, prompt: Text("e.g. M4 Pro, M4 Max"))
                    TextField("Exclude", text: $draft.exclude, prompt: Text("e.g. NTD, Greek, Boxed"))
                }
                Section("Price and stock") {
                    HStack {
                        TextField("Price (£)", text: $draft.minPrice, prompt: Text("Min"))
                        Text("to").foregroundStyle(.secondary)
                        TextField("", text: $draft.maxPrice, prompt: Text("Max"))
                            .labelsHidden()
                    }
                    TextField("Stores", text: $draft.stores, prompt: Text("Any (e.g. Bristol, Kingswood)"))
                    Toggle("Online only", isOn: $draft.onlineOnly)
                    Picker("Sort by", selection: $draft.sort) {
                        ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Updates") {
                    Picker("Check every", selection: $refreshMinutes) {
                        Text("Off").tag(0)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                        Text("3 hours").tag(180)
                    }
                    Toggle("Notify me about new listings", isOn: $notify)
                    Toggle("Open at login", isOn: Binding(
                        get: { SMAppService.mainApp.status == .enabled },
                        set: { on in
                            do {
                                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            } catch {
                                NSLog("CeX Bar login item: \(error.localizedDescription)")
                            }
                        }
                    ))
                }
            }
            .formStyle(.grouped)
            .frame(height: 480)

            HStack {
                Button("Reset") { draft = Search() }
                    .disabled(draft == Search())
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .task(id: facetQuery) { await loadFacets() }
    }

    private func loadFacets() async {
        // Small debounce so typing doesn't fire a request per keystroke; .task(id:) cancels stale ones.
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        loadingFacets = true
        defer { loadingFacets = false }
        do {
            let set = try await CeXAPI.facets(draft)
            if Task.isCancelled { return }
            facets = set
            facetError = nil
        } catch {
            if !Task.isCancelled { facetError = error.localizedDescription }
        }
    }

    /// Keep the current selection in the list even when the new results don't include it.
    private func options(_ values: [FacetValue], selected: String) -> [FacetValue] {
        if selected.isEmpty || values.contains(where: { $0.label == selected }) { return values }
        return [FacetValue(label: selected, count: 0)] + values
    }

    private func label(_ v: FacetValue) -> String {
        v.count > 0 ? "\(v.label) (\(v.count.formatted()))" : v.label
    }

    /// Facets returned for the current results, plus any selected ones that dropped out of them.
    private var shownFacets: [Facet] {
        var list = facets.attributes
        let names = Set(list.map { $0.name })
        for (name, f) in draft.activeAttributes where !names.contains(name) {
            list.insert(Facet(name: name, values: f.values.map { FacetValue(label: $0, count: 0) },
                              numeric: f.values.allSatisfy { measure($0) != nil }), at: 0)
        }
        return list
    }

    @ViewBuilder
    private var attributesSection: some View {
        Section {
            if let facetError {
                Text("Couldn't load filters: \(facetError)").foregroundStyle(.orange)
            } else if draft.isEmpty {
                Text("Type a search or pick a category to see what you can filter on.")
                    .foregroundStyle(.secondary)
            } else if shownFacets.isEmpty && !loadingFacets {
                Text("Nothing else to filter on for these results.").foregroundStyle(.secondary)
            }
            ForEach(shownFacets) { facet in
                facetRow(facet)
            }
        } header: {
            HStack {
                Text("Attributes")
                Spacer()
                if !draft.activeAttributes.isEmpty {
                    Button("Clear") { draft.attributes = [:] }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
        } footer: {
            if !draft.isEmpty && draft.category.isEmpty && !facets.attributes.isEmpty {
                Text("Pick a category for more specific attributes.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func facetRow(_ facet: Facet) -> some View {
        let filter = draft.attributes[facet.name] ?? AttributeFilter()
        let selectedKeys = Set(filter.values.map(facetKey))
        let limit = 12
        let showAll = expanded.contains(facet.name) || facet.values.count <= limit + 2
        // Always show selected values, even past the cut-off.
        let visible = showAll ? facet.values
            : facet.values.enumerated().filter { $0.offset < limit || selectedKeys.contains($0.element.key) }.map { $0.element }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(facetTitle(facet.name))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if facet.numeric && !filter.values.isEmpty {
                    Toggle("and up", isOn: Binding(
                        get: { filter.orMore },
                        set: { draft.attributes[facet.name, default: AttributeFilter()].orMore = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Match the smallest selected value or anything bigger")
                }
            }
            FlowLayout {
                ForEach(visible) { v in
                    Chip(label: v.label, count: v.count > 0 ? v.count : nil, selected: selectedKeys.contains(v.key)) {
                        toggle(v, in: facet.name)
                    }
                }
                if !showAll {
                    Chip(label: "+\(facet.values.count - visible.count) more", count: nil, selected: false) {
                        expanded.insert(facet.name)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func toggle(_ v: FacetValue, in facet: String) {
        var f = draft.attributes[facet] ?? AttributeFilter()
        if let i = f.values.firstIndex(where: { facetKey($0) == v.key }) {
            f.values.remove(at: i)
        } else {
            f.values.append(v.label)
        }
        draft.attributes[facet] = f.values.isEmpty ? nil : f
    }
}

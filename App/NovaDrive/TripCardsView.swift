import ImageIO
import NovaKit
import NovaNav
import NovaPorts
import SwiftUI
import UIKit

/// F-15b §11 (T-040j): the trip list over the bottom of the 导航 map. Not moving: poster cards (number, photo or
/// placeholder, name, district, km, ✕), long-press drag to reorder, a tap opens the details sheet, and the
/// 「串成路线」/「开始导航」 buttons. Moving: one line of numbers and names, no photos and no buttons; taps do nothing.
/// Every edit is a `TripTap` through the voice path's executor (I-6).
struct TripCardsView: View {
    @ObservedObject var model: DriveModel
    let runtime: AgentRuntime

    var body: some View {
        // F-15b §52 item 9 (T-040zc): shown while the plan has any stop; the day in front only picks the cards.
        switch TripScreen.of(plan: model.tripPlan, moving: model.tripMoving) {
        case .none:
            // §16 item 6: the saved plans stay reachable with an empty current plan (not moving).
            if !model.tripMoving, let plans = model.tripPlans, !plans.saved.isEmpty {
                HStack {
                    plansButton
                    Spacer()
                }
            }
        case .strip where model.tripCardsHidden:
            // §22 item 1: no strip while the cards are put away (and no 「行程」 button: taps do nothing while moving).
            EmptyView()
        case .strip(let text):
            Text(text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
                .accessibilityIdentifier("trip-strip")
                // F-09b §16 item 1 (T-031z): the trip on screen (the strip while moving).
                .panelClose(.tripScreen, runtime)
                .screenPanel(.tripScreen)
        case .cards where model.tripCardsHidden, .emptyDay where model.tripCardsHidden:
            // §22 item 1: one 「行程」 button; a tap is the current day's read (shows the cards again).
            HStack {
                Button("行程") { Task { await runtime.tripTap(.day(model.tripPlans?.currentDay ?? 1)) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("trip-show")
                Spacer()
            }
        case .emptyDay:
            // §52 item 9: an empty day is still the trip screen: every day tab and 「这一天还没有安排」.
            VStack(alignment: .leading, spacing: 6) {
                topRow
                Text(TripScreen.emptyDayText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .accessibilityIdentifier("trip-empty-day")
                HStack { Spacer(); plansButton }.font(.subheadline)
            }
            .screenPanel(.tripScreen)
        case .cards(let cards):
            VStack(alignment: .leading, spacing: 6) {
                topRow
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(cards) { card in
                            // §21 item 1: a plain Button (a tap gesture next to .draggable in the ScrollView never fired).
                            Button { Task { await runtime.openTripDetail(card) } } label: {
                                TripCardView(card: card) { Task { await runtime.tripTap(.remove(index: card.index)) } }
                            }
                            .buttonStyle(.plain)
                                // §13 item 2: long-press and drag; the drop is one move.
                                .draggable(String(card.index))
                                .dropDestination(for: String.self) { items, _ in
                                    guard let from = items.first.flatMap({ Int($0) }), from != card.index else { return false }
                                    Task { await runtime.tripTap(.move(from: from, to: card.index)) }
                                    return true
                                }
                                .accessibilityIdentifier("trip-card-\(card.index)")
                        }
                    }
                    .padding(.horizontal, 2)
                }
                HStack(spacing: 8) {
                    // F-15b §29 item 4: one button to the next stop not visited or skipped (`trip_next`); §57 item 2
                    // (T-040zj): with its icon, apart from the cards, and 「结束导航」 in the same spot while navigating.
                    // F-15b §66 item 6 (T-040zs): named after the stop `trip_next` goes to (on the map; an event with no
                    // venue offers no navigation).
                    switch TripScreen.navButton(nextStop: model.tripList.stops.first(where: { $0.mark == nil && $0.placed })?.place.name,
                                                navigating: model.nav.navigating) {
                    case .some(.next(let name)):
                        Button { Task { await runtime.tripTap(.next) } } label: {
                            Label("去下一站：\(name)", systemImage: "location.north.line.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .lineLimit(1)
                        .accessibilityIdentifier("trip-next")
                        .screenPanel(.tripNextButton)
                    case .some(.stop):
                        Button { Task { await runtime.stopNavigationTap() } } label: {
                            Label("结束导航", systemImage: "xmark.circle").frame(minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .accessibilityIdentifier("trip-stop")
                        .screenPanel(.stopNavigationButton)
                    case .none:
                        EmptyView()
                    }
                    Spacer()
                    plansButton
                }
                .font(.subheadline)
                // §57 item 2: at least 12 pt below the card row.
                .padding(.top, 12)
            }
            // F-09b §16 item 1 (T-031z): the trip cards on screen.
            .screenPanel(.tripScreen)
        }
    }
}

extension TripCardsView {
    /// F-09b §22 item 3 (T-031zg): the day tabs, then the panel's 「×」 at the right, in its own row above the cards so
    /// it never covers a card's per-stop ✕.
    private var topRow: some View {
        HStack(spacing: 6) {
            dayTabs
            Spacer(minLength: 0)
            PanelCloseButton(panel: .tripScreen, runtime: runtime)
        }
    }

    /// §11 item 5 with §52 item 9: a tab for every day of the plan; a tap only changes the day in front.
    @ViewBuilder private var dayTabs: some View {
        if model.tripPlan.dayCount > 1 {
            HStack(spacing: 6) {
                ForEach(1...model.tripPlan.dayCount, id: \.self) { day in
                    // F-15b §64 item 1 (T-040zq): 「第1天 · 11月25日 周三」 with a start date.
                    Button(TripDayLabel.text(day: day - 1, asked: model.tripPlan.asked)) { Task { await runtime.tripTap(.day(day)) } }
                        .buttonStyle(.bordered)
                        .tint(day == model.tripPlan.currentDay ? .blue : .gray)
                        .accessibilityIdentifier("trip-day-\(day)")
                }
            }
            .font(.caption)
        }
    }

    private var plansButton: some View {
        Button("我的行程") { model.tripPlansOpen = true }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("trip-plans")
    }
}

/// F-15b §16 item 6 (T-040l): the saved plans with name, days and stop count. A tap opens one; a swipe deletes one
/// after a confirm on screen. Not offered while moving (the sheet closes when moving starts).
struct TripPlansSheet: View {
    @ObservedObject var model: DriveModel
    let runtime: AgentRuntime
    @State private var deleting: TripPlansSummary.Saved?

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.tripPlans?.saved ?? []) { plan in
                    Button {
                        model.tripPlansOpen = false
                        Task { await runtime.tripTap(.openPlan(plan.name)) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(plan.name).font(.headline)
                            Text("\(plan.days)天 · \(plan.stops)个地点").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { deleting = plan }
                    }
                }
            }
            .overlay {
                if model.tripPlans?.saved.isEmpty ?? true { Text("还没有存过行程").foregroundStyle(.secondary) }
            }
            .navigationTitle("我的行程")
            .toolbar { Button("完成") { model.tripPlansOpen = false } }
            .confirmationDialog("删除这个行程？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("删除「\(deleting?.name ?? "")」", role: .destructive) {
                    if let name = deleting?.name { Task { await runtime.tripTap(.deletePlan(name)) } }
                    deleting = nil
                }
            }
        }
        .onChange(of: model.tripMoving) { _, moving in if moving { model.tripPlansOpen = false } }
    }
}

/// F-15b §14: `Application Support/trip/`, atomic writes with complete-until-first-unlock protection, excluded from
/// backup; a bad file is moved aside, not deleted.
struct AppTripFiles: TripFiles {
    private var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("trip", isDirectory: true)
    }

    func read(_ name: String) -> Data? {
        guard let directory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    func write(_ name: String, _ data: Data) {
        guard var directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        try? data.write(to: directory.appendingPathComponent(name),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func moveAside(_ name: String) {
        guard let directory else { return }
        let from = directory.appendingPathComponent(name)
        let to = directory.appendingPathComponent(name.replacingOccurrences(of: ".json", with: ".bad.json"))
        try? FileManager.default.removeItem(at: to)
        try? FileManager.default.moveItem(at: from, to: to)
    }
}

/// §11 item 2: one poster card.
private struct TripCardView: View {
    let card: TripCard
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                TripPhotoView(url: card.photoURL, kind: card.kind)
                    .frame(width: 132, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("\(card.index)")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                    .padding(4)
                HStack {
                    Spacer()
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .accessibilityLabel("去掉第\(card.index)个")
                    .accessibilityIdentifier("trip-remove-\(card.index)")
                }
                .padding(4)
            }
            // F-15b §37 item 8 (T-040o): 住 / 机场, a small label under the poster.
            if let tag = card.tag { Text(tag).font(.caption2.bold()).foregroundStyle(.orange) }
            // F-18 §43 item 4, §44 item 3: 「网络图片」 under a searched picture, 「未找到图片」 when the event has none.
            if let note = card.imageNote { Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            Text(card.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            // F-15b §67 item 4 (T-040zt): the map's place name under the stop's name when they differ.
            if let place = card.place { Text(place).font(.caption2).lineLimit(1) }
            // F-15b §64 item 6 (T-040zq): the event at this venue and its open dates.
            if let event = card.event { Text(event).font(.caption2).foregroundStyle(.purple).lineLimit(1) }
            HStack(spacing: 4) {
                if let district = card.district { Text(district) }
                if let km = card.km { Text(String(format: "%.1f 公里", km)) }
                if let minutes = card.minutes { Text("车程\(minutes)分钟") }
                if card.mark == .visited { Text("已到").foregroundStyle(.green) }
                if card.mark == .skipped { Text("跳过").foregroundStyle(.secondary) }
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 132)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .opacity(card.passed ? 0.5 : 1)
    }
}

/// §12: the place photo, or the §46 item 6 placeholder (the kind's icon on a soft two-colour gradient).
struct TripPhotoView: View {
    let url: URL?
    let kind: PlaceKind
    @State private var image: UIImage?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                let pair = TripKindTheme.colors(kind, dark: scheme == .dark)
                Rectangle().fill(LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: kind.symbol).font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .task(id: url) {
            image = nil
            guard let url, let data = await TripPhotoStore.shared.jpeg(url, maxPixels: 132 * 2 * 3) else { return }
            image = UIImage(data: data)
        }
    }
}

/// §12 item 4: downsampled to twice the card size before they are kept; 32 in memory, `Caches/TripPhotos` at most
/// 20 MB on disk, oldest removed first. A failed download shows the placeholder and is tried again at most once per
/// launch. Saved plans keep the link, not the image.
actor TripPhotoStore {
    static let shared = TripPhotoStore()

    private let memory: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.countLimit = TripPhotoCachePolicy.memoryCount
        return cache
    }()
    private var failures: [URL: Int] = [:]

    private var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("TripPhotos")
    }

    /// The downsampled JPEG for `url` (Data crosses the actor boundary; the view makes the image).
    func jpeg(_ url: URL, maxPixels: Int) async -> Data? {
        if let hit = memory.object(forKey: url as NSURL) { return hit as Data }
        let file = directory?.appendingPathComponent(Self.fileName(url))
        if let file, let data = try? Data(contentsOf: file) {
            memory.setObject(data as NSData, forKey: url as NSURL)
            return data
        }
        guard url.scheme == "https", (failures[url] ?? 0) < 2 else { return nil }
        guard let fetched = try? await URLSession.shared.data(from: url),
              (fetched.1 as? HTTPURLResponse)?.statusCode == 200,
              let small = Self.downsample(fetched.0, maxPixels: maxPixels) else {
            failures[url, default: 0] += 1
            return nil
        }
        memory.setObject(small as NSData, forKey: url as NSURL)
        if let file { store(small, at: file) }
        return small
    }

    private func store(_ data: Data, at file: URL) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        let entries = files.compactMap { url -> TripPhotoCachePolicy.Entry? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return TripPhotoCachePolicy.Entry(name: url.lastPathComponent, bytes: values.fileSize ?? 0,
                                              added: values.creationDate ?? .distantPast)
        }
        for name in TripPhotoCachePolicy.evict(entries) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func downsample(_ data: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
    }

    /// A stable file name for the link (FNV-1a), so the disk cache survives launches.
    private static func fileName(_ url: URL) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16) + ".jpg"
    }
}

/// §11 item 6: photo, address, opening hours and phone from the place detail; nothing is spoken.
struct TripDetailSheet: View {
    let card: TripCard
    let place: Place?
    /// False once the detail lookup ended without a place (failed, or a saved 家/公司 stop).
    let loading: Bool
    /// §21 item 2: nil while looking up.
    let intro: TripIntro.Answer?

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 10) {
            TripPhotoView(url: place?.photoURL ?? card.photoURL, kind: card.kind)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("\(card.index) \(card.name)").font(.title3.weight(.bold))
            if let mapName = card.place { Text(mapName).font(.subheadline).foregroundStyle(.secondary) }
            // §21 items 2, 4: 「介绍」 under the name; none for a saved 家/公司 stop.
            if !card.placeID.hasPrefix("saved_") {
                Text("介绍").font(.headline)
                switch intro {
                case .text(let text)?: Text(text)
                case .failed?: Text("没有查到介绍").foregroundStyle(.secondary)
                case .none?: EmptyView()
                case nil: Text("正在查介绍…").foregroundStyle(.secondary)
                }
            }
            if let place {
                if let address = place.address { Label(address, systemImage: "mappin.and.ellipse") }
                if let hours = place.openingHours { Label(hours, systemImage: "clock") }
                if let phone = place.phone { Label(phone, systemImage: "phone") }
            } else if loading {
                ProgressView()
            } else {
                Text("没有查到详情").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .padding() }
        .presentationDetents([.medium, .large])
    }
}

/// §46 item 6 (T-040r): the placeholder's gradient colour pair per kind of place, light and dark.
enum TripKindTheme {
    /// (hue 0–360, saturation, brightness) of the gradient's first colour; the second is shifted by 30°.
    private static func base(_ kind: PlaceKind) -> (Double, Double, Double) {
        switch kind {
        case .temple: return (20, 0.45, 0.85)
        case .tower: return (210, 0.45, 0.85)
        case .park: return (130, 0.40, 0.75)
        case .museum: return (270, 0.35, 0.80)
        case .hotel: return (40, 0.40, 0.85)
        case .airport: return (195, 0.45, 0.85)
        case .rental: return (0, 0.40, 0.80)
        case .shop: return (320, 0.35, 0.85)
        case .food: return (30, 0.50, 0.90)
        case .other: return (220, 0.15, 0.70)
        }
    }

    static func colors(_ kind: PlaceKind, dark: Bool) -> (Color, Color) {
        let (hue, saturation, brightness) = base(kind)
        let b = dark ? brightness * 0.6 : brightness
        let first = Color(hue: hue / 360, saturation: saturation, brightness: b)
        let second = Color(hue: (hue + 30).truncatingRemainder(dividingBy: 360) / 360, saturation: saturation * 0.8,
                           brightness: b * 0.9)
        return (first, second)
    }
}

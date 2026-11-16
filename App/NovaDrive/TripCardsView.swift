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
        switch TripScreen.of(model.tripList, passed: model.nav.tripStopsPassed, moving: model.tripMoving) {
        case .none:
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
        case .cards(let cards):
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(cards) { card in
                            TripCardView(card: card) { Task { await runtime.tripTap(.remove(index: card.index)) } }
                                .onTapGesture { Task { await runtime.openTripDetail(card) } }
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
                    if model.tripList.count >= 2 {
                        Button("串成路线") { Task { await runtime.tripTap(.route(start: false)) } }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("trip-route")
                    }
                    if model.nav.tripRoute && model.nav.phase == .awaitingRouteSelection {
                        Button("开始导航") { Task { await runtime.tripTap(.route(start: true)) } }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("trip-start")
                    }
                    Spacer()
                }
                .font(.subheadline)
            }
        }
    }
}

/// §11 item 2: one poster card.
private struct TripCardView: View {
    let card: TripCard
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                TripPhotoView(url: card.photoURL, initial: card.initial)
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
            Text(card.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack(spacing: 4) {
                if let district = card.district { Text(district) }
                if let km = card.km { Text(String(format: "%.1f 公里", km)) }
                if card.passed { Text("已到").foregroundStyle(.green) }
            }
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 132)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .opacity(card.passed ? 0.5 : 1)
    }
}

/// §12: the place photo, or the placeholder (the name's first character on a plain colour).
struct TripPhotoView: View {
    let url: URL?
    let initial: String
    @State private var image: UIImage?

    /// A plain colour fixed by the character, the same on every launch.
    private var tint: Color {
        let value = initial.unicodeScalars.first.map { Int($0.value) } ?? 0
        return Color(hue: Double(value % 360) / 360, saturation: 0.35, brightness: 0.85)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(tint)
                Text(initial).font(.largeTitle.weight(.bold)).foregroundStyle(.white)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TripPhotoView(url: place?.photoURL ?? card.photoURL, initial: card.initial)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("\(card.index) \(card.name)").font(.title3.weight(.bold))
            if let place {
                if let address = place.address { Label(address, systemImage: "mappin.and.ellipse") }
                if let hours = place.openingHours { Label(hours, systemImage: "clock") }
                if let phone = place.phone { Label(phone, systemImage: "phone") }
            } else {
                ProgressView()
            }
            Spacer()
        }
        .font(.subheadline)
        .padding()
        .presentationDetents([.medium])
    }
}

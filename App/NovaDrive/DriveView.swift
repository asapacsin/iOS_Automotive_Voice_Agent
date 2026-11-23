import MapKit
import NovaAgent
import NovaKit
import NovaNav
import NovaPlatform
import NovaPorts
import NovaServices
import NovaTools
import NovaVoice
import SwiftUI

/// The product screen: status chip, map with routes, choice list, HUD, simulated car and both voices' lines.
struct DriveView: View {
    @StateObject private var holder = RuntimeHolder.shared
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(DriveSettings.demoOrigin), latitudinalMeters: 6_000, longitudinalMeters: 6_000))

    private var model: DriveModel { holder.runtime.model }

    var body: some View {
        DriveContent(model: holder.runtime.model, position: holder.runtime.mapPosition, camera: $camera,
                     toggle: { Task { model.running ? holder.runtime.stop() : await holder.runtime.start() } },
                     runtime: holder.runtime)
    }
}

/// Hosts the camera preview layer from NovaPlatform (the app does not import AVFoundation).
private struct CameraPreview: UIViewRepresentable {
    let session: CameraSession

    final class Host: UIView {
        var preview: CALayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            preview?.frame = bounds
        }
    }

    func makeUIView(context: Context) -> Host {
        let view = Host()
        let layer = session.makePreviewLayer()
        view.layer.addSublayer(layer)
        view.preview = layer
        return view
    }

    func updateUIView(_ view: Host, context: Context) {}
}

/// F-20a floating window: live camera, 问一下 and ×; drag to any corner. F-20b: 前方/后方 label and switch.
private struct CameraWindow: View {
    @ObservedObject var model: DriveModel
    let runtime: AgentRuntime
    @State private var corner: Alignment = .topTrailing
    @State private var drag: CGSize = .zero
    private let canSwitch: Bool

    init(model: DriveModel, runtime: AgentRuntime) {
        self.model = model
        self.runtime = runtime
        canSwitch = runtime.camera.hasRearLens
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * 0.4
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    CameraPreview(session: runtime.camera)
                        .frame(width: width, height: width * 0.75)
                    Button { runtime.closeCamera() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.white, .black.opacity(0.5))
                    }
                    .padding(4)
                    .accessibilityIdentifier("camera-close")
                    Text(model.cameraLens == .rearView ? "后方" : "前方").font(.caption2.weight(.semibold)).padding(.horizontal, 6)
                        .padding(.vertical, 2).background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(6)
                        .accessibilityIdentifier("camera-lens")
                    if model.cameraAsking {
                        Text("看画面中…").font(.caption2).padding(4)
                            .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(4)
                    }
                }
                HStack {
                    Text(model.cameraAnswer ?? " ").font(.caption2).lineLimit(3)
                    Spacer(minLength: 4)
                    Button { Task { await runtime.switchCamera() } } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                    }
                    .font(.caption.weight(.semibold)).buttonStyle(.bordered)
                    .disabled(!canSwitch || model.cameraSwitching)
                    .accessibilityLabel(model.cameraLens == .rearView ? "切换到前方" : "切换到后方")
                    .accessibilityIdentifier("camera-switch")
                    Button("问一下") { Task { await runtime.tapAsk() } }
                        .font(.caption.weight(.semibold)).buttonStyle(.bordered)
                        .disabled(model.cameraAsking)
                        .accessibilityIdentifier("camera-ask")
                }
                .padding(6)
                .frame(width: width)
                .background(.regularMaterial)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 4)
            .offset(drag)
            .gesture(DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    let right = value.location.x > proxy.size.width / 2
                    let bottom = value.location.y > proxy.size.height / 2
                    corner = bottom ? (right ? .bottomTrailing : .bottomLeading) : (right ? .topTrailing : .topLeading)
                    drag = .zero
                })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
            .animation(.easeOut(duration: 0.2), value: corner)
        }
        .padding(.top, 70)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .accessibilityIdentifier("camera-window")
    }
}

@MainActor
final class RuntimeHolder: ObservableObject {
    /// One runtime for the phone screen.
    static let shared = RuntimeHolder()
    let runtime = AgentRuntime()
}

/// F-13 §14 item 7 (T-032b): the playing iTunes preview, with the attribution and the store link.
private struct PreviewCardView: View {
    let card: PreviewCard
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: card.artworkURL) { $0.resizable() } placeholder: { Color.gray.opacity(0.3) }
                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let artist = card.artist { Text(artist).font(.caption).lineLimit(1) }
                Text(PreviewCard.attribution).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let store = card.storeURL {
                Button("在 Apple Music 中打开") { openURL(store) }.font(.caption.weight(.semibold)).buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("preview-card")
    }
}

private struct DriveContent: View {
    @ObservedObject var model: DriveModel
    @ObservedObject var position: MapPositionModel
    @Binding var camera: MapCameraPosition
    /// Camera changes until then were commanded by the policy, not made by the driver.
    @GestureState private var dragging = false
    @GestureState private var magnifying = false
    @State private var visible = false
    let toggle: () -> Void
    let runtime: AgentRuntime
    @Environment(\.scenePhase) private var scenePhase
    @State private var bubble = BubbleFade()
    @AppStorage(DriveSettings.useDeviceLocation) private var useDeviceLocation = true
    /// F-01 §14 item 6: 「唤醒词」 changed in 设置: the listener is applied again.
    @AppStorage(DriveSettings.wakeWord) private var wakeWord = true

    var body: some View {
        ZStack(alignment: .top) {
            map.ignoresSafeArea()
            VStack(spacing: 8) {
                header
                if model.nav.navigating { hud }
                Spacer()
                if model.nav.listOpen || model.nav.phase == .calculatingRoute || model.nav.phase == .resolvingDestination {
                    choices
                }
                // F-15b §50 item 6 (T-040w): the steps while she works, where 「正在搜索地点…」 shows.
                workSteps
                // F-15b §11 (T-040j): the trip list's cards, or the strip while moving.
                TripCardsView(model: model, runtime: runtime)
                if let card = model.previewCard { PreviewCardView(card: card).screenPanel(.musicCard) }
                // F-09b §19 item 3 (T-031zd): the pin's small card; no 导航 button, no route.
                if let pin = model.mapPin { mapPinCard(pin) }
                conversation
                locateRow
                carCard
                talkButton
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            if model.cameraOpen { CameraWindow(model: model, runtime: runtime).screenPanel(.camera) }
        }
        // F-15b §11 item 6: a card's details, not moving only.
        .sheet(item: $model.tripDetail) { card in TripDetailSheet(card: card, place: model.tripDetailPlace, loading: model.tripDetailLoading, intro: model.tripIntro).screenPanel(.tripDetail) }
        // T-044c: 我的位置 and the camera follow the policy (F-16b); the view only applies its commands.
        .onChange(of: model.geometry) { _, geometry in position.navigation(model.nav, geometry: geometry) }
        .onChange(of: model.nav) { _, flow in
            position.navigation(flow, geometry: model.geometry)
            // F-09b §19 item 5 (T-031zd): a navigate_to that lists places takes the pin away.
            if model.mapPin != nil, MapPin.kept(model.mapPin, after: flow) == nil { model.mapPin = nil }
        }
        .onChange(of: model.mapPin) { _, pin in position.mapPin(pin?.coordinate) }
        .onChange(of: position.command) { _, command in if let command { apply(command.command) } }
        .onChange(of: useDeviceLocation) { _, _ in position.sourceChanged() }
        .onChange(of: wakeWord) { _, _ in Task { await runtime.refreshWake() } }
        .onAppear {
            visible = true
            position.appear()
            position.navigation(model.nav, geometry: model.geometry)
        }
        .onDisappear {
            visible = false
            position.disappear()
        }
        // F-20a §5: the camera never runs in the background.
        .task {
            if UITestDrive.enabled {
                await runtime.startUITestDrive()
            } else {
                await runtime.prepareTrip()
                await runtime.refreshWake()
            }
        }
        // F-15b §16 item 6: 「我的行程」.
        .sheet(isPresented: $model.tripPlansOpen) { TripPlansSheet(model: model, runtime: runtime).screenPanel(.tripPlans) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && model.cameraOpen { runtime.closeCamera() }
            // F-16b §9: 我的位置 streams only while the drive screen is visible, not in the background.
            if phase == .background { position.disappear() } else if phase == .active && visible { position.appear() }
            let mapped: AppScenePhase = switch phase {
            case .background: .background
            case .inactive: .inactive
            default: .foreground
            }
            Task { await runtime.sceneChanged(mapped) }
        }
    }

    // MARK: Map

    private var presentation: MapPresentation { MapPresentation(model.nav) }

    private var map: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            // T-044: only what the flow allows is drawn (offered or chosen routes; nothing after 算了).
            ForEach(model.geometry.routes.filter { presentation.routes.contains($0.summary.id) }, id: \.summary.id) { route in
                let selected = route.summary.id == model.geometry.selected
                MapPolyline(coordinates: route.points.map { CLLocationCoordinate2D($0) })
                    .stroke(selected ? Color.blue : Color.gray.opacity(0.6), lineWidth: selected ? 7 : 4)
            }
            // F-16b: one 我的位置 marker; while navigating it is the simulated car (OQ-MAP-2). GCJ-02 like the
            // routes, so MapKit's own user annotation is not used.
            if let marker = position.position.marker {
                let point = CLLocationCoordinate2D(marker.coordinate)
                if let radius = marker.accuracyRadiusMeters {
                    let tint = marker.style == .provisional ? Color.gray : Color.blue
                    MapCircle(center: point, radius: radius)
                        .foregroundStyle(tint.opacity(0.15))
                        .stroke(tint.opacity(0.4), lineWidth: 1)
                }
                Annotation(marker.caption ?? "", coordinate: point) {
                    SelfMarker(marker: marker).accessibilityIdentifier("self-position")
                }
            }
            // F-09b §19 item 3 (T-031zd): the one green pin show_on_map drew.
            if let pin = model.mapPin {
                Marker(pin.name, coordinate: CLLocationCoordinate2D(pin.coordinate)).tint(.green)
            }
            if let destination = presentation.destination {
                Marker(destination.name, coordinate: CLLocationCoordinate2D(destination.coordinate)).tint(.red)
            }
            ForEach(Array(presentation.markers.enumerated()), id: \.offset) { index, place in
                Marker("\(index + 1) \(place.name)", coordinate: CLLocationCoordinate2D(place.coordinate)).tint(.orange)
            }
            // F-15b §13 item 5: numbered pins at the stops; 途经k and 终点 on a trip route; passed stops greyed.
            // Labels and grey only when the list's stops are the trip route's (an opened plan or another day is not).
            // F-15b §22 item 1: no trip pins while the cards are put away.
            // F-15b §29 item 4: numbered pins, no 途经 labels; visited and skipped stops greyed.
            ForEach(model.tripCardsHidden ? [] : TripPin.pins(model.tripList)) { pin in
                Annotation(pin.label, coordinate: CLLocationCoordinate2D(pin.coordinate)) {
                    Text("\(pin.index)")
                        .font(.caption.weight(.heavy)).foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(pin.passed ? Color.gray : Color.purple, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
        }
        // A pan or zoom by the driver's finger stops following (C7). Touches are watched directly, so the
        // map's own load, layout and commanded moves never count as a gesture. Rotation is off (the arrow
        // is drawn against north).
        .simultaneousGesture(DragGesture(minimumDistance: 8).updating($dragging) { _, touching, _ in touching = true })
        .simultaneousGesture(MagnifyGesture().updating($magnifying) { _, touching, _ in touching = true })
        // A touch beginning stops following; its end (or cancel) restarts the 15 s auto-recenter (C8). Gesture state
        // resets itself when a touch is cancelled, so the next touch always counts.
        .onChange(of: dragging) { position.userGesture() }
        .onChange(of: magnifying) { position.userGesture() }
        // F-15b §47 item 8: OSRM / OpenStreetMap attribution in small text while an OSRM route is used.
        .overlay(alignment: .bottomLeading) {
            if let attribution = model.geometry.attribution, !model.geometry.routes.isEmpty {
                Text(attribution)
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
                    .padding(6)
                    .accessibilityIdentifier("route-attribution")
            }
        }
    }

    /// F-09b §19 item 3: name, 「<district>，距离 N 公里」 and a 「×」 through the same close as 「关掉」 (I-6).
    private func mapPinCard(_ pin: MapPin) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "mappin.circle.fill").foregroundStyle(.green).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(pin.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                if !pin.detail.isEmpty { Text(pin.detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button { runtime.closePanel(.mapPin) } label: {
                Image(systemName: "xmark").font(.subheadline.weight(.bold)).padding(6)
            }
            .accessibilityLabel("关掉地图标记")
            .accessibilityIdentifier("map-pin-close")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("map-pin-card")
        .screenPanel(.mapPin)
    }

    /// Applies a `MapCameraPolicy` command; the resulting camera change is not a driver gesture.
    private func apply(_ command: MapCameraPolicy.Command) {
        switch command {
        case .center(let point, let span):
            withAnimation(.linear(duration: 0.8)) {
                camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(point), latitudinalMeters: span,
                                                    longitudinalMeters: span))
            }
        case .fitContent:
            // T-044 framing: the listed places (also along the route), else the routes on offer.
            var points = presentation.list == .places ? presentation.markers.map(\.coordinate) : []
            if points.isEmpty {
                points = model.geometry.routes.filter { presentation.routes.contains($0.summary.id) }.flatMap(\.points)
            }
            guard !points.isEmpty else { return }
            let lats = points.map(\.latitude), lngs = points.map(\.longitude)
            let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                                longitude: (lngs.min()! + lngs.max()!) / 2)
            let span = MKCoordinateSpan(latitudeDelta: (lats.max()! - lats.min()!) * 1.6 + 0.01,
                                        longitudeDelta: (lngs.max()! - lngs.min()!) * 1.6 + 0.01)
            withAnimation { camera = .region(MKCoordinateRegion(center: center, span: span)) }
        case .frame(let points):
            // F-09b §19 item 4 (T-031zd): the car and the pin together, the `fitContent` margin.
            guard !points.isEmpty else { return }
            let lats = points.map(\.latitude), lngs = points.map(\.longitude)
            let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                                longitude: (lngs.min()! + lngs.max()!) / 2)
            let span = MKCoordinateSpan(latitudeDelta: (lats.max()! - lats.min()!) * 1.6 + 0.01,
                                        longitudeDelta: (lngs.max()! - lngs.min()!) * 1.6 + 0.01)
            withAnimation { camera = .region(MKCoordinateRegion(center: center, span: span)) }
        }
    }

    /// 定位未开启 pill and 回到我的位置 (F-16b §2), bottom-right above the car card.
    private var locateRow: some View {
        HStack {
            if position.locate.showsPermissionPill {
                Button("定位未开启") { position.openSettings() }
                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("location-off")
            }
            Spacer()
            Button { position.locateMe() } label: {
                Image(systemName: position.locate.icon.rawValue)
                    .font(.title3).frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("回到我的位置")
            .accessibilityIdentifier("locate-me")
        }
    }

    // MARK: Header and HUD

    private var header: some View {
        HStack {
            Text("小诺").font(.headline)
            chip
            Button { Task { await runtime.toggleCamera() } } label: {
                Image(systemName: model.cameraDenied ? "camera.slash.fill" : "camera.fill")
                    .foregroundStyle(model.cameraOpen ? .blue : .primary)
            }
            .accessibilityIdentifier("camera-button")
            Spacer()
            if !useDeviceLocation {
                // F-16a: a viewer is never misled about where the car is.
                Text("演示位置")
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .accessibilityIdentifier("demo-location")
            }
            Text(model.nav.navigating && model.nav.mode == .emulator ? "模拟行驶" : "模拟车辆")
                .font(.caption2).padding(.horizontal, 6).padding(.vertical, 3)
                .background(.yellow.opacity(0.85), in: Capsule())
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var chip: some View {
        // F-04 §14 item 4: while she talks the microphone is ignored; when she stops it is the driver's turn.
        let state: (String, Color) = switch model.view.chip {
        case .idle: (model.running ? "待命" : "未开始", .gray)
        case .processing: ("思考中", .orange)
        case .listening: ("请说", .green)
        case .speaking: ("说话中", .blue)
        case .error: ("出错 \(model.view.configError?.rawValue ?? "")", .red)
        }
        // F-24 §14 items 3–4: no network is not an error.
        let network: (String, Color)? = if model.networkEnded && !model.running {
            // F-24 §15 item 6 (T-016j): after giving up or the offline cap.
            (SessionEndedChip.text(wakeArmed: model.wakeArmed), .red)
        } else if model.view.waitingForNetwork && model.running {
            ("等待网络…", .orange)
        } else if model.running, model.connectionShow == .reconnecting {
            // F-24 §17 item 2 (T-016o): a retryable drop, after 1 s.
            (ConnectionNotice.reconnectingText, .orange)
        } else if model.running, model.connectionShow == .back {
            // F-24 §17 item 3: for 3 s after the next setupComplete.
            (ConnectionNotice.backText, .green)
        } else { nil }
        // F-04b §6 item 11 (T-013e): 声纹锁定 failed closed.
        let speaker: (String, Color)? = model.speakerUnavailable && model.running
            ? (SpeakerLockPolicy.unavailableChip, .red) : nil
        // F-04b §14 item 8 (T-013h): a dropped sentence (session) or wake word (idle), 3 s; the item 11 chip wins.
        let dropped: (String, Color)? = speaker == nil ? model.speakerNotice.map { ($0, Color.orange) } : nil
        let (text, color) = network ?? speaker ?? dropped ?? (model.sheTalks && model.running ? ("她在说话", Color.blue) : state)
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 0) {
                Text(text).font(.subheadline.weight(.semibold))
                if model.sheTalks && model.stopHint && model.running {
                    Text("说「别说了」可打断").font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("stop-hint")
                }
                // F-01 §14 item 8: only while the wake listener is armed and no session runs.
                if let hint = WakePhrase.hint(armed: model.wakeArmed, sessionRunning: model.running) {
                    Text(hint).font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("wake-hint")
                }
            }
            backgroundWorkCaption
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
        .onTapGesture { if model.networkEnded && !model.running { Task { await runtime.start() } } }
        .accessibilityIdentifier("status-chip")
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.85), in: Capsule())
    }

    /// F-17 panel from `HUDPanelModel`; the limit stays hidden until an engine reports one (limit 0 = no data).
    private var hud: some View {
        let panel = HUDPanelModel(destinationName: model.nav.destination?.name ?? "", naviInfo: model.nav.info,
                                  lastGuidance: model.nav.lastGuidance, speedLimitKmh: model.nav.info?.facilityLimitKmh ?? 0)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(panel.title).font(.headline)
                // F-15a §2.3: a simulation is never mistaken for guidance; §5: rerouting keeps navigating.
                if model.nav.mode == .emulator { badge("模拟导航", .yellow).accessibilityIdentifier("hud-simulated") }
                if model.nav.rerouting { badge("重新规划中", .orange).accessibilityIdentifier("hud-rerouting") }
                Spacer()
                // F-15b §57 item 1 (T-040zj): the stop button in the guidance panel's top row.
                stopNavigationButton
            }
            if let status = panel.statusText {
                Text(status).font(.subheadline)
            }
            if let step = panel.stepDistanceText {
                HStack(spacing: 6) {
                    if let turn = panel.turn { Text(turn.arrow).font(.title2.weight(.bold)) }
                    Text([step, panel.turn?.word].compactMap { $0 }.joined(separator: " ")).font(.title3.weight(.semibold))
                    if let road = panel.nextRoadText { Text(road).font(.subheadline) }
                }
            }
            HStack {
                if let remaining = panel.remainingText { Text(remaining).font(.subheadline) }
                Spacer()
                if let limit = panel.speedLimitText {
                    Text(limit).font(.caption.weight(.bold)).padding(4)
                        .background(Circle().stroke(.red, lineWidth: 2))
                }
            }
            if let guidance = panel.lastGuidance {
                Text(guidance).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            // F-15a §2.5 (I-6): a tap on another route changes to it, like 「换第N条」.
            if !model.nav.routeTapTargets.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.nav.routeTapTargets, id: \.row) { alternative in
                        Button("换 " + alternative.text) { Task { await runtime.tapChoice(row: alternative.row) } }
                            .font(.caption).buttonStyle(.bordered)
                            .accessibilityIdentifier("hud-alternative-\(alternative.row)")
                    }
                }
                // F-09b §16 item 1: the route choice over the running guidance is routePicking too.
                .screenPanel(.routePicking)
            }
        }
        .accessibilityIdentifier("hud-panel")
        // F-09b §16 item 1 (T-031z): the guidance panel.
        .screenPanel(.navigation)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// F-15b §57 item 1 (T-040zj): 「结束导航」, a red bordered button of at least 44 × 44 pt; a tap is
    /// `exit_navigation_mode`, while moving too, with no confirmation.
    private var stopNavigationButton: some View {
        Button { Task { await runtime.stopNavigationTap() } } label: {
            Label("结束导航", systemImage: "xmark.circle").font(.subheadline.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .accessibilityIdentifier("nav-stop")
        .screenPanel(.stopNavigationButton)
    }

    static func distance(_ meters: Int) -> String {
        meters >= 1000 ? String(format: "%.1f 公里", Double(meters) / 1000) : "\(meters) 米"
    }

    // MARK: Choices

    @ViewBuilder private var choices: some View {
        VStack(alignment: .leading, spacing: 6) {
            // F-15b §57 item 1 (T-040zj): while the route is searched, calculated or picked (no guidance panel yet).
            if model.nav.stopButtonShown && !model.nav.navigating {
                HStack { Spacer(); stopNavigationButton }
            }
            switch model.nav.phase {
            // A place list: the destination list, or the along-route list over the running guidance.
            case _ where presentation.list == .places:
                Text(model.nav.alongRouteList ? "沿途结果：说第几个改去那里，或点一下" : "请说第几个，或点一下")
                    .font(.caption).foregroundStyle(.secondary)
                    .screenPanel(.destinationList)
                ForEach(Array(model.nav.places.enumerated()), id: \.offset) { index, place in
                    HStack {
                        Text("\(index + 1)").font(.headline).frame(width: 22)
                        VStack(alignment: .leading) {
                            Text(place.name).font(.subheadline.weight(.semibold))
                            // F-16 §15 item 2 (T-042d): what the place is, from the search answer.
                            if let about = model.nav.about(place) { Text(about).font(.caption) }
                            if let address = place.address { Text(address).font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if let meters = place.distanceMeters, !model.nav.unlocated(place) {
                            Text(Self.distance(meters)).font(.caption)
                        }
                        // F-15b §13 item 3: the already-found place joins the trip list, no new lookup.
                        // F-15b §51 item 2: not offered while the trip cards are hidden.
                        // F-16 §15 item 2: a name 高德 could not find has no real place to add.
                        if !model.tripPlan.isEmpty && !model.tripMoving && !model.tripCardsHidden
                            && !model.nav.unlocated(place) {
                            Button("加入清单") { Task { await runtime.tripTap(.add(place)) } }
                                .font(.caption).buttonStyle(.bordered)
                                .accessibilityIdentifier("trip-add-\(index)")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await runtime.tapChoice(row: index) } }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("place-row-\(index)")
                }
            case .resolvingDestination:
                Label("正在搜索地点…", systemImage: "magnifyingglass").screenPanel(.routeCalculating)
            case .calculatingRoute:
                Label("正在计算路线…", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .screenPanel(.routeCalculating)
            case .awaitingRouteSelection:
                Text("说第几条，或者「开始导航」").font(.caption).foregroundStyle(.secondary)
                    .screenPanel(.routePicking)
                ForEach(Array(model.nav.routes.enumerated()), id: \.offset) { index, route in
                    HStack {
                        Text("\(index + 1)").font(.headline).frame(width: 22)
                        Text("\(max(1, route.durationSeconds / 60)) 分钟").font(.subheadline.weight(.semibold))
                        Text(Self.distance(route.lengthMeters)).font(.caption)
                        Spacer()
                        Text("红绿灯 \(route.trafficLights) · ¥\(route.tollYuan)").font(.caption2)
                    }
                    .padding(4)
                    .background(route.id == model.nav.selectedRoute ? Color.blue.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await runtime.tapChoice(row: index) } }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("route-row-\(index)")
                }
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// F-04 §15 items 1-4 (T-004k): next to the status caption while any tool call runs, whoever talks; the list is
    /// read every 0.25 s (on/off follow the calls only, no keep time).
    private var backgroundWorkCaption: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            if let caption = runtime.background.current.caption {
                Text(caption)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
                    .accessibilityIdentifier("background-work")
                    .screenPanel(.backgroundWork)
            }
        }
    }

    /// F-15b §50 item 6 (T-040w): `WorkProgress` read every 0.25 s; it shows nothing for the first second.
    private var workSteps: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            if let panel = runtime.work.panel {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(panel.steps.enumerated()), id: \.offset) { _, step in
                        Label(step.title, systemImage: Self.stepIcon(step.state))
                            .font(.subheadline)
                            .foregroundStyle(step.state == .failed ? Color.orange : step.state == .done ? Color.secondary : Color.primary)
                    }
                    if let failure = panel.failure {
                        Text(failure).font(.caption).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("work-steps")
                .screenPanel(.working)
            }
        }
    }

    private static func stepIcon(_ state: WorkProgress.State) -> String {
        switch state {
        case .pending: "circle"
        case .running: "magnifyingglass"
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    // MARK: Conversation, car and button

    private static func now() -> NovaInstant {
        NovaInstant(milliseconds: Int64(ProcessInfo.processInfo.systemUptime * 1000))
    }

    /// F-25: the latest exchange, held by `BubbleFade` and faded on its own.
    private var conversation: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let phase = bubble.phase(at: Self.now())
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    if phase != .hidden, !model.driverLine.isEmpty {
                        HStack {
                            Spacer()
                            Text(model.driverLine).padding(8)
                                .background(.green.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    if phase != .hidden, !model.view.subtitle.isEmpty {
                        Text(model.view.subtitle).padding(8)
                            .background(.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .opacity(phase == .fading ? 0.4 : 1)
                // F-24 §17 items 1, 4: the other notice is unchanged; a non-retryable failure adds 连接失败，点按重试.
                if let notice = model.notice ?? (model.connectionShow == .failed ? ConnectionNotice.failedText : nil) {
                    Text(notice).font(.footnote).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.5), value: phase)
        }
        .onChange(of: model.driverLine) { _, line in
            bubble.update(line, at: Self.now())
        }
        .onChange(of: model.view.subtitle) { _, text in
            bubble.update(model.driverLine + text, at: Self.now())
        }
        .onChange(of: model.view.chip) { _, chip in
            bubble.pin(chip == .speaking, at: Self.now())
        }
    }

    private var carCard: some View {
        HStack(spacing: 14) {
            Label("\(ClimateToolHandler.formatTemperature(model.climate.targetTemperatureCelsius))°C",
                  systemImage: model.climate.powerOn ? "snowflake" : "thermometer.medium")
            Label("风量 \(model.climate.fanLevel)", systemImage: "fan")
            Label("座椅 \(model.cabin.seatHeights[.driver] ?? 0)", systemImage: "carseat.left")
            Label("车窗 \(model.cabin.windows[.frontLeft] ?? 0)%", systemImage: "window.vertical.closed")
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("car-card")
    }

    private var talkButton: some View {
        VStack {
            if UITestDrive.enabled {
                // T-048: stands in for the driver's 「导航去珠海站」 in the simulator drive.
                Button("导航去珠海站") { Task { await runtime.navigate(to: "珠海站") } }
                    .accessibilityIdentifier("uitest-navigate")
            }
            voiceButton
        }
    }

    private var voiceButton: some View {
        Button(action: toggle) {
            Label(model.running ? "结束对话" : "开始对话", systemImage: model.running ? "stop.circle.fill" : "mic.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.running ? .red : .blue)
        .accessibilityIdentifier("talk-button")
    }
}

extension CLLocationCoordinate2D {
    init(_ c: GeoCoordinate) { self.init(latitude: c.latitude, longitude: c.longitude) }
}

/// 我的位置: a heading arrow while moving, else a dot with a white ring; gray when the fix is provisional.
private struct SelfMarker: View {
    let marker: SelfPosition.Marker

    var body: some View {
        let color: Color = marker.style == .provisional ? .gray : .blue
        if let heading = marker.headingDegrees {
            Image(systemName: "location.north.fill")
                .font(.title2)
                .foregroundStyle(color)
                .rotationEffect(.degrees(heading))
                .shadow(radius: 2)
        } else {
            Circle()
                .fill(color)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(radius: 2)
        }
    }
}

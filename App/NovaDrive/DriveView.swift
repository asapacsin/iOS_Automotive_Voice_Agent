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
    /// One runtime for the phone screen and the CarPlay scene (they read the same snapshots, §11.5).
    static let shared = RuntimeHolder()
    let runtime = AgentRuntime()
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
                conversation
                locateRow
                carCard
                talkButton
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            if model.cameraOpen { CameraWindow(model: model, runtime: runtime) }
        }
        // T-044c: 我的位置 and the camera follow the policy (F-16b); the view only applies its commands.
        .onChange(of: model.geometry) { _, geometry in position.navigation(model.nav, geometry: geometry) }
        .onChange(of: model.nav) { _, flow in position.navigation(flow, geometry: model.geometry) }
        .onChange(of: position.command) { _, command in if let command { apply(command.command) } }
        .onChange(of: useDeviceLocation) { _, _ in position.sourceChanged() }
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
        .task { if UITestDrive.enabled { await runtime.startUITestDrive() } else { await runtime.refreshWake() } }
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
            if let destination = presentation.destination {
                Marker(destination.name, coordinate: CLLocationCoordinate2D(destination.coordinate)).tint(.red)
            }
            ForEach(Array(presentation.markers.enumerated()), id: \.offset) { index, place in
                Marker("\(index + 1) \(place.name)", coordinate: CLLocationCoordinate2D(place.coordinate)).tint(.orange)
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
        let (text, color) = model.sheTalks && model.running ? ("她在说话", Color.blue) : state
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 0) {
                Text(text).font(.subheadline.weight(.semibold))
                if model.sheTalks && model.stopHint && model.running {
                    Text("说「别说了」可打断").font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("stop-hint")
                }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
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
            }
        }
        .accessibilityIdentifier("hud-panel")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    static func distance(_ meters: Int) -> String {
        meters >= 1000 ? String(format: "%.1f 公里", Double(meters) / 1000) : "\(meters) 米"
    }

    // MARK: Choices

    @ViewBuilder private var choices: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.nav.phase {
            // A place list: the destination list, or the along-route list over the running guidance.
            case _ where presentation.list == .places:
                Text(model.nav.alongRouteList ? "沿途结果：说第几个改去那里，或点一下" : "请说第几个，或点一下")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(model.nav.places.enumerated()), id: \.offset) { index, place in
                    HStack {
                        Text("\(index + 1)").font(.headline).frame(width: 22)
                        VStack(alignment: .leading) {
                            Text(place.name).font(.subheadline.weight(.semibold))
                            if let address = place.address { Text(address).font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if let meters = place.distanceMeters { Text(Self.distance(meters)).font(.caption) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await runtime.tapChoice(row: index) } }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("place-row-\(index)")
                }
            case .resolvingDestination:
                Label("正在搜索地点…", systemImage: "magnifyingglass")
            case .calculatingRoute:
                Label("正在计算路线…", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            case .awaitingRouteSelection:
                Text("说第几条，或者「开始导航」").font(.caption).foregroundStyle(.secondary)
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
                if let notice = model.notice {
                    Text(notice).font(.footnote).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.5), value: phase)
        }
        .onChange(of: model.driverLine) { _, line in
            // A new driver line starts a new exchange.
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

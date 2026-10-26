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
    @StateObject private var holder = RuntimeHolder()
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(DriveSettings.demoOrigin), latitudinalMeters: 6_000, longitudinalMeters: 6_000))

    private var model: DriveModel { holder.runtime.model }

    var body: some View {
        DriveContent(model: holder.runtime.model, camera: $camera,
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

/// F-20a floating window: live back camera, 问一下 and ×; drag to any corner.
private struct CameraWindow: View {
    @ObservedObject var model: DriveModel
    let runtime: AgentRuntime
    @State private var corner: Alignment = .topTrailing
    @State private var drag: CGSize = .zero

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
                    if model.cameraAsking {
                        Text("看画面中…").font(.caption2).padding(4)
                            .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(4)
                    }
                }
                HStack {
                    Text(model.cameraAnswer ?? " ").font(.caption2).lineLimit(3)
                    Spacer(minLength: 4)
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
    let runtime = AgentRuntime()
}

private struct DriveContent: View {
    @ObservedObject var model: DriveModel
    @Binding var camera: MapCameraPosition
    let toggle: () -> Void
    let runtime: AgentRuntime
    @Environment(\.scenePhase) private var scenePhase

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
                carCard
                talkButton
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            if model.cameraOpen { CameraWindow(model: model, runtime: runtime) }
        }
        .onChange(of: model.geometry) { _, geometry in focus(geometry) }
        // F-20a §5: the camera never runs in the background.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && model.cameraOpen { runtime.closeCamera() }
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
        Map(position: $camera) {
            // T-044: only what the flow allows is drawn (offered or chosen routes; nothing after 算了).
            ForEach(model.geometry.routes.filter { presentation.routes.contains($0.summary.id) }, id: \.summary.id) { route in
                let selected = route.summary.id == model.geometry.selected
                MapPolyline(coordinates: route.points.map { CLLocationCoordinate2D($0) })
                    .stroke(selected ? Color.blue : Color.gray.opacity(0.6), lineWidth: selected ? 7 : 4)
            }
            if let car = model.geometry.car {
                Annotation("", coordinate: CLLocationCoordinate2D(car)) {
                    Image(systemName: "location.north.circle.fill")
                        .font(.title).foregroundStyle(.white, .blue)
                }
            }
            if let destination = presentation.destination {
                Marker(destination.name, coordinate: CLLocationCoordinate2D(destination.coordinate)).tint(.red)
            }
            ForEach(Array(presentation.markers.enumerated()), id: \.offset) { index, place in
                Marker("\(index + 1) \(place.name)", coordinate: CLLocationCoordinate2D(place.coordinate)).tint(.orange)
            }
        }
    }

    private func focus(_ geometry: RouteGeometry) {
        if presentation.followCar, let car = geometry.car {
            withAnimation(.linear(duration: 1)) {
                camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(car), latitudinalMeters: 1_500,
                                                    longitudinalMeters: 1_500))
            }
            return
        }
        let points = geometry.routes.filter { presentation.routes.contains($0.summary.id) }.flatMap(\.points)
        guard !points.isEmpty else { return }
        let lats = points.map(\.latitude), lngs = points.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lngs.min()! + lngs.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: (lats.max()! - lats.min()!) * 1.6 + 0.01,
                                    longitudeDelta: (lngs.max()! - lngs.min()!) * 1.6 + 0.01)
        withAnimation { camera = .region(MKCoordinateRegion(center: center, span: span)) }
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
            Text(model.nav.navigating ? "模拟行驶" : "模拟车辆")
                .font(.caption2).padding(.horizontal, 6).padding(.vertical, 3)
                .background(.yellow.opacity(0.85), in: Capsule())
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var chip: some View {
        let (text, color): (String, Color) = switch model.view.chip {
        case .idle: (model.running ? "待命" : "未开始", .gray)
        case .processing: ("思考中", .orange)
        case .listening: ("聆听中", .green)
        case .speaking: ("说话中", .blue)
        case .error: ("出错 \(model.view.configError?.rawValue ?? "")", .red)
        }
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
        .accessibilityIdentifier("status-chip")
    }

    /// F-17 panel from `HUDPanelModel`; the limit stays hidden until an engine reports one (limit 0 = no data).
    private var hud: some View {
        let panel = HUDPanelModel(destinationName: model.nav.destination?.name ?? "", naviInfo: model.nav.info,
                                  lastGuidance: model.nav.lastGuidance, speedLimitKmh: model.nav.info?.facilityLimitKmh ?? 0)
        return VStack(alignment: .leading, spacing: 4) {
            Text(panel.title).font(.headline)
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

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.driverLine.isEmpty {
                HStack {
                    Spacer()
                    Text(model.driverLine).padding(8)
                        .background(.green.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if !model.view.subtitle.isEmpty {
                Text(model.view.subtitle).padding(8)
                    .background(.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
            }
            if let notice = model.notice {
                Text(notice).font(.footnote).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: model.view.subtitle)
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

import NovaKit

// MARK: Vehicle (simulated, F-11) — mirrors `vehicle/VehicleControlPort.kt`

public enum SeatID: String, Sendable, Hashable, CaseIterable { case driver, passenger }
/// Declaration order is Android's `WindowId.entries` order (announcements list windows in it).
public enum WindowID: String, Sendable, Hashable, CaseIterable {
    case frontLeft = "front_left", frontRight = "front_right", rearLeft = "rear_left", rearRight = "rear_right"
}

public struct ClimateState: Sendable, Hashable {
    public var powerOn: Bool
    public var targetTemperatureCelsius: Double
    public var fanLevel: Int

    public init(powerOn: Bool, targetTemperatureCelsius: Double, fanLevel: Int) {
        self.powerOn = powerOn
        self.targetTemperatureCelsius = targetTemperatureCelsius
        self.fanLevel = fanLevel
    }

    /// `ClimateState.DEFAULT`.
    public static let `default` = ClimateState(powerOn: false, targetTemperatureCelsius: 24, fanLevel: 2)
}

public struct CabinState: Sendable, Hashable {
    /// Percent open, 0...100.
    public var windows: [WindowID: Int]
    /// Level 0...10.
    public var seatHeights: [SeatID: Int]

    public init(windows: [WindowID: Int], seatHeights: [SeatID: Int]) {
        self.windows = windows
        self.seatHeights = seatHeights
    }

    /// `CabinState.DEFAULT`: windows closed, seats at 5.
    public static let `default` = CabinState(
        windows: Dictionary(uniqueKeysWithValues: WindowID.allCases.map { ($0, CabinLimits.windowMin) }),
        seatHeights: Dictionary(uniqueKeysWithValues: SeatID.allCases.map { ($0, CabinLimits.seatDefault) }))
}

public enum ClimateLimits {
    public static let minTemperatureC = 16.0
    public static let maxTemperatureC = 32.0
    public static let minFanLevel = 0
    public static let maxFanLevel = 7
    public static let defaultTemperatureStepC = 1.0
    public static let defaultFanStep = 1
}

public enum CabinLimits {
    public static let windowMin = 0
    public static let windowMax = 100
    public static let defaultWindowStep = 20
    public static let seatMin = 0
    public static let seatMax = 10
    public static let seatDefault = 5
    public static let defaultSeatStep = 1
}

/// Backend-neutral outcome (`VehicleActionResult`). Reasons go to the model as `detail`, never to logs.
public enum VehicleActionResult<State: Sendable & Hashable>: Sendable, Hashable {
    case success(State, limitReached: Bool)
    case invalidArgument(String)
    case unsupported(String)
    case unavailable(String)
    case permissionDenied(String)
    case failure(String)
}

/// Vehicle backend; only the simulator exists (`BACKEND_LABEL=simulated`). Relative calls use the
/// backend's current state; the model never supplies the previous value.
public protocol VehicleControlPort: Sendable {
    var backendLabel: String { get }
    func setHvacPower(_ on: Bool) async -> VehicleActionResult<ClimateState>
    func setCabinTemperature(_ celsius: Double) async -> VehicleActionResult<ClimateState>
    func changeCabinTemperature(_ deltaCelsius: Double) async -> VehicleActionResult<ClimateState>
    func setFanLevel(_ level: Int) async -> VehicleActionResult<ClimateState>
    func changeFanLevel(_ delta: Int) async -> VehicleActionResult<ClimateState>
    func climateState() async -> ClimateState
    func setWindows(_ windows: Set<WindowID>, openPercent: Int) async -> VehicleActionResult<CabinState>
    func changeWindows(_ windows: Set<WindowID>, deltaPercent: Int) async -> VehicleActionResult<CabinState>
    func setSeatHeight(_ seat: SeatID, level: Int) async -> VehicleActionResult<CabinState>
    func changeSeatHeight(_ seat: SeatID, delta: Int) async -> VehicleActionResult<CabinState>
    func cabinState() async -> CabinState
}

// MARK: Music (F-13)

public protocol MusicPort: Sendable {
    func playBundled() async -> Bool
    func stop() async
    var isPlaying: Bool { get async }
}

public struct NowPlaying: Sendable, Hashable {
    public let title: String
    public let artist: String?
    public init(title: String, artist: String?) {
        self.title = title
        self.artist = artist
    }
}

/// Apple Music through MusicKit (M6, only if OQ-IOS-7 approves).
public protocol NamedMusicPort: Sendable {
    func play(query: String) async throws
    func nowPlaying() async -> NowPlaying?
}

// MARK: Phone (F-19)

public struct Contact: Sendable, Hashable {
    public let displayName: String
    public let phoneNumbers: [String]
    public init(displayName: String, phoneNumbers: [String]) {
        self.displayName = displayName
        self.phoneNumbers = phoneNumbers
    }
}

public protocol ContactsDirectory: Sendable {
    /// Contacts whose name matches; throws `ContactsError.permissionDenied` without access.
    func search(_ name: String) async throws -> [Contact]
}

public enum ContactsError: Error, Sendable, Hashable {
    case permissionDenied
}

public protocol PhoneDialer: Sendable {
    var canPlaceCalls: Bool { get async }
    /// Opens `tel://`; the system shows its own confirmation.
    func dial(_ number: String) async -> Bool
}

// MARK: Vision (F-20)

public struct JPEGImage: Sendable, Hashable {
    public let data: [UInt8]
    public init(data: [UInt8]) { self.data = data }
}

public protocol CameraFrameSource: Sendable {
    /// One JPEG of the live preview (longest side ≤ 1024 px, not older than 1 s). Throws `CameraError`.
    func captureStill() async throws -> JPEGImage
}

/// Why `captureStill` failed (F-20a §8).
public enum CameraError: Error, Sendable, Hashable {
    case permissionDenied
    case unavailable
}

public enum VisionAnswer: Sendable, Hashable {
    case answer(String)
    case notConfigured
    case authFailed
    case failed
}

/// Vision backend: Gemini `generateContent` by default (F-20a OQ-CAM-1), Qianfan optional.
public protocol VisionPort: Sendable {
    func ask(_ question: String, image: JPEGImage) async -> VisionAnswer
}

// MARK: Settings and secrets (F-22)

/// Every secret the app stores. `CredentialWipe` removes all of them.
public enum CredentialKey: String, Sendable, Hashable, CaseIterable {
    case geminiAPIKey = "gemini_api_key"
    case azureSpeechKey = "azure_speech_key"
    case amapSDKKey = "amap_sdk_key"
    case amapWebKey = "amap_web_key"
    case iflytekAppID = "iflytek_app_id"
    /// AIKit wake word (T-060): the app's APIKey and APISecret from the iFlytek console.
    case iflytekAPIKey = "iflytek_api_key"
    case iflytekAPISecret = "iflytek_api_secret"
    case qianfanKey = "qianfan_key"
}

/// Keychain (`kSecAttrAccessibleAfterFirstUnlock`). Values are write-only from the UI.
public protocol CredentialStore: Sendable {
    func value(for key: CredentialKey) throws -> String?
    func set(_ value: String, for key: CredentialKey) throws
    func remove(_ key: CredentialKey) throws
}

/// UserDefaults for non-secret settings.
public protocol SettingsStore: Sendable {
    func string(_ key: String) -> String?
    func bool(_ key: String) -> Bool?
    func set(_ value: String?, for key: String)
    func set(_ value: Bool, for key: String)
}

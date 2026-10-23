import NovaKit

// MARK: Vehicle (simulated, F-11)

public enum SeatPosition: String, Sendable, Hashable { case driver, passenger }
public enum WindowPosition: String, Sendable, Hashable, CaseIterable { case frontLeft, frontRight, rearLeft, rearRight }

public struct ClimateState: Sendable, Hashable {
    public var powerOn: Bool
    public var temperatureCelsius: Int
    public var fanLevel: Int

    public init(powerOn: Bool, temperatureCelsius: Int, fanLevel: Int) {
        self.powerOn = powerOn
        self.temperatureCelsius = temperatureCelsius
        self.fanLevel = fanLevel
    }
}

public struct VehicleState: Sendable, Hashable {
    public var climate: ClimateState
    public var seatHeight: [SeatPosition: Int]
    /// Percent open, 0...100.
    public var windowOpen: [WindowPosition: Int]

    public init(climate: ClimateState, seatHeight: [SeatPosition: Int], windowOpen: [WindowPosition: Int]) {
        self.climate = climate
        self.seatHeight = seatHeight
        self.windowOpen = windowOpen
    }
}

/// Vehicle backend; only the simulator exists (`BACKEND_LABEL=simulated`). Handlers in NovaTools turn
/// tool arguments into these calls; failures surface as `ToolErrorCode`s.
public protocol VehicleControl: Sendable {
    var backendLabel: String { get }
    func state() async -> VehicleState
    func setClimatePower(_ on: Bool) async -> Result<ClimateState, VehicleFault>
    func setTemperature(_ celsius: Int) async -> Result<ClimateState, VehicleFault>
    func setFan(_ level: Int) async -> Result<ClimateState, VehicleFault>
    func setSeatHeight(_ seat: SeatPosition, level: Int) async -> Result<Int, VehicleFault>
    func setWindow(_ window: WindowPosition, percentOpen: Int) async -> Result<Int, VehicleFault>
}

public struct VehicleFault: Error, Sendable, Hashable {
    public let code: ToolErrorCode
    public init(_ code: ToolErrorCode) { self.code = code }
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
    func search(_ name: String) async throws -> [Contact]
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
    func captureStill() async throws -> JPEGImage
}

public enum VisionAnswer: Sendable, Hashable {
    case answer(String)
    case notConfigured
    case authFailed
    case failed
}

/// Qianfan VLM.
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

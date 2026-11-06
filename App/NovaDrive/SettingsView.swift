import NovaAgent
import NovaNav
import NovaPlatform
import NovaPorts
import NovaServices
import NovaVoice
import SwiftUI

/// Keys are write-only: entered here, kept in the Keychain, never shown again (H-keys).
struct SettingsView: View {
    private let store = KeychainCredentialStore()
    private static let allKeys: [(CredentialKey, String)] = [
        (.geminiAPIKey, "Gemini API key"),
        (.azureSpeechKey, "Azure Speech key"),
        (.amapSDKKey, "高德 iOS SDK key"),
        (.amapWebKey, "高德 Web 服务 key"),
        (.zhipuKey, "智谱 key（视觉，推荐）"),
        (.qwenAPIKey, "阿里云百炼 key（联网搜索）"),
        (.qianfanKey, "千帆 key（可选，视觉备用）"),
        (.iflytekAppID, "讯飞 APPID（唤醒词）"),
        (.iflytekAPIKey, "讯飞 APIKey"),
        (.iflytekAPISecret, "讯飞 APISecret"),
    ]
    /// F-01 §14 item 5: with the sherpa wake engine selected the three 讯飞 fields do not show.
    private let keys = SettingsView.allKeys.filter { !WakeEngineKind.selected.hiddenKeys.contains($0.0) }
    private let settings = DefaultsSettingsStore()
    @State private var drafts: [CredentialKey: String] = [:]
    @State private var saved: Set<CredentialKey> = []
    @State private var message: String?
    @State private var readiness: SettingsReadiness?
    @State private var confirmWipe = false
    @AppStorage(SettingsKey.geminiConsentAccepted) private var geminiConsent = false
    @AppStorage(DriveSettings.azureRegion) private var azureRegion = ""
    @AppStorage(DriveSettings.azureVoice) private var azureVoice = DriveSettings.defaultVoice
    @AppStorage(DriveSettings.useDeviceLocation) private var useDeviceLocation = true
    @AppStorage(DriveSettings.noiseSuppression) private var noiseSuppression = true
    @AppStorage(DriveSettings.interruptible) private var interruptible = false
    @AppStorage(DriveSettings.modelComfort) private var modelComfort = false
    @AppStorage(DriveSettings.webSearch) private var webSearch = false
    @AppStorage(DriveSettings.conversationRecord) private var conversationRecord = false
    @AppStorage(DriveSettings.wakeWord) private var wakeWord = true
    @State private var confirmDeleteRecords = false
    @AppStorage(DriveSettings.navigationMode) private var navigationMode = NavigationModeSetting.default.rawValue
    @StateObject private var locationPermission = LocationPermission()

    var body: some View {
        NavigationStack {
            Form {
                if let readiness { statusSection(readiness) }
                Section("Gemini 使用条款") {
                    Toggle("同意 Gemini 使用条款", isOn: $geminiConsent)
                    Text("开始对话后，你的语音会发送到 Google Gemini 处理。").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(keys, id: \.0) { key, title in
                    Section(title) {
                        SecureField(saved.contains(key) ? "已保存，输入可替换" : "未设置", text: binding(key))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        HStack {
                            Button("保存") { save(key) }.disabled((drafts[key] ?? "").isEmpty)
                            Spacer()
                            if saved.contains(key) { Button("删除", role: .destructive) { remove(key) } }
                        }
                    }
                }
                Section("Azure 区域和声音") {
                    TextField("区域（留空自动识别）", text: $azureRegion)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("声音", text: $azureVoice)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                // F-01 §14 item 6 (T-060a).
                Section("唤醒词") {
                    Toggle("唤醒词", isOn: $wakeWord)
                    Text("开：应用在前台时用手机麦克风等「你好小诺」，声音只在手机上处理。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("声音") {
                    Toggle("抗噪", isOn: $noiseSuppression)
                    Text("开：只有人声才会打开麦克风或打断小诺，喇叭、音乐、路噪不会。切换后立即生效。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("可以打断她（实验）", isOn: $interruptible)
                    Text("开：她说话时你说出新的内容，她会先变小声，确认是你在说新问题后停下来回答你。关：只有「别说了」能让她停。导航播报不会被打断。")
                        .font(.footnote).foregroundStyle(.secondary)
                    // F-04b §3 (T-013e).
                    SpeakerLockSection()
                }
                // F-12 §14 items 4 and 7 (T-031a, T-031b).
                Section("舒适场景") {
                    Toggle("由模型决定舒适动作（实验）", isOn: $modelComfort)
                    Text("开：说「有蚊子」「有点闷」这类感受时，由模型看车内状态自己决定开窗、空调或音乐，并用自己的话说做了什么。关：按固定的场景表做。下次开始对话时生效。")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("舒适场景测试") { ComfortEvalView() }
                }
                // F-18 §15 item 1, §17 item 2 (T-046e).
                Section("联网") {
                    Toggle("联网搜索（实验）", isOn: $webSearch)
                    Text("需要阿里云百炼 key。问题会发到阿里云新加坡。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("开：天气、新闻、营业时间这类信息由她联网查，答案可能不准。车辆操作不变，仍只通过车辆工具。关：和现在一样。下次开始对话时生效。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                // F-12 §17 (T-031f).
                Section("测试") {
                    Toggle("保存对话记录（测试用）", isOn: $conversationRecord)
                    Text("开：每次对话把听到的话、她说的话和做的操作存成手机上的一个文件（文件 App 或电脑上可取），只保留最新 50 个。可能含有地址，只在测试时打开。下次开始对话时生效。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("删除全部对话记录", role: .destructive) { confirmDeleteRecords = true }
                        .confirmationDialog("删除全部对话记录？", isPresented: $confirmDeleteRecords, titleVisibility: .visible) {
                            Button("删除", role: .destructive) { ConversationRecordFile.deleteAll() }
                        }
                }
                Section("位置来源") {
                    Picker("位置来源", selection: $useDeviceLocation) {
                        Text("手机定位").tag(true)
                        Text("演示起点").tag(false)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("定位权限", value: locationPermission.label)
                    if locationPermission.denied {
                        Button("打开系统设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    Text(useDeviceLocation ? "搜索附近、天气和路线起点用手机的真实位置。" : "用固定的演示起点（录屏用），屏幕上显示「演示位置」。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .onChange(of: useDeviceLocation) { if useDeviceLocation { locationPermission.request() } }
                // F-15a §2.1: read when guidance starts; 演示起点 locks it to 模拟导航.
                Section("导航方式") {
                    let locked = NavigationModeSetting.locked(source: useDeviceLocation ? .device : .demo)
                    Picker("导航方式", selection: locked ? .constant(NavigationModeSetting.simulated.rawValue)
                                                      : $navigationMode) {
                        Text("真实导航").tag(NavigationModeSetting.real.rawValue)
                        Text("模拟导航").tag(NavigationModeSetting.simulated.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .disabled(locked)
                    .accessibilityIdentifier("navigation-mode")
                    Text(locked ? "演示起点只能模拟导航。"
                         : navigationMode == NavigationModeSetting.simulated.rawValue
                         ? "模拟导航（演示 / 录屏）：一辆模拟车沿路线行驶，屏幕显示「模拟导航」。下次导航生效。"
                         : "真实导航：按手机定位走路线，偏离路线会重新规划。没有定位时不能开始。下次导航生效。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("危险操作") {
                    Button("清除所有密钥", role: .destructive) { confirmWipe = true }
                }
                if let message { Section { Text(message) } }
                // F-18 §26 item 10: no about or data-source area, so the Open-Meteo credit is at the bottom.
                Section {
                    Text(ForecastWeather.credit).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("weather-credit")
                }
            }
            .navigationTitle("设置")
            .onAppear(perform: refresh)
            .onChange(of: geminiConsent) { refresh() }
            .confirmationDialog("清除所有密钥？", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("清除所有密钥", role: .destructive) { wipe() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("所有已保存的 key、Gemini 同意状态和声纹都会被删除。")
            }
        }
    }

    private func statusSection(_ ready: SettingsReadiness) -> some View {
        Section("状态") {
            statusRow("Gemini key", ready.geminiKey)
            statusRow("Gemini 同意", ready.geminiConsent)
            statusRow("Azure 声音", ready.azureVoice)
            statusRow("高德 Web key", ready.amapWebKey)
            statusRow("视觉 key", ready.vision)
        }
    }

    private func statusRow(_ title: String, _ isSet: Bool) -> some View {
        LabeledContent(title, value: isSet ? "✓" : "未设置")
    }

    private func binding(_ key: CredentialKey) -> Binding<String> {
        Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0 })
    }

    private func refresh() {
        // Sessions use the default voice when none was typed; store it so readiness says so too.
        if settings.string(SettingsKey.azureVoice)?.isEmpty != false {
            settings.set(DriveSettings.defaultVoice, for: SettingsKey.azureVoice)
        }
        saved = Set(keys.map(\.0).filter { SecretField.display($0, in: store) == .saved })
        readiness = SettingsReadiness(credentials: store, settings: settings)
    }

    private func save(_ key: CredentialKey) {
        do {
            if try SecretField.save(drafts[key] ?? "", for: key, in: store) { message = "已保存" }
            drafts[key] = nil
        } catch { message = "保存失败: \(error)" }
        refresh()
    }

    private func remove(_ key: CredentialKey) {
        do { try store.remove(key); message = "已删除" } catch { message = "删除失败: \(error)" }
        refresh()
    }

    private func wipe() {
        let failed = CredentialWipe.wipe(store, settings: settings)
        // F-04b §3 item 5: the wipe-all also deletes the voice profile (and turns the lock off).
        SpeakerLockService.shared.deleteProfile()
        geminiConsent = false
        drafts = [:]
        message = failed.isEmpty ? "已清除所有密钥" : "以下 key 清除失败：\(failed.map(\.rawValue).joined(separator: ", "))"
        refresh()
    }
}

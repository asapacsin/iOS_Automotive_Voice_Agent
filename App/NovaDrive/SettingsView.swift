import NovaAgent
import NovaPorts
import NovaServices
import SwiftUI

/// Keys are write-only: entered here, kept in the Keychain, never shown again (H-keys).
struct SettingsView: View {
    private let store = KeychainCredentialStore()
    private let keys: [(CredentialKey, String)] = [
        (.geminiAPIKey, "Gemini API key"),
        (.azureSpeechKey, "Azure Speech key"),
        (.amapSDKKey, "高德 iOS SDK key"),
        (.amapWebKey, "高德 Web 服务 key"),
        (.qianfanKey, "千帆 key（可选，视觉备用）"),
    ]
    private let settings = DefaultsSettingsStore()
    @State private var drafts: [CredentialKey: String] = [:]
    @State private var saved: Set<CredentialKey> = []
    @State private var message: String?
    @State private var readiness: SettingsReadiness?
    @State private var confirmWipe = false
    @AppStorage(SettingsKey.geminiConsentAccepted) private var geminiConsent = false
    @AppStorage(DriveSettings.azureRegion) private var azureRegion = ""
    @AppStorage(DriveSettings.azureVoice) private var azureVoice = DriveSettings.defaultVoice

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
                Section("危险操作") {
                    Button("清除所有密钥", role: .destructive) { confirmWipe = true }
                }
                if let message { Section { Text(message) } }
            }
            .navigationTitle("设置")
            .onAppear(perform: refresh)
            .onChange(of: geminiConsent) { refresh() }
            .confirmationDialog("清除所有密钥？", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("清除所有密钥", role: .destructive) { wipe() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("所有已保存的 key 和 Gemini 同意状态都会被删除。")
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
        geminiConsent = false
        drafts = [:]
        message = failed.isEmpty ? "已清除所有密钥" : "以下 key 清除失败：\(failed.map(\.rawValue).joined(separator: ", "))"
        refresh()
    }
}

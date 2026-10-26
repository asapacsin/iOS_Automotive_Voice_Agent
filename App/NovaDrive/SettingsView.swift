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
    ]
    @State private var drafts: [CredentialKey: String] = [:]
    @State private var saved: Set<CredentialKey> = []
    @State private var message: String?
    @AppStorage(DriveSettings.azureRegion) private var azureRegion = ""
    @AppStorage(DriveSettings.azureVoice) private var azureVoice = DriveSettings.defaultVoice

    var body: some View {
        NavigationStack {
            Form {
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
                if let message { Section { Text(message) } }
            }
            .navigationTitle("设置")
            .onAppear(perform: refresh)
        }
    }

    private func binding(_ key: CredentialKey) -> Binding<String> {
        Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0 })
    }

    private func refresh() {
        saved = Set(keys.map(\.0).filter { (try? store.value(for: $0)) != nil })
    }

    private func save(_ key: CredentialKey) {
        let value = (drafts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do { try store.set(value, for: key); drafts[key] = nil; message = "已保存" }
        catch { message = "保存失败: \(error)" }
        refresh()
    }

    private func remove(_ key: CredentialKey) {
        do { try store.remove(key); message = "已删除" } catch { message = "删除失败: \(error)" }
        refresh()
    }
}

import SwiftUI

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("aiModel") private var model = "opus"
    @AppStorage("aiQuickModel") private var quickModel = "sonnet"
    @AppStorage("claudePath") private var claudePath = ""
    @State private var autoUpdate = Updater.shared.automaticallyChecks

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                .pickerStyle(.segmented)
            }
            Section {
                Picker("Assistant model", selection: $model) {
                    Text("Opus").tag("opus"); Text("Sonnet").tag("sonnet"); Text("Haiku").tag("haiku")
                }
                Picker("Quick actions model", selection: $quickModel) {
                    Text("Opus").tag("opus"); Text("Sonnet").tag("sonnet"); Text("Haiku").tag("haiku")
                }
                TextField("Claude Code path", text: $claudePath, prompt: Text(ClaudeCLI.executable() ?? "Not found"))
                LabeledContent("Status") {
                    Label(ClaudeCLI.isAvailable ? "Using your Claude Code login" : "Claude Code not found",
                          systemImage: ClaudeCLI.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(ClaudeCLI.isAvailable ? Color.cAccent : Color.cRed)
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("Canopy runs Claude through Claude Code, so it uses your existing login. Claude only gets read-only tools: it can't write, drop or run $out.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) { _, v in Updater.shared.automaticallyChecks = v }
                LabeledContent("Version") {
                    HStack {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                            .foregroundStyle(.secondary)
                        Button("Check Now") { Updater.shared.checkForUpdates() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 500)
    }
}

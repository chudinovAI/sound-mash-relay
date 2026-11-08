import SwiftUI
import AppKit

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SoundMashRelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RelayModel()

    var body: some Scene {
        Window("Sound Mash Relay", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 500, minHeight: 420)
                .onDisappear { model.stop() }
        }
        .windowResizability(.contentMinSize)
    }
}

private struct ContentView: View {
    @ObservedObject var model: RelayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Sound Mash Relay").font(.largeTitle.bold())
            Text("Один Mac передаёт системный звук, второй воспроизводит его с общей задержкой.")
                .foregroundStyle(.secondary)
            Text("Поток не защищён: любой, кто может подключиться к порту 45987, может слушать. Используйте только доверенную сеть.")
                .font(.caption).foregroundStyle(.orange)

            GroupBox("Первый Mac — отправитель") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Адрес этого Mac: \(model.localAddresses)").textSelection(.enabled)
                    Text("Введите этот адрес на втором Mac. При запросе разрешите захват системного звука.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Начать передачу") { model.startSender() }
                        .disabled(model.running)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }

            GroupBox("Второй Mac — приёмник") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("IP-адрес первого Mac", text: $model.host)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.running)
                        Button("Подключиться") { model.startReceiver() }
                            .disabled(model.running || model.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    HStack {
                        Text("Коррекция: \(Int(model.adjustmentMs)) мс")
                        Slider(value: $model.adjustmentMs, in: -200...200, step: 1)
                    }
                    Text("Отрицательное значение воспроизводит раньше, положительное — позже.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(4)
            }

            HStack(alignment: .top) {
                Text(model.status).foregroundStyle(model.hasError ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                Button("Остановить") { model.stop() }.disabled(!model.running)
            }
        }
        .padding(24)
    }
}

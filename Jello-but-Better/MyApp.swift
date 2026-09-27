import SwiftUI

@main struct MyApp: App {
#if os(macOS)
    @State private var controller = ScreenMirrorController()

    var body: some Scene {
        MenuBarExtra("Jello-but-Better", systemImage: controller.isRunning ? "wand.and.stars.inverse" : "wand.and.stars") {
            MenuContent(controller: controller)
        }
    }
#else
    var body: some Scene {
        WindowGroup {
            Text("Jello-but-Better runs on macOS.")
        }
    }
#endif
}

#if os(macOS)
struct MenuContent: View {
    @Bindable var controller: ScreenMirrorController

    var body: some View {
        Button(controller.isRunning ? "Stop Overlay" : "Start Overlay") {
            controller.toggle()
        }
        .keyboardShortcut("e")
        Text("⌃⌥⌘E toggles the overlay from anywhere")

        Picker("Effect", selection: $controller.effect) {
            ForEach(Effect.allCases) { effect in
                Text(effect.rawValue).tag(effect)
            }
        }

        Picker("Jello", selection: $controller.jello) {
            ForEach(Jello.allCases) { jello in
                Text(jello.rawValue).tag(jello)
            }
        }
        Toggle("Dragged Window Only", isOn: $controller.jelloWindowOnly)

        Toggle("Liquid Glass", isOn: $controller.liquidGlass)

        if let message = controller.errorMessage {
            Divider()
            Text(message)
            Button("Open Screen Recording Settings…") {
                controller.openScreenRecordingSettings()
            }
        }

        Divider()
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
#endif

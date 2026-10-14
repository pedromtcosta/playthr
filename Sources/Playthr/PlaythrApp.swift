import SwiftUI
import AppKit

@main
struct PlaythrApp: App {
    @StateObject private var model = SessionModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-smoke-output") {
            DispatchQueue.global().asyncAfter(deadline: .now() + 45) { print("UI smoke test timed out."); exit(11) }
        }
        #endif
    }
    var body: some Scene {
        Window("Playthr", id: "studio") {
            StudioView(model: model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1100, minHeight: 800)
                .onAppear {
                    delegate.model = model
                    NSApp.setActivationPolicy(.regular)
                    SmokeTest.runIfRequested(model: model)
                }
                .onOpenURL { model.openProject(url: $0) }
        }
        .defaultSize(width: 1360, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…", action: model.newProject).keyboardShortcut("n").disabled(model.locked)
                Button("Open Project…") { model.openProject() }.keyboardShortcut("o").disabled(model.locked)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo", action: model.undo).keyboardShortcut("z").disabled(!model.canUndo)
                Button("Redo", action: model.redo).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo)
            }
            CommandMenu("Session") {
                Button("Import Sound Razor Song…") { model.importAudio(soundRazor: true) }.disabled(!model.hasProject || model.locked)
                Button("Import Audio Files…") { model.importAudio(soundRazor: false) }.keyboardShortcut("i").disabled(!model.hasProject || model.locked)
                Button("Export Video…", action: model.exportVideo).keyboardShortcut("e").disabled(!model.canExportVideo || model.locked)
                Divider()
                Button("Recover Unlisted Takes", action: model.recoverTakes).disabled(!model.hasProject || model.locked)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: SessionModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.locked == true {
            let alert = NSAlert()
            alert.messageText = "Your session is still working"
            alert.informativeText = "Stop recording and let your take finish saving, or cancel the export, before quitting Playthr."
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

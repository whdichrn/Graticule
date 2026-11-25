import AppKit
import SwiftUI

enum AppCommandKind: Sendable {
    case openDataset
    case exportImage
    case exportScript
    case openScriptEditor
    case fitWindow
    case actualSize
    case refresh
    case back
    case forward
    case fullExtent
    case toggleInspector
    case panMode
    case selectMode
}

extension Notification.Name {
    static let graticuleCommand = Notification.Name("GraticuleCommandNotification")
}

private struct ActiveSessionIDKey: FocusedValueKey {
    typealias Value = UUID
}

extension FocusedValues {
    var activeSessionID: UUID? {
        get { self[ActiveSessionIDKey.self] }
        set { self[ActiveSessionIDKey.self] = newValue }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.contains("--self-check") {
            let env = BackendEnvironment()
            print("Graticule self-check OK")
            print("python=\(env.resolvedPythonPath ?? "missing")")
            print("gmt=\(env.resolvedGMTPath ?? "missing")")
            print("sourceRoot=\(env.resolvedSourceRoot ?? "missing")")
            fflush(stdout)
            exit(0)
        }

        if args.contains("--register-default") {
            let customPath: URL? = {
                if let idx = args.firstIndex(of: "--app-path"), idx + 1 < args.count {
                    return URL(fileURLWithPath: args[idx + 1])
                }
                return nil
            }()
            Task {
                do {
                    let result = try await FileAssociationManager.registerAsDefaultForAll(appURL: customPath)
                    for ext in FileAssociationManager.supportedExtensions {
                        print(".\(ext): \(result[ext] ?? "unknown")")
                    }
                    fflush(stdout)
                    exit(0)
                } catch {
                    fputs("Registration failed: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 10))
            exit(1)
        }

        let fileURLs = args
            .filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !fileURLs.isEmpty {
            WorkspaceManager.shared.pendingLaunchURLs.append(contentsOf: fileURLs)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.setActivationPolicy(.regular)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        WorkspaceManager.shared.handleIncomingURLs(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        WorkspaceManager.shared.rpc.terminateImmediately()
    }
}

@main
struct GraticuleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @FocusedValue(\.activeSessionID) private var focusedSessionID

    var body: some Scene {
        WindowGroup(id: "workspace", for: UUID.self) { $sessionID in
            WorkspaceWindowView(sessionID: sessionID)
        } defaultValue: {
            WorkspaceManager.shared.createOrClaimInitialSessionID()
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Dataset…") {
                    post(.openDataset)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("New Tab") {
                    _ = WorkspaceManager.shared.spawnNewTab(from: NSApp.keyWindow)
                }
                .keyboardShortcut("t", modifiers: .command)

                Divider()

                Button("Export Image…") {
                    post(.exportImage)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Export GMT Script…") {
                    post(.exportScript)
                }
            }

            CommandMenu("Plot") {
                Button("Pan Mode") {
                    post(.panMode)
                }
                Button("Select Subregion Mode") {
                    post(.selectMode)
                }

                Divider()

                Button("Fit Window") {
                    post(.fitWindow)
                }
                .keyboardShortcut("0", modifiers: .command)

                Button("Actual Size") {
                    post(.actualSize)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Refresh Plot") {
                    post(.refresh)
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("Back in Region History") {
                    post(.back)
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Forward in Region History") {
                    post(.forward)
                }
                .keyboardShortcut("]", modifiers: .command)

                Button("Reset to Full Grid") {
                    post(.fullExtent)
                }
                .keyboardShortcut("0", modifiers: [.command, .shift])

                Divider()

                Button("GMT Script Editor…") {
                    post(.openScriptEditor)
                }
                .keyboardShortcut("e", modifiers: .command)

                Button("Toggle Inspector") {
                    post(.toggleInspector)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView(workspace: .shared)
        }
    }

    private func post(_ command: AppCommandKind) {
        let target = focusedSessionID ?? WorkspaceManager.shared.activeSessionID ?? WorkspaceManager.shared.sessionOrder.first
        guard let target else {
            if command == .openDataset {
                WorkspaceManager.shared.openFileDialog(in: nil)
            }
            return
        }
        NotificationCenter.default.post(
            name: .graticuleCommand,
            object: nil,
            userInfo: ["sessionID": target, "command": command]
        )
    }
}

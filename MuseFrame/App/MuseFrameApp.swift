import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceController.apply(UserDefaults.standard.string(forKey: "appearance") ?? "system")
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) { CurrentArtworkStore.shared.flushWidgetReload() }
}

@MainActor enum AppearanceController {
    static func apply(_ preference: String) {
        NSApp.appearance = preference == "system" ? nil : NSAppearance(named: preference == "dark" ? .darkAqua : .aqua)
    }
}

@main struct MuseFrameApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("showMenuBar") private var showMenuBar = true

    var body: some Scene {
        Window("MuseFrame", id: "gallery") {
            MainWindow(model: model)
                .onChange(of: appearance) { _, value in AppearanceController.apply(value) }
                .task { await model.start() }
                .onOpenURL { url in
                    guard let destination = MuseFrameDeepLink(url) else { return }
                    Task {
                        await model.navigate(to: destination)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 940)
        .handlesExternalEvents(matching: ["museframe"])
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("画廊") {
                Button("Gallery") { model.tab = .gallery }.keyboardShortcut("1")
                Button("Art History") { model.tab = .history }.keyboardShortcut("2")
                Button("Saved") { model.tab = .saved }.keyboardShortcut("3")
                Divider()
                Button("放大艺术史") { model.historyMagnification = min(2.5, model.historyMagnification + 0.15) }
                    .keyboardShortcut("=").disabled(model.tab != .history)
                Button("缩小艺术史") { model.historyMagnification = max(0.55, model.historyMagnification - 0.15) }
                    .keyboardShortcut("-").disabled(model.tab != .history)
                Button("实际大小") { model.historyMagnification = 1 }
                    .keyboardShortcut("0").disabled(model.tab != .history)
            }
        }
        Settings { MuseFrameSettings(model: model).onChange(of: appearance) { _, value in AppearanceController.apply(value) } }
        MenuBarExtra("MuseFrame", systemImage: "photo.artframe", isInserted: $showMenuBar) {
            MuseFrameMenu(model: model)
        }.menuBarExtraStyle(.window)
    }
}

struct MainWindow: View {
    @Bindable var model: AppModel
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 3) {
                    ForEach(GalleryTab.allCases, id: \.self) { tab in
                        Button { model.tab = tab } label: {
                            Text(tab.rawValue).font(.system(size: 14, weight: model.tab == tab ? .semibold : .medium))
                                .frame(width: 116, height: 34)
                                .background(model.tab == tab ? Color.primary.opacity(0.09) : .clear, in: Capsule())
                                .contentShape(Capsule())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
                    }
                }.padding(4).background(.primary.opacity(0.035), in: Capsule())
                    .accessibilityIdentifier("mainNavigation")
                HStack(spacing: 16) {
                    Spacer()
                    RoundIconButton(symbol: "circle.lefthalf.filled", label: "切换浅色 / 深色") {
                        appearance = colorScheme == .dark ? "light" : "dark"
                    }
                    SettingsLink {
                        Image(systemName: "gearshape").font(.system(size: 15)).frame(width: 34, height: 34)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.12)))
                    }.buttonStyle(.plain).accessibilityLabel("设置").help("设置")
                }.padding(.trailing, 30)
            }.frame(height: 72)
            Group {
                if model.tab == .history { ArtHistoryView(model: model) }
                else { GalleryView(model: model) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MuseumStyle.canvas)
        .tint(.primary)
        .frame(minWidth: 1180, minHeight: 760)
        .onAppear { PerformanceDiagnostics.mark("main-window-on-appear", once: true) }
        .sheet(item: $model.selectedArtwork) { artwork in
            NavigationStack { ArtworkDetailView(artwork: artwork, model: model) }
                .frame(width: 1080, height: 720)
        }
        .alert("未能设置壁纸", isPresented: Binding(get: { model.wallpaperError != nil && model.selectedArtwork == nil }, set: { if !$0 { model.wallpaperError = nil } })) {
            Button("重试") {
                Task { await model.retryWallpaper() }
            }
            Button("取消", role: .cancel) { model.wallpaperError = nil }
        } message: { Text(model.wallpaperError ?? "") }
    }
}

import ServiceManagement
import SwiftUI

struct MuseFrameSettings: View {
    @Bindable var model: AppModel
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("editorialFeedURL") private var feedAddress = ""
    @State private var cacheStatus: String?
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private func setting<Value>(_ keyPath: WritableKeyPath<RotationSettings, Value>) -> Binding<Value> {
        Binding(get: { model.rotation.settings[keyPath: keyPath] }, set: { value in model.updateRotation { $0[keyPath: keyPath] = value } })
    }
    private var dailyTime: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: model.rotation.settings.dailyMinute / 60,
                minute: model.rotation.settings.dailyMinute % 60, second: 0, of: .now) ?? .now
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            model.updateRotation { $0.dailyMinute = (parts.hour ?? 8) * 60 + (parts.minute ?? 0) }
        })
    }
    private var displayChoice: Binding<String> {
        Binding(get: { model.rotation.settings.allDisplays ? "all" : model.rotation.settings.screenID ?? "main" }, set: { value in
            model.updateRotation { $0.allDisplays = value == "all"; $0.screenID = ["all", "main"].contains(value) ? nil : value }
        })
    }

    var body: some View {
        TabView {
            Form {
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                }
                Toggle("登录时打开 MuseFrame", isOn: Binding(get: { loginEnabled }, set: updateLogin))
                Toggle("在菜单栏显示 MuseFrame", isOn: $showMenuBar)
                if SMAppService.mainApp.status == .requiresApproval {
                    Button("打开系统登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).tabItem { Label("通用", systemImage: "gearshape") }

            Form {
                Section {
                    Toggle("自动轮换", isOn: setting(\.enabled)).accessibilityIdentifier("rotationEnabled")
                    if model.rotation.settings.enabled || model.backgroundService.lastError != nil {
                        LabeledContent("后台", value: model.backgroundService.serviceStatus)
                            .foregroundStyle(.secondary)
                        if model.backgroundService.needsApproval {
                            Button("允许后台轮换…") { model.backgroundService.openApprovalSettings() }
                        }
                        if let error = model.backgroundService.lastError {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Picker("频率", selection: setting(\.cadence)) {
                        ForEach(RotationCadence.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("rotationCadence")
                    if model.rotation.settings.cadence == .daily {
                        DatePicker("每天", selection: dailyTime, displayedComponents: .hourAndMinute)
                    } else if model.rotation.settings.cadence == .everyHours {
                        Picker("间隔", selection: setting(\.hours)) {
                            ForEach([2, 3, 4, 6, 8, 12, 24], id: \.self) { Text("\($0) 小时").tag($0) }
                        }
                    }
                    Picker("作品来源", selection: Binding(get: { model.rotation.settings.pool }, set: { pool in
                        model.updateRotation {
                            $0.pool = pool
                            $0.filter = pool == .currentFilters ? RotationFilter(artist: model.filter.artist, movement: model.filter.movement, theme: model.filter.theme) : RotationFilter()
                        }
                    })) { ForEach(RotationPool.allCases) { Text($0.title).tag($0) } }
                    if model.rotation.settings.pool == .currentFilters {
                        LabeledContent("筛选") {
                            VStack(alignment: .trailing, spacing: 6) {
                                Text([model.rotation.settings.filter.artist, model.rotation.settings.filter.movement, model.rotation.settings.filter.theme].compactMap { $0 }.joined(separator: " · "))
                                    .lineLimit(2).foregroundStyle(.secondary)
                                Button("使用 Gallery 当前筛选") { model.captureRotationFilters() }
                            }
                        }
                    }
                }
                Section {
                    Picker("显示方式", selection: setting(\.mode)) {
                        ForEach(WallpaperMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("显示器", selection: displayChoice) {
                        Text("主显示器").tag("main")
                        ForEach(model.screens) { Text($0.name).tag($0.id) }
                        if let id = model.rotation.settings.screenID, !model.screens.contains(where: { $0.matchesIdentifier(id) }) {
                            Text("显示器已断开 · 暂用主显示器").tag(id)
                        }
                        Text("所有显示器").tag("all")
                    }
                    if model.rotation.settings.enabled, let next = model.rotation.nextDueDate {
                        LabeledContent("下一幅", value: next.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let error = model.rotation.lastError { Text(error).font(.caption).foregroundStyle(.secondary) }
                }
            }.formStyle(.grouped).tabItem { Label("壁纸", systemImage: "display") }

            Form {
                LabeledContent("已知作品", value: "\(model.artworks.count)")
                LabeledContent("图片来源", value: "The Met / Wikimedia Commons")
                TextField("策展目录地址（可选）", text: $feedAddress, prompt: Text("https://…/edition.json"))
                if let status = model.editorialStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                Button("更新馆藏目录") { Task { await model.synchronizeCatalog(force: true) } }.disabled(model.isSyncing)
                Button("清理下载的图片缓存") {
                    Task {
                        do { try await ImageCache.shared.clear(); cacheStatus = "图片缓存已清理" }
                        catch { cacheStatus = error.localizedDescription }
                    }
                }
                if let cacheStatus { Text(cacheStatus).font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).tabItem { Label("内容", systemImage: "photo") }

            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                    .scaledToFit().frame(width: 72, height: 72).accessibilityLabel("MuseFrame 应用图标")
                Text("MuseFrame").font(.system(size: 26, design: .serif))
                Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.5") · Wallpaper Collection").foregroundStyle(.secondary)
                Link("The Metropolitan Museum of Art", destination: URL(string: "https://www.metmuseum.org/about-the-met/policies-and-documents/open-access")!)
                Link("Art Institute of Chicago · Open Access", destination: URL(string: "https://www.artic.edu/open-access/open-access-images")!)
            }.font(.system(size: 12)).frame(maxWidth: .infinity, maxHeight: .infinity)
                .tabItem { Label("关于", systemImage: "info.circle") }
        }.frame(width: 560, height: 440)
    }

    private func updateLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
            loginError = nil
        } catch { loginEnabled = SMAppService.mainApp.status == .enabled; loginError = error.localizedDescription }
    }
}

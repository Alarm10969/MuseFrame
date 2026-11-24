import Foundation
import Observation
import ServiceManagement

@MainActor @Observable final class BackgroundServiceController {
    private(set) var serviceStatus = "后台轮换未启用"
    private(set) var needsApproval = false
    private(set) var lastError: String?
    private(set) var isRunning = false
    @ObservationIgnored private let managesRegistration: Bool
    @ObservationIgnored private let service = SMAppService.agent(plistName: "io.museframe.rotation.plist")
    @ObservationIgnored private var desiredEnabled = false
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var registrationError: String?
    private let buildKey = "registeredRotationHelperBuild"

    init(managesRegistration: Bool = true) { self.managesRegistration = managesRegistration }

    /// Only an explicit rotation preference drives registration; GUI Quit never unregisters it.
    /// Requests arriving during asynchronous unregistration are reconciled to the latest intent.
    func reconcile(enabled: Bool) async {
        desiredEnabled = enabled
        guard managesRegistration, !reconciling else { return }
        reconciling = true
        defer { reconciling = false; refresh() }
        var handled: Bool?
        repeat {
            let requested = desiredEnabled
            handled = requested
            do {
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
                let upgraded = UserDefaults.standard.string(forKey: buildKey).map { $0 != build } ?? false
                if !requested || upgraded {
                    if service.status == .enabled || service.status == .requiresApproval {
                        try await service.unregister()
                    }
                    UserDefaults.standard.removeObject(forKey: buildKey)
                }
                // A disable request may have arrived while the old job was being removed.
                if desiredEnabled {
                    if service.status == .notRegistered || service.status == .notFound { try service.register() }
                    if service.status == .enabled || service.status == .requiresApproval {
                        UserDefaults.standard.set(build, forKey: buildKey)
                    }
                }
                registrationError = nil
            } catch { registrationError = "后台轮换服务未能更新：\(error.localizedDescription)" }
        } while handled != desiredEnabled
    }

    func refresh() {
        guard managesRegistration else { return }
        let receipt = BackgroundHelperStatus.read()
        isRunning = receipt?.isAlive() == true
        needsApproval = service.status == .requiresApproval
        switch service.status {
        case .enabled: serviceStatus = isRunning ? "后台轮换运行中" : "后台轮换已登记，等待启动"
        case .requiresApproval: serviceStatus = "后台轮换需要系统允许"
        case .notRegistered: serviceStatus = "后台轮换未启用"
        case .notFound: serviceStatus = "后台组件不可用"
        @unknown default: serviceStatus = "后台状态暂不可用"
        }
        lastError = registrationError ?? (isRunning ? receipt?.lastError : nil)
    }

    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
}

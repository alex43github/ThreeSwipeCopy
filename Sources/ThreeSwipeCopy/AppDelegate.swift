import AppKit
import ApplicationServices
import ServiceManagement

/// 菜单栏应用入口：状态栏图标 + 三指手势监听（MultitouchSupport）+ 开机自启动开关。
@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var permissionCheckTimer: Timer?
    private let controller = GestureController()

    private var mtStarted = false
    private var wasTrusted = false

    private var enabledItem: NSMenuItem!
    private var swapItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var launchItem: NSMenuItem!

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        wasTrusted = AXIsProcessTrusted()
        Log.write("[launch] 应用启动 axTrusted=\(wasTrusted) enabled=\(controller.enabled) swap=\(controller.swapDirection)")
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        refreshPermissionItem()
        refreshLaunchItem()
        startGestureMonitoring()
        requestAccessibilityIfNeeded()

        // 定时刷新权限状态显示（手势监听本身已启动，授权只影响能否发送 ⌘C/⌘V）
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.permissionCheckTick()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionCheckTimer?.invalidate()
        MultitouchMonitor.shared.stop()
    }

    // MARK: - 状态栏与菜单

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "hand.tap.fill",
                                   accessibilityDescription: "三指复制粘贴")
        }

        let menu = NSMenu()

        let header = NSMenuItem(title: "三指复制粘贴", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        enabledItem = NSMenuItem(title: "", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        menu.addItem(enabledItem)

        swapItem = NSMenuItem(title: "", action: #selector(toggleSwap), keyEquivalent: "")
        swapItem.target = self
        menu.addItem(swapItem)

        menu.addItem(.separator())

        permissionItem = NSMenuItem(title: "", action: #selector(openPermissionSettings), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        launchItem = NSMenuItem(title: "", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        refreshStatusItems()
    }

    private func refreshStatusItems() {
        enabledItem.title = controller.enabled ? "已启用（点按暂停）" : "已暂停（点按启用）"
        enabledItem.state = controller.enabled ? .on : .off
        swapItem.title = controller.swapDirection ? "方向：下滑复制 / 上滑粘贴" : "方向：上滑复制 / 下滑粘贴"
        swapItem.state = controller.swapDirection ? .on : .off
    }

    // MARK: - 手势监听与权限

    private func permissionCheckTick() {
        let trusted = AXIsProcessTrusted()
        if trusted != wasTrusted {
            wasTrusted = trusted
            Log.write("[perm] 辅助功能授权状态变化: trusted=\(trusted)")
        }
        refreshPermissionItem()
    }

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 启动 MultitouchSupport 触控板触点监听（读取触点不需要授权；发送 ⌘C/⌘V 需要授权）
    private func startGestureMonitoring() {
        guard !mtStarted else { return }
        MultitouchMonitor.shared.onThreeFingerVerticalSwipe = { [weak self] up in
            self?.controller.handleThreeFinger(up: up)
        }
        MultitouchMonitor.shared.start()
        mtStarted = true
        refreshPermissionItem()
    }

    private func refreshPermissionItem() {
        if AXIsProcessTrusted() {
            permissionItem.title = mtStarted ? "✅ 辅助功能已授权，手势监听运行中" : "✅ 辅助功能已授权"
        } else {
            permissionItem.title = "⚠️ 需要辅助功能权限（点击去授权）"
        }
    }

    // MARK: - 菜单动作

    @objc private func toggleEnabled() {
        controller.enabled.toggle()
        refreshStatusItems()
    }

    @objc private func toggleSwap() {
        controller.swapDirection.toggle()
        refreshStatusItems()
    }

    @objc private func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            do {
                try SMAppService.mainApp.register()
            } catch {
                let alert = NSAlert()
                alert.messageText = "无法设置开机自启动"
                alert.informativeText = "请先把应用放到 /Applications 文件夹（运行 install.sh）后重试。\n\n\(error.localizedDescription)"
                alert.runModal()
            }
        }
        refreshLaunchItem()
    }

    private func refreshLaunchItem() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchItem.title = "开机自启动：已开启（点按关闭）"
            launchItem.state = .on
        case .notRegistered, .requiresApproval, .notFound:
            launchItem.title = "开机自启动：已关闭（点按开启）"
            launchItem.state = .off
        @unknown default:
            launchItem.title = "开机自启动：未知状态"
            launchItem.state = .off
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

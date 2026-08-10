import AppKit
import ApplicationServices
import ServiceManagement

/// 菜单栏应用入口：状态栏图标 + 三指手势监听（MultitouchSupport）+ 可自定义手势动作 + 开机自启动开关。
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var permissionCheckTimer: Timer?
    private let controller = GestureController()

    private var mtStarted = false
    private var wasTrusted = false

    private var enabledItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var launchItem: NSMenuItem!
    private var gestureItems: [Gesture: NSMenuItem] = [:]

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        wasTrusted = AXIsProcessTrusted()
        Log.write("[launch] 应用启动 axTrusted=\(wasTrusted) enabled=\(controller.enabled)")
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        refreshPermissionItem()
        refreshLaunchItem()
        startGestureMonitoring()
        requestAccessibilityIfNeeded()

        // 定时刷新权限状态显示（手势监听本身已启动，授权只影响能否发送快捷键）
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
        menu.delegate = self

        let header = NSMenuItem(title: "三指复制粘贴", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        enabledItem = NSMenuItem(title: "", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        menu.addItem(enabledItem)

        menu.addItem(.separator())

        // 手势设置：每个手势一个子菜单，可自定义绑定动作
        let settingsHeader = NSMenuItem(title: "手势设置", action: nil, keyEquivalent: "")
        settingsHeader.isEnabled = false
        menu.addItem(settingsHeader)

        for gesture in Gesture.allCases {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            gestureItems[gesture] = item
        }

        let resetItem = NSMenuItem(title: "恢复默认动作", action: #selector(resetActions), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

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

    /// 菜单打开前刷新（标题 + 手势子菜单，保证改动立即生效）
    func menuWillOpen(_ menu: NSMenu) {
        refreshStatusItems()
    }

    private func refreshStatusItems() {
        enabledItem.title = controller.enabled ? "已启用（点按暂停）" : "已暂停（点按启用）"
        enabledItem.state = controller.enabled ? .on : .off

        for gesture in Gesture.allCases {
            guard let item = gestureItems[gesture] else { continue }
            let current = controller.action(for: gesture)
            item.title = "\(gesture.title)：\(current.title)"
            item.submenu = buildActionSubmenu(for: gesture)
        }
    }

    /// 构建某个手势的动作选择子菜单（BTT 风格分组）
    private func buildActionSubmenu(for gesture: Gesture) -> NSMenu {
        let menu = NSMenu()
        let current = controller.action(for: gesture)

        func addAction(_ action: Action) {
            let item = NSMenuItem(title: action.title, action: #selector(selectAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ActionItemPayload(gesture: gesture, action: action)
            item.state = (action == current) ? .on : .off
            menu.addItem(item)
        }

        func addSection(_ title: String, _ actions: [Action]) {
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for a in actions { addAction(a) }
        }

        addAction(.none)
        menu.addItem(.separator())

        addSection("常用快捷键", [.copy, .paste, .cut, .undo, .redo, .selectAll,
                                   .save, .find, .deleteFile, .spotlight,
                                   .closeWindow, .hideApp, .minimizeWindow,
                                   .switchApp, .fullscreen])
        addSection("打开 App", [.openFinder, .openSafari, .openChrome, .openTerminal,
                                .openNotes, .openMail, .openMessages, .openMusic,
                                .openCalculator, .openSystemSettings])
        addSection("媒体与音量", [.mediaToggle, .mediaNext, .mediaPrev,
                                  .volumeUp, .volumeDown, .volumeMute])
        addSection("系统控制", [.missionControl, .launchpad, .showDesktop,
                               .lockScreen, .sleepDisplay, .screenshot])

        return menu
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

    /// 启动 MultitouchSupport 触控板触点监听（读取触点不需要授权；发送快捷键需要授权）
    private func startGestureMonitoring() {
        guard !mtStarted else { return }
        MultitouchMonitor.shared.onSwipe = { [weak self] direction in
            self?.controller.handle(Gesture(direction))
        }
        MultitouchMonitor.shared.onFourFingerTap = { [weak self] in
            self?.controller.handle(.fourFingerTap)
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

    @objc private func selectAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ActionItemPayload else { return }
        controller.setAction(payload.action, for: payload.gesture)
        refreshStatusItems()
    }

    @objc private func resetActions() {
        controller.resetAll()
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

/// 菜单项携带的数据：手势 + 动作
private final class ActionItemPayload: NSObject {
    let gesture: Gesture
    let action: Action
    init(gesture: Gesture, action: Action) {
        self.gesture = gesture
        self.action = action
    }
}

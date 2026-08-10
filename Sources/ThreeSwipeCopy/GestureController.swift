import AppKit
import CoreGraphics
import Darwin

/// 三指滑动方向（由 MultitouchMonitor 识别）
enum SwipeDirection {
    case up, down, left, right

    var logName: String {
        switch self {
        case .up: return "上滑"
        case .down: return "下滑"
        case .left: return "左滑"
        case .right: return "右滑"
        }
    }
}

/// 可配置的手势。
enum Gesture: String, CaseIterable {
    case swipeUp = "swipeUp"
    case swipeDown = "swipeDown"
    case swipeLeft = "swipeLeft"
    case swipeRight = "swipeRight"
    case fourFingerTap = "fourFingerTap"         // 三指按住 + 小指点按（删除）
    case twoFingerTap = "twoFingerTap"
    case twoFingerSwipeLeft = "twoFingerSwipeLeft"
    case twoFingerSwipeRight = "twoFingerSwipeRight"
    case fourFingerSwipeUp = "fourFingerSwipeUp"
    case fourFingerSwipeDown = "fourFingerSwipeDown"
    case fourFingerSwipeLeft = "fourFingerSwipeLeft"
    case fourFingerSwipeRight = "fourFingerSwipeRight"
    case fourFingerTapAll = "fourFingerTapAll"   // 四指同时轻点

    var title: String {
        switch self {
        case .swipeUp: return "三指上滑"
        case .swipeDown: return "三指下滑"
        case .swipeLeft: return "三指左滑"
        case .swipeRight: return "三指右滑"
        case .fourFingerTap: return "三指按住+小指点按"
        case .twoFingerTap: return "两指轻点"
        case .twoFingerSwipeLeft: return "两指左滑"
        case .twoFingerSwipeRight: return "两指右滑"
        case .fourFingerSwipeUp: return "四指上滑"
        case .fourFingerSwipeDown: return "四指下滑"
        case .fourFingerSwipeLeft: return "四指左滑"
        case .fourFingerSwipeRight: return "四指右滑"
        case .fourFingerTapAll: return "四指轻点"
        }
    }

    init(_ direction: SwipeDirection) {
        switch direction {
        case .up: self = .swipeUp
        case .down: self = .swipeDown
        case .left: self = .swipeLeft
        case .right: self = .swipeRight
        }
    }

    /// 四指滑动方向 → 手势
    init(fourFinger direction: SwipeDirection) {
        switch direction {
        case .up: self = .fourFingerSwipeUp
        case .down: self = .fourFingerSwipeDown
        case .left: self = .fourFingerSwipeLeft
        case .right: self = .fourFingerSwipeRight
        }
    }

    /// 两指滑动方向 → 手势（当前仅识别左右快速甩动；纵向交给系统滚动）
    init?(twoFinger direction: SwipeDirection) {
        switch direction {
        case .left: self = .twoFingerSwipeLeft
        case .right: self = .twoFingerSwipeRight
        case .up, .down: return nil
        }
    }
}

/// 动作目录（参考 BetterTouchTool 的常见动作分类）：
/// 无动作 / 常用快捷键 / 打开 App / 媒体与音量 / 系统控制。
enum Action: String, CaseIterable {

    // MARK: 无动作
    case none = "none"

    // MARK: 常用快捷键
    case copy = "copy"              // ⌘C
    case paste = "paste"            // ⌘V
    case cut = "cut"                // ⌘X
    case undo = "undo"              // ⌘Z
    case redo = "redo"              // ⌘⇧Z
    case selectAll = "selectAll"    // ⌘A
    case save = "save"              // ⌘S
    case find = "find"              // ⌘F
    case deleteFile = "deleteFile"  // ⌘⌫ 删除到废纸篓
    case spotlight = "spotlight"    // ⌘Space 聚焦搜索
    case closeWindow = "closeWindow"    // ⌘W
    case hideApp = "hideApp"            // ⌘H
    case minimizeWindow = "minimizeWindow" // ⌘M
    case switchApp = "switchApp"        // ⌘Tab
    case fullscreen = "fullscreen"      // ⌃⌘F 全屏

    // MARK: 打开常用 App
    case openFinder = "openFinder"
    case openSafari = "openSafari"
    case openChrome = "openChrome"
    case openTerminal = "openTerminal"
    case openNotes = "openNotes"
    case openMail = "openMail"
    case openMessages = "openMessages"
    case openMusic = "openMusic"
    case openCalculator = "openCalculator"
    case openSystemSettings = "openSystemSettings"
    case openCustomApp = "openCustomApp"   // 用户自己选择的任意 App（路径存 customAppPaths）

    // MARK: 媒体与音量
    case mediaToggle = "mediaToggle"  // 播放/暂停
    case mediaNext = "mediaNext"      // 下一首
    case mediaPrev = "mediaPrev"      // 上一首
    case volumeUp = "volumeUp"        // 音量+
    case volumeDown = "volumeDown"    // 音量-
    case volumeMute = "volumeMute"    // 静音/取消静音

    // MARK: 系统控制
    case missionControl = "missionControl" // 调度中心
    case launchpad = "launchpad"           // 启动台
    case showDesktop = "showDesktop"       // 显示桌面
    case lockScreen = "lockScreen"         // 锁定屏幕
    case sleepDisplay = "sleepDisplay"     // 显示屏休眠
    case screenshot = "screenshot"         // 区域截屏

    /// 菜单分组名（用于子菜单里的分类标题），nil = 不分组
    enum Section: String, CaseIterable {
        case shortcuts = "常用快捷键"
        case apps = "打开 App"
        case media = "媒体与音量"
        case system = "系统控制"
    }

    var section: Section? {
        switch self {
        case .none: return nil
        case .copy, .paste, .cut, .undo, .redo, .selectAll, .save, .find,
             .deleteFile, .spotlight, .closeWindow, .hideApp, .minimizeWindow,
             .switchApp, .fullscreen:
            return .shortcuts
        case .openFinder, .openSafari, .openChrome, .openTerminal, .openNotes,
             .openMail, .openMessages, .openMusic, .openCalculator, .openSystemSettings,
             .openCustomApp:
            return .apps
        case .mediaToggle, .mediaNext, .mediaPrev, .volumeUp, .volumeDown, .volumeMute:
            return .media
        case .missionControl, .launchpad, .showDesktop, .lockScreen,
             .sleepDisplay, .screenshot:
            return .system
        }
    }

    var title: String {
        switch self {
        case .none: return "无动作"
        case .copy: return "复制（⌘C）"
        case .paste: return "粘贴（⌘V）"
        case .cut: return "剪切（⌘X）"
        case .undo: return "撤销（⌘Z）"
        case .redo: return "重做（⌘⇧Z）"
        case .selectAll: return "全选（⌘A）"
        case .save: return "保存（⌘S）"
        case .find: return "查找（⌘F）"
        case .deleteFile: return "删除到废纸篓（⌘⌫）"
        case .spotlight: return "聚焦搜索（⌘Space）"
        case .closeWindow: return "关闭窗口（⌘W）"
        case .hideApp: return "隐藏当前 App（⌘H）"
        case .minimizeWindow: return "最小化（⌘M）"
        case .switchApp: return "切换 App（⌘Tab）"
        case .fullscreen: return "全屏（⌃⌘F）"
        case .openFinder: return "打开访达"
        case .openSafari: return "打开 Safari"
        case .openChrome: return "打开 Chrome"
        case .openTerminal: return "打开终端"
        case .openNotes: return "打开备忘录"
        case .openMail: return "打开邮件"
        case .openMessages: return "打开信息"
        case .openMusic: return "打开音乐"
        case .openCalculator: return "打开计算器"
        case .openSystemSettings: return "打开系统设置"
        case .openCustomApp: return "自定义 App…"
        case .mediaToggle: return "播放 / 暂停"
        case .mediaNext: return "下一首"
        case .mediaPrev: return "上一首"
        case .volumeUp: return "音量 +"
        case .volumeDown: return "音量 -"
        case .volumeMute: return "静音 / 取消静音"
        case .missionControl: return "调度中心"
        case .launchpad: return "启动台"
        case .showDesktop: return "显示桌面"
        case .lockScreen: return "锁定屏幕"
        case .sleepDisplay: return "显示屏休眠"
        case .screenshot: return "区域截屏（⌘⇧4）"
        }
    }

    /// 应用动作对应的 Bundle ID；非应用动作返回 nil
    var appBundleID: String? {
        switch self {
        case .openFinder: return "com.apple.finder"
        case .openSafari: return "com.apple.Safari"
        case .openChrome: return "com.google.Chrome"
        case .openTerminal: return "com.apple.Terminal"
        case .openNotes: return "com.apple.Notes"
        case .openMail: return "com.apple.mail"
        case .openMessages: return "com.apple.MobileSMS"
        case .openMusic: return "com.apple.Music"
        case .openCalculator: return "com.apple.calculator"
        case .openSystemSettings: return "com.apple.systempreferences"
        default: return nil
        }
    }
}

/// 手势策略与动作执行：把 MultitouchMonitor 识别的手势映射到用户配置的动作。
final class GestureController {

    private enum Keys {
        static let enabled = "enabled"
        static let gestureActions = "gestureActions"
        static let customAppPaths = "customAppPaths"
    }

    /// 是否启用（菜单可暂停）
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Keys.enabled) }
    }

    /// 手势 → 动作 配置（只存用户改过的，未配置的用默认值）
    private var actionMap: [Gesture: Action]

    /// 防抖冷却：两次触发之间的最小间隔（秒）
    private let cooldown: TimeInterval = 0.45
    private var lastTriggerAt: CFTimeInterval = 0

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        var map: [Gesture: Action] = [:]
        if let stored = defaults.dictionary(forKey: Keys.gestureActions) as? [String: String] {
            for gesture in Gesture.allCases {
                if let raw = stored[gesture.rawValue], let action = Action(rawValue: raw) {
                    map[gesture] = action
                }
            }
        }
        actionMap = map
    }

    /// 读取某个手势当前绑定的动作
    func action(for gesture: Gesture) -> Action {
        actionMap[gesture] ?? GestureController.defaultAction(for: gesture)
    }

    /// 设置手势绑定的动作（持久化到 UserDefaults）
    func setAction(_ action: Action, for gesture: Gesture) {
        // 防止把未配置自定义 App 的手势绑定成 .openCustomApp（应通过 NSOpenPanel 选择）
        if action == .openCustomApp && customAppPath(for: gesture) == nil {
            Log.write("[cfg] 忽略：手势「\(gesture.title)」未选择自定义 App")
            return
        }
        actionMap[gesture] = action
        var stored = UserDefaults.standard.dictionary(forKey: Keys.gestureActions) as? [String: String] ?? [:]
        stored[gesture.rawValue] = action.rawValue
        UserDefaults.standard.set(stored, forKey: Keys.gestureActions)
        Log.write("[cfg] 手势「\(gesture.title)」→ \(action.title)")
    }

    // MARK: - 自定义 App（用户自己选择的任意 App）

    /// 读取手势绑定的自定义 App 绝对路径；未设置返回 nil
    func customAppPath(for gesture: Gesture) -> String? {
        (UserDefaults.standard.dictionary(forKey: Keys.customAppPaths) as? [String: String])?[gesture.rawValue]
    }

    /// 读取自定义 App 的显示名（优先 Info.plist 的 CFBundleName，否则用文件名）
    func customAppName(for gesture: Gesture) -> String? {
        guard let path = customAppPath(for: gesture) else { return nil }
        return Self.displayName(ofAppAt: path)
    }

    /// 绑定手势 → 打开指定路径的 App（同时把动作设为 .openCustomApp）
    func setCustomApp(path: String, for gesture: Gesture) {
        var stored = UserDefaults.standard.dictionary(forKey: Keys.customAppPaths) as? [String: String] ?? [:]
        stored[gesture.rawValue] = path
        UserDefaults.standard.set(stored, forKey: Keys.customAppPaths)
        actionMap[gesture] = .openCustomApp
        Log.write("[cfg] 手势「\(gesture.title)」→ 打开自定义 App：\(Self.displayName(ofAppAt: path)) (\(path))")
    }

    /// 清除手势绑定的自定义 App；若该手势当前绑定的正是打开自定义 App，则恢复为「无动作」
    func clearCustomApp(for gesture: Gesture) {
        var stored = UserDefaults.standard.dictionary(forKey: Keys.customAppPaths) as? [String: String] ?? [:]
        stored.removeValue(forKey: gesture.rawValue)
        UserDefaults.standard.set(stored, forKey: Keys.customAppPaths)
        if actionMap[gesture] == .openCustomApp {
            actionMap[gesture] = Action.none
        }
        Log.write("[cfg] 手势「\(gesture.title)」已清除自定义 App")
    }

    /// 根据 .app 绝对路径取显示名
    static func displayName(ofAppAt path: String) -> String {
        if let bundle = Bundle(path: path),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }
        return (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    }

    /// 恢复默认动作
    func resetAll() {
        actionMap = [:]
        UserDefaults.standard.removeObject(forKey: Keys.gestureActions)
        UserDefaults.standard.removeObject(forKey: Keys.customAppPaths)
        Log.write("[cfg] 已恢复默认手势动作")
    }

    static func defaultAction(for gesture: Gesture) -> Action {
        switch gesture {
        case .swipeUp: return .copy
        case .swipeDown: return .paste
        case .swipeLeft: return .none
        case .swipeRight: return .none
        case .fourFingerTap: return .deleteFile
        case .twoFingerTap, .twoFingerSwipeLeft, .twoFingerSwipeRight,
             .fourFingerSwipeUp, .fourFingerSwipeDown, .fourFingerSwipeLeft,
             .fourFingerSwipeRight, .fourFingerTapAll:
            return .none   // 默认不占用，避免与系统/滚动冲突，用户需要时再绑定
        }
    }

    /// 手势已确认 → 执行绑定动作（带冷却）
    func handle(_ gesture: Gesture) {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastTriggerAt > cooldown else { return }
        lastTriggerAt = now
        perform(action(for: gesture), gesture: gesture)
    }

    // MARK: - 动作执行

    private func perform(_ action: Action, gesture: Gesture) {
        switch action {
        case .none:
            return
        case .openCustomApp:
            openCustomApp(for: gesture)

        // 常用快捷键
        case .copy:      logAndSend("复制 ⌘C", 8, .maskCommand)
        case .paste:     logAndSend("粘贴 ⌘V", 9, .maskCommand)
        case .cut:       logAndSend("剪切 ⌘X", 7, .maskCommand)
        case .undo:      logAndSend("撤销 ⌘Z", 6, .maskCommand)
        case .redo:      logAndSend("重做 ⌘⇧Z", 6, [.maskCommand, .maskShift])
        case .selectAll: logAndSend("全选 ⌘A", 0, .maskCommand)
        case .save:      logAndSend("保存 ⌘S", 1, .maskCommand)
        case .find:      logAndSend("查找 ⌘F", 3, .maskCommand)
        case .deleteFile: logAndSend("删除到废纸篓 ⌘⌫", 51, .maskCommand)
        case .spotlight: logAndSend("聚焦搜索 ⌘Space", 49, .maskCommand)
        case .closeWindow: logAndSend("关闭窗口 ⌘W", 13, .maskCommand)
        case .hideApp:   logAndSend("隐藏当前 App ⌘H", 4, .maskCommand)
        case .minimizeWindow: logAndSend("最小化 ⌘M", 46, .maskCommand)
        case .switchApp: logAndSend("切换 App ⌘Tab", 48, .maskCommand)
        case .fullscreen: logAndSend("全屏 ⌃⌘F", 3, [.maskControl, .maskCommand])

        // 打开 App
        case .openFinder, .openSafari, .openChrome, .openTerminal, .openNotes,
             .openMail, .openMessages, .openMusic, .openCalculator, .openSystemSettings:
            openApp(action)

        // 媒体与音量
        case .mediaToggle: logMedia("播放/暂停"); MediaRemote.send(2)
        case .mediaNext:   logMedia("下一首");     MediaRemote.send(4)
        case .mediaPrev:   logMedia("上一首");     MediaRemote.send(5)
        case .volumeUp:    logVolume("音量 +");    Volume.set(delta: 6)
        case .volumeDown:  logVolume("音量 -");    Volume.set(delta: -6)
        case .volumeMute:  logVolume("静音切换");  Volume.toggleMute()

        // 系统控制
        case .missionControl: logSystem("调度中心");   System.openAppNamed("Mission Control")
        case .launchpad:      logSystem("启动台");     System.openAppNamed("Launchpad")
        case .showDesktop:    logSystem("显示桌面");   sendKey(99, flags: .maskCommand)   // ⌘F3
        case .lockScreen:     logSystem("锁定屏幕");   sendKey(12, flags: [.maskControl, .maskCommand]) // ⌃⌘Q
        case .sleepDisplay:   logSystem("显示屏休眠"); System.run("/usr/bin/pmset", ["displaysleepnow"])
        case .screenshot:     logSystem("区域截屏");   sendKey(21, flags: [.maskCommand, .maskShift])  // ⌘⇧4
        }
    }

    // MARK: - 执行辅助

    private func logAndSend(_ name: String, _ keycode: CGKeyCode, _ flags: CGEventFlags) {
        Log.write("[action] \(name)")
        sendKey(keycode, flags: flags)
    }

    private func logMedia(_ name: String) { Log.write("[action] 媒体：\(name)") }
    private func logVolume(_ name: String) { Log.write("[action] 音量：\(name)") }
    private func logSystem(_ name: String) { Log.write("[action] 系统：\(name)") }

    /// 发送指定 flags + keycode 的按下与抬起事件
    private func sendKey(_ keycode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Log.write("[action] CGEventSource 创建失败")
            return
        }
        let down = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// 通过 Bundle ID 打开应用（先定位，再打开）
    private func openApp(_ action: Action) {
        guard let bundleID = action.appBundleID else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Log.write("[action] 未找到应用：\(action.title) (\(bundleID))")
            return
        }
        NSWorkspace.shared.open(url)
        Log.write("[action] 打开 \(action.title)")
    }

    /// 打开手势绑定的自定义 App（绝对路径）
    private func openCustomApp(for gesture: Gesture) {
        guard let path = customAppPath(for: gesture) else {
            Log.write("[action] 自定义 App 路径未设置（\(gesture.title)）")
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            Log.write("[action] 自定义 App 不存在：\(path)")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        Log.write("[action] 打开自定义 App：\(Self.displayName(ofAppAt: path))")
    }
}

// MARK: - 媒体控制（MediaRemote 私有框架，BetterTouchTool 同款）

private enum MediaRemote {
    private typealias SendCommandFn = @convention(c) (Int32, AnyObject?) -> Void

    private static let sendCommand: SendCommandFn? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_LAZY | RTLD_GLOBAL
        ) else {
            Log.write("[action] dlopen MediaRemote 失败: \(String(cString: dlerror()))")
            return nil
        }
        guard let sym = dlsym(handle, "MRMediaRemoteSendCommand") else {
            Log.write("[action] dlsym MRMediaRemoteSendCommand 失败")
            return nil
        }
        return unsafeBitCast(sym, to: SendCommandFn.self)
    }()

    /// command: 0=播放 1=暂停 2=播放/暂停 4=下一首 5=上一首
    static func send(_ command: Int32) {
        guard let fn = sendCommand else {
            Log.write("[action] MediaRemote 不可用")
            return
        }
        fn(command, nil)
    }
}

// MARK: - 音量控制（AppleScript，公开 API）

private enum Volume {
    static func set(delta: Int32) {
        run("set v to output volume of (get volume settings)\n" +
            "set volume output volume (v + \(delta))\n")
    }

    static func toggleMute() {
        run("if output muted of (get volume settings) then\n" +
            "  set volume output muted false\n" +
            "else\n" +
            "  set volume output muted true\n" +
            "end if\n")
    }

    private static func run(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let e = error {
            Log.write("[action] AppleScript 错误: \(e)")
        }
    }
}

// MARK: - 系统命令（open / pmset）

private enum System {
    /// 打开系统自带 App（按显示名，例如 Mission Control / Launchpad）
    static func openAppNamed(_ name: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", name]
        try? p.run()
    }

    static func run(_ executable: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        try? p.run()
    }
}

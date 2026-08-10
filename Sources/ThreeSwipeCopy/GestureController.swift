import AppKit
import CoreGraphics
import QuartzCore

/// 手势策略：三指上滑 = 复制（⌘C），三指下滑 = 粘贴（⌘V）。
/// 手势本身由 MultitouchMonitor（MultitouchSupport 私有框架）负责识别，
/// 这里只负责触发按键与防抖。
final class GestureController {

    private enum Keys {
        static let enabled = "enabled"
        static let swapDirection = "swapDirection"
        static let deleteEnabled = "deleteEnabled"
    }

    /// 是否启用（菜单可暂停）
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Keys.enabled) }
    }

    /// 是否交换方向（部分触控板/系统设置下上下方向相反时使用）
    var swapDirection: Bool {
        didSet { UserDefaults.standard.set(swapDirection, forKey: Keys.swapDirection) }
    }

    /// 是否启用「三指按住 + 第四指点按 = 删除到废纸篓」（菜单可开关）
    var deleteEnabled: Bool {
        didSet { UserDefaults.standard.set(deleteEnabled, forKey: Keys.deleteEnabled) }
    }

    /// 防抖冷却：两次触发之间的最小间隔（秒）
    private let cooldown: TimeInterval = 0.45
    private var lastTriggerAt: CFTimeInterval = 0

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        swapDirection = defaults.object(forKey: Keys.swapDirection) as? Bool ?? false
        deleteEnabled = defaults.object(forKey: Keys.deleteEnabled) as? Bool ?? true
    }

    /// MultitouchSupport 通道回调：三指纵向滑动已确认。
    /// - Parameter up: true = 上滑（默认复制），false = 下滑（默认粘贴）
    func handleThreeFinger(up: Bool) {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastTriggerAt > cooldown else { return }
        lastTriggerAt = now

        let action: Action = up ? (swapDirection ? .paste : .copy)
                                : (swapDirection ? .copy : .paste)
        perform(action)
    }

    /// MultitouchSupport 通道回调：三指按住 + 第四指点按已确认。
    /// 触发「移到废纸篓」（⌘⌫），与 Finder 中删除选中文件一致。
    func handleFourFingerTap() {
        guard enabled, deleteEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastTriggerAt > cooldown else { return }
        lastTriggerAt = now
        perform(.delete)
    }

    // MARK: - 按键动作

    private enum Action {
        case copy
        case paste
        case delete
    }

    private func perform(_ action: Action) {
        switch action {
        case .copy:
            Log.write("[action] 发送 ⌘C (keycode 8)")
            sendCommandKey(keycode: 8)
        case .paste:
            Log.write("[action] 发送 ⌘V (keycode 9)")
            sendCommandKey(keycode: 9)
        case .delete:
            Log.write("[action] 发送 ⌘⌫ (keycode 51)")
            sendCommandKey(keycode: 51)
        }
    }

    /// 发送 ⌘ + 指定 keycode 的按下与抬起事件
    private func sendCommandKey(keycode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            Log.write("[action] CGEventSource 创建失败")
            return
        }
        let down = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        Log.write("[action] 已投递 keyDown/keyUp")
    }
}

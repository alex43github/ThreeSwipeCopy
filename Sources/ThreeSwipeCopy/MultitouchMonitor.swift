import Foundation
import Darwin

// MARK: - MultitouchSupport 私有框架（dlsym 动态加载，BetterTouchTool / Jitouch 同款底层）

private typealias MTContactCallback = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
private typealias MTDeviceCreateDefaultFn = @convention(c) () -> UnsafeMutableRawPointer?
private typealias MTDeviceCreateListFn = @convention(c) () -> CFMutableArray?
private typealias MTRegisterContactFrameCallbackFn = @convention(c) (UnsafeMutableRawPointer?, MTContactCallback) -> Int32
private typealias MTDeviceStartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
private typealias MTDeviceStopFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32

/// 通过 MultitouchSupport 私有框架读取触控板原始触点，
/// 检测「三指上滑 / 三指下滑」并回调给上层。
/// 这是 BetterTouchTool / Jitouch 使用的底层方案，能拿到 CGEventTap 拿不到的触点位移。
final class MultitouchMonitor {

    static let shared = MultitouchMonitor()

    /// 三指纵向滑动已确认：true = 上滑，false = 下滑
    var onThreeFingerVerticalSwipe: ((_ up: Bool) -> Void)?

    // MARK: - 私有 API 符号（惰性加载一次）

    private struct Symbols {
        let deviceCreateList: MTDeviceCreateListFn
        let deviceCreateDefault: MTDeviceCreateDefaultFn
        let registerCallback: MTRegisterContactFrameCallbackFn
        let deviceStart: MTDeviceStartFn
        let deviceStop: MTDeviceStopFn

        init?() {
            guard let handle = dlopen(
                "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
                RTLD_LAZY | RTLD_GLOBAL
            ) else {
                Log.write("[mt] dlopen MultitouchSupport 失败: \(String(cString: dlerror()))")
                return nil
            }
            guard let s1 = dlsym(handle, "MTDeviceCreateList"),
                  let s2 = dlsym(handle, "MTDeviceCreateDefault"),
                  let s3 = dlsym(handle, "MTRegisterContactFrameCallback"),
                  let s4 = dlsym(handle, "MTDeviceStart"),
                  let s5 = dlsym(handle, "MTDeviceStop") else {
                Log.write("[mt] dlsym 符号缺失")
                return nil
            }
            deviceCreateList = unsafeBitCast(s1, to: MTDeviceCreateListFn.self)
            deviceCreateDefault = unsafeBitCast(s2, to: MTDeviceCreateDefaultFn.self)
            registerCallback = unsafeBitCast(s3, to: MTRegisterContactFrameCallbackFn.self)
            deviceStart = unsafeBitCast(s4, to: MTDeviceStartFn.self)
            deviceStop = unsafeBitCast(s5, to: MTDeviceStopFn.self)
        }
    }

    private var symbols: Symbols?
    private var started = false
    private var callback: MTContactCallback?
    private var devices: [UnsafeMutableRawPointer] = []

    // MARK: - 触点与手势跟踪状态

    private struct Touch {
        let fingerId: Int32
        let state: Int32
        let x: Float
        let y: Float
    }

    /// 会话内每个手指的起点位置
    private struct FingerTrack {
        let startX: Float
        let startY: Float
    }

    private let threshold: Float = 0.10        // 归一化位移阈值（三指平均位移）
    private let minPerFingerMove: Float = 0.02 // 每根手指至少移动这么多，防止“两指滚动+一指悬停”误触发
    private let cooldown: TimeInterval = 0.6   // 两次触发最小间隔
    private var session: [Int32: FingerTrack]?
    private var lastFireAt: TimeInterval = 0
    private var didLogFirstFrame = false

    // MARK: - 启动 / 停止

    func start() {
        guard !started else { return }
        guard let symbols = Symbols() else { return }
        self.symbols = symbols

        // @convention(c) 回调不能捕获上下文，通过共享单例转发
        let callback: MTContactCallback = { _, rawPtr, count, _, _ in
            MultitouchMonitor.shared.handleFrame(rawPtr, count: Int(count))
            return 0
        }
        self.callback = callback

        var registered = 0
        // 优先遍历所有设备（外接触控板/鼠标也能覆盖），回退到默认设备
        if let list = symbols.deviceCreateList() {
            let n = CFArrayGetCount(list)
            for i in 0..<n {
                if let ptr = CFArrayGetValueAtIndex(list, i) {
                    let device = UnsafeMutableRawPointer(mutating: ptr)
                    _ = symbols.registerCallback(device, callback)
                    let startCode = symbols.deviceStart(device, 0)
                    Log.write("[mt] 注册设备 \(i)/\(n) start=\(startCode)")
                    devices.append(device)
                    registered += 1
                }
            }
        }
        if registered == 0 {
            if let device = symbols.deviceCreateDefault() {
                _ = symbols.registerCallback(device, callback)
                let startCode = symbols.deviceStart(device, 0)
                Log.write("[mt] 默认设备注册 start=\(startCode)")
                devices.append(device)
                registered = 1
            }
        }
        started = registered > 0
        Log.write(registered > 0 ? "[mt] 触控板监听启动成功（\(registered) 个设备）" : "[mt] 未找到可用触控板设备")
    }

    func stop() {
        guard started, let symbols = symbols else { return }
        for device in devices {
            _ = symbols.deviceStop(device, 0)
        }
        devices.removeAll()
        started = false
        Log.write("[mt] 监听已停止")
    }

    // MARK: - 帧处理

    private func handleFrame(_ rawPtr: UnsafeMutableRawPointer?, count: Int) {
        guard let rawPtr = rawPtr, count > 0 else { return }
        // Finger 结构（Karabiner MultitouchPrivate.h，64 位）：96 字节。
        // 关键字段偏移：state@20、fingerId@24、x@32、y@36（normalized 0~1 坐标）
        let base = rawPtr.bindMemory(to: UInt8.self, capacity: count * 96)
        var touches: [Touch] = []
        for i in 0..<count {
            let p = UnsafeRawPointer(base).advanced(by: i * 96)
            let state = p.load(fromByteOffset: 20, as: Int32.self)
            guard state != 0 else { continue }
            let fingerId = p.load(fromByteOffset: 24, as: Int32.self)
            let x = p.load(fromByteOffset: 32, as: Float.self)
            let y = p.load(fromByteOffset: 36, as: Float.self)
            touches.append(Touch(fingerId: fingerId, state: state, x: x, y: y))
        }

        // 首次有效帧打印一次原始数据，便于确认结构体布局是否正确
        if !didLogFirstFrame && !touches.isEmpty {
            didLogFirstFrame = true
            let sample = touches.prefix(3).map {
                String(format: "id=%d st=%d x=%.2f y=%.2f", $0.fingerId, $0.state, $0.x, $0.y)
            }
            Log.write("[mt] 首帧有效触点 count=\(touches.count) [\(sample.joined(separator: ", "))]")
        }

        process(touches: touches)
    }

    private func process(touches: [Touch]) {
        // 严格三指才判定；手指数变化时重置会话
        guard touches.count == 3 else {
            session = nil
            return
        }

        // 首次进入三指状态：建立会话，记录每根手指的起点
        if session == nil {
            var s: [Int32: FingerTrack] = [:]
            for t in touches { s[t.fingerId] = FingerTrack(startX: t.x, startY: t.y) }
            session = s
            return
        }

        guard let s = session else { return }

        // 手指集合发生变化（抬起/落下）→ 重建会话
        let currentIDs = Set(touches.map(\.fingerId))
        guard currentIDs == Set(s.keys) else {
            session = nil
            return
        }

        // 计算每根手指相对会话起点的位移
        var totalDX: [Float] = []
        var totalDY: [Float] = []
        for t in touches {
            guard let track = session?[t.fingerId] else { return }
            totalDX.append(t.x - track.startX)
            totalDY.append(t.y - track.startY)
        }
        guard totalDX.count == 3, totalDY.count == 3 else { return }

        // 防误触 1：三根手指必须都在移动（两指滚动+一指悬停时，悬停指位移≈0）
        guard totalDY.allSatisfy({ abs($0) >= minPerFingerMove }) else { return }

        let avgX = totalDX.reduce(0, +) / 3
        let avgY = totalDY.reduce(0, +) / 3

        // 防误触 2：以纵向为主（三指左右滑是切换应用等系统手势，不做处理）
        guard abs(avgY) > abs(avgX) else { return }

        // 方向一致性：三指同向才算一次滑动
        let signY = Set(totalDY.map { $0 > 0 })
        guard signY.count == 1 else { return }

        guard abs(avgY) >= threshold else { return }

        // 触控板归一化坐标：本机实测 y 增大 = 向屏幕上方滑；若方向反了可在菜单里交换
        let up = avgY > 0
        fire(up: up)
        session = nil
    }

    private func fire(up: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFireAt > cooldown else { return }
        lastFireAt = now
        Log.write("[mt] 三指\(up ? "上滑" : "下滑") 已确认")
        onThreeFingerVerticalSwipe?(up)
    }
}

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

    /// 三指滑动已确认：方向（上 / 下 / 左 / 右）
    var onSwipe: ((_ direction: SwipeDirection) -> Void)?

    /// 三指按住 + 第四指点按（轻点）已确认
    var onFourFingerTap: (() -> Void)?

    /// 两指轻点已确认
    var onTwoFingerTap: (() -> Void)?

    /// 两指横向滑动（快速甩动）已确认：左 / 右
    var onTwoFingerSwipe: ((_ direction: SwipeDirection) -> Void)?

    /// 四指滑动已确认：方向（上 / 下 / 左 / 右）
    var onFourFingerSwipe: ((_ direction: SwipeDirection) -> Void)?

    /// 四指同时轻点已确认
    var onFourFingerTapAll: (() -> Void)?

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
        // 调试：触点集合（数量/手指/状态）变化时打印一行，用于排查四指手势
        debugFrame(touches)
        // 各手势独立检测、互不干扰；已有三指逻辑勿改
        handleFourFingerSwipe(touches: touches)
        handleFourFingerTapAll(touches: touches)
        handleTwoFingerSwipe(touches: touches)
        handleTwoFingerTap(touches: touches)
        handleFourFingerTap(touches: touches)
        handleThreeFingerSwipe(touches: touches)
    }

    /// 调试日志：仅当触点集合（数量 / 手指 id / 状态）变化时输出，避免刷屏
    private var lastDebugSig = ""
    private func debugFrame(_ touches: [Touch]) {
        let sig = touches.map { "\($0.fingerId):\($0.state)" }.sorted().joined(separator: ",")
        guard sig != lastDebugSig else { return }
        lastDebugSig = sig
        let pos = touches.prefix(4).map { String(format: "%.2f/%.2f", $0.x, $0.y) }.joined(separator: " ")
        Log.write("[mt] debug count=\(touches.count) [\(sig)] pos=[\(pos)]")
    }

    // MARK: - 三指滑动

    /// 识别三指上/下/左/右滑动。以位移大的方向为主轴判定；
    /// 注意：三指左右滑默认被系统用于「在全屏 App 之间切换」，若用户想用手势绑定
    /// 左右动作，需要在 系统设置 → 触控板 → 更多手势 里关闭该系统的三指手势。
    private func handleThreeFingerSwipe(touches: [Touch]) {
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

        let avgX = totalDX.reduce(0, +) / 3
        let avgY = totalDY.reduce(0, +) / 3

        // 主轴判定：位移大的方向为主
        let verticalDominant = abs(avgY) > abs(avgX)

        if verticalDominant {
            // 防误触 1：三根手指纵向必须都在移动（两指滚动+一指悬停时，悬停指位移≈0）
            guard totalDY.allSatisfy({ abs($0) >= minPerFingerMove }) else { return }
            // 方向一致性：三指同向才算一次滑动
            let signY = Set(totalDY.map { $0 > 0 })
            guard signY.count == 1 else { return }
            guard abs(avgY) >= threshold else { return }
            fire(avgY > 0 ? .up : .down)
        } else {
            // 横向滑动同理：三指横向必须都在移动
            guard totalDX.allSatisfy({ abs($0) >= minPerFingerMove }) else { return }
            let signX = Set(totalDX.map { $0 > 0 })
            guard signX.count == 1 else { return }
            guard abs(avgX) >= threshold else { return }
            fire(avgX > 0 ? .right : .left)
        }
        session = nil
    }

    private func fire(_ direction: SwipeDirection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFireAt > cooldown else { return }
        lastFireAt = now
        Log.write("[mt] 三指\(direction.logName) 已确认")
        onSwipe?(direction)
    }

    // MARK: - 四指滑动

    /// 四指滑动会话（独立于三指会话：四指落地时三指会话会被清掉）
    private var fourSwipeSession: [Int32: FingerTrack]?
    private var lastFourSwipeFireAt: TimeInterval = 0
    private let fourSwipeThreshold: Float = 0.09        // 归一化平均位移阈值
    private let fourSwipeMinPerFingerMove: Float = 0.02 // 每指至少移动这么多
    private let fourSwipeCooldown: TimeInterval = 0.6

    /// 识别四指上/下/左/右滑动。系统默认把四指上/下滑用于「调度中心 / 显示桌面」、
    /// 左右滑用于「在全屏 App 之间切换」，若用户想绑定四指滑动，需在
    /// 系统设置 → 触控板 → 更多手势 里关闭对应的系统手势。
    private func handleFourFingerSwipe(touches: [Touch]) {
        guard touches.count == 4 else {
            fourSwipeSession = nil
            return
        }

        if fourSwipeSession == nil {
            var s: [Int32: FingerTrack] = [:]
            for t in touches { s[t.fingerId] = FingerTrack(startX: t.x, startY: t.y) }
            fourSwipeSession = s
            return
        }

        guard let s = fourSwipeSession else { return }
        let currentIDs = Set(touches.map(\.fingerId))
        guard currentIDs == Set(s.keys) else {
            fourSwipeSession = nil
            return
        }

        var totalDX: [Float] = []
        var totalDY: [Float] = []
        for t in touches {
            guard let track = fourSwipeSession?[t.fingerId] else { return }
            totalDX.append(t.x - track.startX)
            totalDY.append(t.y - track.startY)
        }
        guard totalDX.count == 4, totalDY.count == 4 else { return }

        let avgX = totalDX.reduce(0, +) / 4
        let avgY = totalDY.reduce(0, +) / 4
        let verticalDominant = abs(avgY) > abs(avgX)

        if verticalDominant {
            guard totalDY.allSatisfy({ abs($0) >= fourSwipeMinPerFingerMove }) else { return }
            let signY = Set(totalDY.map { $0 > 0 })
            guard signY.count == 1 else { return }
            guard abs(avgY) >= fourSwipeThreshold else { return }
            fireFourSwipe(avgY > 0 ? .up : .down)
        } else {
            guard totalDX.allSatisfy({ abs($0) >= fourSwipeMinPerFingerMove }) else { return }
            let signX = Set(totalDX.map { $0 > 0 })
            guard signX.count == 1 else { return }
            guard abs(avgX) >= fourSwipeThreshold else { return }
            fireFourSwipe(avgX > 0 ? .right : .left)
        }
        fourSwipeSession = nil
    }

    private func fireFourSwipe(_ direction: SwipeDirection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFourSwipeFireAt > fourSwipeCooldown else { return }
        lastFourSwipeFireAt = now
        Log.write("[mt] 四指\(direction.logName) 已确认")
        onFourFingerSwipe?(direction)
    }

    // MARK: - 四指同时轻点

    /// 四指轻点状态机：四指几乎同时落下 → 基本静止 → 全部抬起 → 判定轻点。
    /// 若位移超过阈值则判为滑动并放弃轻点；若先出现抬起又落回则取消。
    private struct FourTapAllState {
        let beganAt: TimeInterval          // 4 指全部落下的时刻
        let startPositions: [(Float, Float)]
        var liftStarted = false
        var liftStartedAt: TimeInterval?
    }

    private var fourTapAllState: FourTapAllState?
    private var lastFourTapAllFireAt: TimeInterval = 0
    private var lastDownBeganAt: TimeInterval?    // 本次落指（0→有触点）起点，用于判断“几乎同时落下”
    private var prevFourTapAllCount = -1
    private let fourTapAllWindow: TimeInterval = 0.6     // 落下→全部抬起的最长间隔
    private let fourTapAllLiftWindow: TimeInterval = 0.25 // 开始抬起→全部抬起的最长间隔
    private let fourTapAllLandWindow: TimeInterval = 0.15 // 4 指须在首指落下后这么短时间内到齐
    private let fourTapAllDrift: Float = 0.045           // 允许的位移（超过视为滑动）
    private let fourTapAllCooldown: TimeInterval = 0.6

    private func handleFourFingerTapAll(touches: [Touch]) {
        let now = ProcessInfo.processInfo.systemUptime
        let count = touches.count

        // 跟踪本次落指起点（只有回到 0 触点才重置）
        if count == 0 {
            lastDownBeganAt = nil
        } else if lastDownBeganAt == nil {
            lastDownBeganAt = now
        }

        let pos = positions(touches)

        if let st = fourTapAllState {
            switch count {
            case 4:
                // 仍全按：位移过大→滑动；按住超时→取消；抬起后又落回→取消
                if !match(st.startPositions, pos, tolerance: fourTapAllDrift) {
                    Log.write("[mt] 四指轻点：位移过大，取消（按滑动处理）")
                    fourTapAllState = nil
                } else if now - st.beganAt > fourTapAllWindow {
                    Log.write("[mt] 四指轻点：按住超时，取消")
                    fourTapAllState = nil
                } else if st.liftStarted {
                    Log.write("[mt] 四指轻点：抬起后又落回，取消")
                    fourTapAllState = nil
                }
            case 0:
                fourTapAllState = nil
                let total = now - st.beganAt
                // 四根手指可能同一帧同时抬起（没有经过 1~3 指的中间帧），也算有效轻点
                let liftValid = st.liftStartedAt.map { now - $0 <= fourTapAllLiftWindow } ?? true
                if total <= fourTapAllWindow && liftValid {
                    fireFourTapAll()
                } else {
                    Log.write("[mt] 四指轻点未通过: total=\(String(format: "%.2f", total))")
                }
            default:
                // 1~3：正在抬起
                if !st.liftStarted {
                    var s = st
                    s.liftStarted = true
                    s.liftStartedAt = now
                    fourTapAllState = s
                }
            }
            prevFourTapAllCount = count
            return
        }

        // 无状态：触点数量增加到 4 且四指几乎同时落下 → 建立候选
        // （避免把「三指按住+第四指点按」的删除手势误判成四指轻点）
        let increased = count > prevFourTapAllCount
        if count == 4 && increased,
           let landed = lastDownBeganAt, now - landed <= fourTapAllLandWindow {
            fourTapAllState = FourTapAllState(beganAt: now, startPositions: pos)
            Log.write("[mt] 四指轻点候选建立（落地间隔 \(String(format: "%.3f", now - landed))s）")
        }
        prevFourTapAllCount = count
    }

    private func fireFourTapAll() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFourTapAllFireAt > fourTapAllCooldown else { return }
        lastFourTapAllFireAt = now
        Log.write("[mt] 四指轻点 已确认")
        onFourFingerTapAll?()
    }

    // MARK: - 两指轻点

    /// 两指轻点状态机：两指落下 → 基本静止 → 全部抬起 → 判定轻点。
    /// 注意：若系统把「两指点按」设为右键单击，会与本手势冲突，默认不绑定动作。
    private struct TwoTapState {
        let beganAt: TimeInterval
        let startPositions: [(Float, Float)]
        var liftStarted = false
        var liftStartedAt: TimeInterval?
    }

    private var twoTapState: TwoTapState?
    private var lastTwoTapFireAt: TimeInterval = 0
    private var prevTwoTapCount = -1
    private let twoTapWindow: TimeInterval = 0.5
    private let twoTapLiftWindow: TimeInterval = 0.25
    private let twoTapDrift: Float = 0.05
    private let twoTapCooldown: TimeInterval = 0.6

    private func handleTwoFingerTap(touches: [Touch]) {
        let now = ProcessInfo.processInfo.systemUptime
        let count = touches.count
        let pos = positions(touches)
        let increased = count > prevTwoTapCount

        if let st = twoTapState {
            switch count {
            case 2:
                if !match(st.startPositions, pos, tolerance: twoTapDrift) {
                    Log.write("[mt] 两指轻点：位移过大，取消（按滚动处理）")
                    twoTapState = nil
                } else if now - st.beganAt > twoTapWindow {
                    Log.write("[mt] 两指轻点：按住超时，取消")
                    twoTapState = nil
                } else if st.liftStarted {
                    Log.write("[mt] 两指轻点：抬起后又落回，取消")
                    twoTapState = nil
                }
            case 0:
                twoTapState = nil
                let total = now - st.beganAt
                // 两根手指可能同一帧同时抬起（没有经过 1 指的中间帧），也算有效轻点
                let liftValid = st.liftStartedAt.map { now - $0 <= twoTapLiftWindow } ?? true
                if total <= twoTapWindow && liftValid {
                    fireTwoTap()
                } else {
                    Log.write("[mt] 两指轻点未通过: total=\(String(format: "%.2f", total))")
                }
            default:
                if !st.liftStarted {
                    var s = st
                    s.liftStarted = true
                    s.liftStartedAt = now
                    twoTapState = s
                }
            }
            prevTwoTapCount = count
            return
        }

        // 无状态：触点增加到 2（0→2 或 1→2 均为新落指；3→2 是抬手不算）
        if count == 2 && increased {
            twoTapState = TwoTapState(beganAt: now, startPositions: pos)
            Log.write("[mt] 两指轻点候选建立 pos=[\(fmt(pos))]")
        }
        prevTwoTapCount = count
    }

    private func fireTwoTap() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTwoTapFireAt > twoTapCooldown else { return }
        lastTwoTapFireAt = now
        Log.write("[mt] 两指轻点 已确认")
        onTwoFingerTap?()
    }

    // MARK: - 两指横向滑动（快速甩动）

    /// 两指左右滑动（甩动）会话。与系统两指滚动天然冲突，
    /// 因此只识别「落下后 0.4s 内横向甩过阈值」的快速动作，降低误触。
    private struct TwoSwipeSession {
        var tracks: [Int32: FingerTrack] = [:]
        let beganAt: TimeInterval
    }

    private var twoSwipeSession: TwoSwipeSession?
    private var lastTwoSwipeFireAt: TimeInterval = 0
    private var prevTwoSwipeCount = -1
    private let twoSwipeThreshold: Float = 0.10
    private let twoSwipeMinPerFingerMove: Float = 0.02
    private let twoSwipeFlickWindow: TimeInterval = 0.4
    private let twoSwipeCooldown: TimeInterval = 0.6

    private func handleTwoFingerSwipe(touches: [Touch]) {
        let now = ProcessInfo.processInfo.systemUptime
        let count = touches.count

        guard count == 2 else {
            twoSwipeSession = nil
            prevTwoSwipeCount = count
            return
        }

        if twoSwipeSession == nil {
            // 只在“落指”时建立会话（0→2 / 1→2），抬手（3→2）不算
            let increased = count > prevTwoSwipeCount
            guard increased else {
                prevTwoSwipeCount = count
                return
            }
            var s: [Int32: FingerTrack] = [:]
            for t in touches { s[t.fingerId] = FingerTrack(startX: t.x, startY: t.y) }
            twoSwipeSession = TwoSwipeSession(tracks: s, beganAt: now)
            prevTwoSwipeCount = count
            return
        }

        guard let s = twoSwipeSession else { return }
        let currentIDs = Set(touches.map(\.fingerId))
        guard currentIDs == Set(s.tracks.keys) else {
            twoSwipeSession = nil
            prevTwoSwipeCount = count
            return
        }

        var totalDX: [Float] = []
        var totalDY: [Float] = []
        for t in touches {
            guard let track = s.tracks[t.fingerId] else { return }
            totalDX.append(t.x - track.startX)
            totalDY.append(t.y - track.startY)
        }
        guard totalDX.count == 2, totalDY.count == 2 else { return }

        let avgX = totalDX.reduce(0, +) / 2
        let avgY = totalDY.reduce(0, +) / 2

        // 只识别横向甩动；纵向（滚动）不抢
        guard abs(avgX) > abs(avgY) else {
            prevTwoSwipeCount = count
            return
        }
        guard totalDX.allSatisfy({ abs($0) >= twoSwipeMinPerFingerMove }) else {
            prevTwoSwipeCount = count
            return
        }
        let signX = Set(totalDX.map { $0 > 0 })
        guard signX.count == 1 else {
            prevTwoSwipeCount = count
            return
        }
        guard abs(avgX) >= twoSwipeThreshold, now - s.beganAt <= twoSwipeFlickWindow else {
            prevTwoSwipeCount = count
            return
        }
        fireTwoSwipe(avgX > 0 ? .right : .left)
        twoSwipeSession = nil
        prevTwoSwipeCount = count
    }

    private func fireTwoSwipe(_ direction: SwipeDirection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTwoSwipeFireAt > twoSwipeCooldown else { return }
        lastTwoSwipeFireAt = now
        Log.write("[mt] 两指\(direction.logName)（甩动）已确认")
        onTwoFingerSwipe?(direction)
    }

    // MARK: - 三指按住 + 第四指点按

    /// 四指手势状态机（不依赖 fingerId，只数触点数量 + 位置匹配）：
    /// 3 根手指轻放（count=3，任意触点状态）→ 第 4 根手指短暂加入（count=4）
    /// → 第 4 根手指离开（count=3），且 3 根基准手指位置几乎不变 → 判定为轻点，
    /// 触发删除到废纸篓。
    private struct BaseHold {
        var positions: [(Float, Float)]   // 3 个基准触点位置（按 x 排序）
        let beganAt: TimeInterval
    }

    private struct TapCandidate {
        let joinedAt: TimeInterval
        let basePositions: [(Float, Float)]  // 第四指加入瞬间冻结的基准位置快照
    }

    private let minHoldDuration: TimeInterval = 0.15 // 三指至少保持 count=3 这么久
    private let tapWindow: TimeInterval = 0.8        // 第四指加入→离开的最长间隔（轻点）
    private let driftThreshold: Float = 0.06         // 基准手指漂移上限：超过视为移动/换姿势
    private let stationaryThreshold: Float = 0.045   // 触发时基准手指允许的位移
    private let matchTolerance: Float = 0.07         // 位置匹配容差（识别“同一根手指”）
    private var baseHold: BaseHold?
    private var tapCandidate: TapCandidate?
    private var prevFourCount = -1
    private var lastFourTapFireAt: TimeInterval = 0

    /// 触点归一化坐标，按 x 排序
    private func positions(_ touches: [Touch]) -> [(Float, Float)] {
        touches.map { ($0.x, $0.y) }.sorted { $0.0 < $1.0 }
    }

    /// a 中的每个点是否都能在 b 中找到（数量相同、一一匹配、误差 <= tolerance）
    private func match(_ a: [(Float, Float)], _ b: [(Float, Float)], tolerance: Float) -> Bool {
        guard a.count == b.count else { return false }
        var used = [Bool](repeating: false, count: b.count)
        for p in a {
            var best: Float = .greatestFiniteMagnitude
            var bestIdx = -1
            for (j, q) in b.enumerated() where !used[j] {
                let d = max(abs(p.0 - q.0), abs(p.1 - q.1))
                if d < best { best = d; bestIdx = j }
            }
            if bestIdx < 0 || best > tolerance { return false }
            used[bestIdx] = true
        }
        return true
    }

    /// a 中与 b 匹配后剩余（未匹配上）的点
    private func unmatched(_ a: [(Float, Float)], _ b: [(Float, Float)], tolerance: Float) -> [(Float, Float)] {
        var used = [Bool](repeating: false, count: b.count)
        var rest: [(Float, Float)] = []
        for p in a {
            var best: Float = .greatestFiniteMagnitude
            var bestIdx = -1
            for (j, q) in b.enumerated() where !used[j] {
                let d = max(abs(p.0 - q.0), abs(p.1 - q.1))
                if d < best { best = d; bestIdx = j }
            }
            if bestIdx >= 0 && best <= tolerance {
                used[bestIdx] = true
            } else {
                rest.append(p)
            }
        }
        return rest
    }

    private func handleFourFingerTap(touches: [Touch]) {
        let now = ProcessInfo.processInfo.systemUptime
        let count = touches.count
        let pos = positions(touches)

        // 调试：触点数量变化日志（每次手势应能看到 3→4→3）
        if count != prevFourCount {
            let ids = Set(touches.map(\.fingerId))
            Log.write("[mt] count \(prevFourCount)->\(count) ids=[\(ids.sorted())]")
            prevFourCount = count
        }

        switch count {
        case 3:
            handleThreeHold(now: now, pos: pos)
        case 4:
            handleFourPresent(now: now, pos: pos)
        default:
            resetFourTapState(reason: "触点数量 \(count) 非 3/4")
        }
    }

    /// count == 3：维护三指按住基线，或完成一次第四指轻点
    private func handleThreeHold(now: TimeInterval, pos: [(Float, Float)]) {
        // 正处于第四指轻点候选：第四指已离开，回到三指 → 判定
        if let cand = tapCandidate {
            guard let base = baseHold else {
                resetFourTapState(reason: "无基准")
                return
            }
            let tapDuration = now - cand.joinedAt
            let holdDuration = now - base.beganAt
            let still = match(cand.basePositions, pos, tolerance: stationaryThreshold)
            Log.write("[mt] 第四指离开 tapDuration=\(String(format: "%.2f", tapDuration)) hold=\(String(format: "%.2f", holdDuration)) 静止=\(still)")
            if tapDuration <= tapWindow && holdDuration >= minHoldDuration && still {
                fireFourTap()
            } else {
                Log.write("[mt] 轻点未通过: tapDuration=\(String(format: "%.2f", tapDuration)) hold=\(String(format: "%.2f", holdDuration)) 静止=\(still)")
            }
            resetFourTapState(reason: "轻点判定完成")
            return
        }

        // 无候选：维护三指基线（跟随慢速漂移）
        if let b = baseHold {
            if match(b.positions, pos, tolerance: driftThreshold) {
                baseHold = BaseHold(positions: pos, beganAt: b.beganAt)
                return
            }
            Log.write("[mt] 三指大幅移动，重置基线")
            resetFourTapState(reason: "三指大幅移动")
            return
        }

        // 首次进入三指：建立基线
        baseHold = BaseHold(positions: pos, beganAt: now)
        Log.write("[mt] 三指按住基线建立 pos=[\(fmt(pos))]")
    }

    /// count == 4：在三指基线之上检测到第四指加入
    private func handleFourPresent(now: TimeInterval, pos: [(Float, Float)]) {
        // 已有候选（第四指还没离开）：若按住太久则忽略本次
        if let cand = tapCandidate {
            if now - cand.joinedAt > tapWindow {
                Log.write("[mt] 第四指按住超过 \(tapWindow)s，忽略本次")
                tapCandidate = nil
            }
            return
        }

        guard let base = baseHold else {
            // 没有三指基线直接出现四指（罕见）：忽略，等回落到三指
            Log.write("[mt] 无三指基线直接四指，忽略")
            return
        }

        let rest = unmatched(pos, base.positions, tolerance: matchTolerance)
        if rest.count == 1 {
            tapCandidate = TapCandidate(joinedAt: now, basePositions: base.positions)
            Log.write("[mt] 第四指加入 新点=\(fmt(rest))")
        } else {
            Log.write("[mt] 四指帧与三指基线不匹配 剩余点=\(rest.count)")
            resetFourTapState(reason: "四指集合与三指基线不兼容")
        }
    }

    /// 触发删除（带冷却）
    private func fireFourTap() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFourTapFireAt > cooldown else { return }
        lastFourTapFireAt = now
        Log.write("[mt] 三指按住 + 第四指点按 已确认")
        onFourFingerTap?()
    }

    /// 重置四指检测状态
    private func resetFourTapState(reason: String) {
        if baseHold != nil || tapCandidate != nil {
            Log.write("[mt] 四指状态重置: \(reason)")
        }
        baseHold = nil
        tapCandidate = nil
    }

    /// 调试：格式化触点坐标
    private func fmt(_ pts: [(Float, Float)]) -> String {
        pts.prefix(4).map { String(format: "%.2f/%.2f", $0.0, $0.1) }.joined(separator: " ")
    }
}

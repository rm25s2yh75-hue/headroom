import Cocoa
import UserNotifications
import Darwin

// MARK: - Per-process info

struct ProcInfo {
    let pid: Int32
    let name: String
    let residentBytes: UInt64
    var cpuPercent: Double = 0.0
    var faultRate:  Double = 0.0   // page faults per second — proxy for swap pressure
}

// MARK: - Shared colours  (one definition, used everywhere)

let kColorGreen  = NSColor(srgbRed: 0.30, green: 0.78, blue: 0.46, alpha: 1.0)
let kColorAmber  = NSColor(srgbRed: 0.91, green: 0.75, blue: 0.19, alpha: 1.0)
let kColorRed    = NSColor(srgbRed: 0.91, green: 0.33, blue: 0.33, alpha: 1.0)
let kDotColors   = [kColorGreen, kColorAmber, kColorRed]

// MARK: - Line graph view

class LineGraphView: NSView {
    var values: [Double] = []
    var graphTitle: String = ""
    private let titleFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    // Resolved each draw call so it responds to live appearance changes
    private var resolvedLineColor: NSColor {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? .white : .black
    }

    override func draw(_ dirtyRect: NSRect) {
        let lineColor = resolvedLineColor
        let padX: CGFloat = 8, titleH: CGFloat = 15, padB: CGFloat = 4
        let titleY = bounds.height - titleH - 1

        // Measure the percentage label first so we know how much space the title can use
        let pctAttr: NSAttributedString?
        if let last = values.last {
            pctAttr = NSAttributedString(string: String(format: "%.0f%%", last),
                                         attributes: [.font: titleFont, .foregroundColor: lineColor])
        } else { pctAttr = nil }
        let pctW = pctAttr?.size().width ?? 0

        // Draw title, clipped so it never runs into the percentage
        let maxTitleW = bounds.width - pctW - padX * 3
        if maxTitleW > 0 {
            let ta: [NSAttributedString.Key: Any] = [.font: titleFont,
                                                      .foregroundColor: NSColor.secondaryLabelColor]
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: padX, y: 0, width: maxTitleW, height: bounds.height)).setClip()
            NSAttributedString(string: graphTitle, attributes: ta).draw(at: NSPoint(x: padX, y: titleY))
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // Draw percentage right-aligned
        if let pa = pctAttr {
            pa.draw(at: NSPoint(x: bounds.width - pctW - padX, y: titleY))
        }

        drawLine(in: NSRect(x: padX, y: padB, width: bounds.width - padX*2,
                            height: bounds.height - titleH - padB - 4),
                 lineColor: lineColor)
    }

    private func drawLine(in rect: NSRect, lineColor: NSColor) {
        guard values.count > 1 else { return }
        let base = NSBezierPath()
        base.move(to: NSPoint(x: rect.minX, y: rect.minY))
        base.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        base.lineWidth = 0.5
        NSColor.separatorColor.withAlphaComponent(0.3).setStroke(); base.stroke()

        let path = NSBezierPath()
        path.lineWidth = 1.5; path.lineJoinStyle = .round; path.lineCapStyle = .round
        let step = rect.width / CGFloat(values.count - 1)
        let pts = values.enumerated().map { i, v in
            NSPoint(x: rect.minX + CGFloat(i)*step,
                    y: rect.minY + CGFloat(min(max(v,0),100)/100) * rect.height)
        }
        path.move(to: pts[0]); pts.dropFirst().forEach { path.line(to: $0) }
        lineColor.setStroke(); path.stroke()

        guard let fill = path.copy() as? NSBezierPath else { return }
        fill.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        fill.line(to: NSPoint(x: rect.minX, y: rect.minY))
        fill.close()
        lineColor.withAlphaComponent(0.12).setFill(); fill.fill()
    }
}

// MARK: - Toggle row view  (click does NOT close the menu)

class ToggleRowView: NSView {
    var label: String = "" { didSet { needsDisplay = true } }
    var isOn: Bool    = false { didSet { needsDisplay = true } }
    var onChange: ((Bool) -> Void)?

    private var hovering = false
    private let itemFont = NSFont.menuFont(ofSize: 0)

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let sv = superview, sv.bounds.width > 0 {
            setFrameSize(NSSize(width: sv.bounds.width, height: frame.height))
        }
        autoresizingMask = [.width]
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Validate real cursor position — clears stale hover caused by menu scrolling
        if hovering, let win = window,
           !bounds.contains(convert(win.mouseLocationOutsideOfEventStream, from: nil)) {
            hovering = false
        }
        if hovering {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 2), xRadius: 5, yRadius: 5).fill()
        }
        let fg = hovering ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        let attr: [NSAttributedString.Key: Any] = [.font: itemFont, .foregroundColor: fg]
        let midY = bounds.height / 2
        if isOn {
            let ck = NSAttributedString(string: "✓", attributes: attr)
            ck.draw(at: NSPoint(x: 14, y: midY - ck.size().height / 2))
        }
        let ls = NSAttributedString(string: label, attributes: attr)
        ls.draw(at: NSPoint(x: 34, y: midY - ls.size().height / 2))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true; needsDisplay = true
        superview?.subviews.forEach { ($0 as? ToggleRowView)?.needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) { isOn = !isOn; onChange?(isOn) }
}

// MARK: - Graph pair view  (two LineGraphViews side by side for the 2×2 grid)

class GraphPairView: NSView {
    let left:  LineGraphView
    let right: LineGraphView

    init(width: CGFloat, height: CGFloat = 54) {
        left  = LineGraphView(frame: .zero)
        right = LineGraphView(frame: .zero)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        addSubview(left); addSubview(right)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let sv = superview, sv.bounds.width > 0 {
            setFrameSize(NSSize(width: sv.bounds.width, height: frame.height))
        }
        autoresizingMask = [.width]
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        switch (left.isHidden, right.isHidden) {
        case (true,  false): right.frame = bounds
        case (false, true):  left.frame  = bounds
        default:
            let half = floor(w / 2)
            left.frame  = NSRect(x: 0,    y: 0, width: half,    height: h)
            right.frame = NSRect(x: half, y: 0, width: w - half, height: h)
        }
    }
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate,
                   UNUserNotificationCenterDelegate, NSMenuDelegate {

    var statusItem: NSStatusItem!
    let persistentMenu = NSMenu()

    // ── CPU state ──
    var prevCPUInfo: processor_info_array_t?
    var prevCPUInfoCount: mach_msg_type_number_t = 0

    // ── Histories ──
    var ramHistory:          [Double] = []
    var cpuHistory:          [Double] = []
    var pressureHistory:     [Double] = []
    var swapPressureHistory: [Double] = []
    let historyMax = 20
    var prevVMFaults: UInt64 = 0   // for system-wide fault-rate delta

    // ── Cached computed values ──
    var lastVMStats        = vm_statistics64()
    var lastRAM:           Double = 0
    var lastCPU:           Double = 0
    var lastSwap:          Double = 0
    var lastPressure:      Int    = 0
    var lastPressureScore: Double = 0   // continuous 0-100 for bar + graph
    var lastSwapScore:     Double = 0   // continuous 0-100 swap pressure for bar
    var lastNetDown:       Double = 0
    var lastNetUp:         Double = 0

    // ── Process cache ──
    var cachedTopRAMProcs:  [ProcInfo] = []
    var cachedTopCPUProcs:  [ProcInfo] = []
    var cachedTopSwapProcs: [ProcInfo] = []
    var procRefreshTick = 0
    var prevProcTicks:  [Int32: UInt64] = [:]
    var prevProcFaults: [Int32: Int64]  = [:]   // cumulative fault counts for delta
    var prevProcTime: Date = Date()

    // ── Network state ──
    var prevNetBytesIn:  UInt64 = 0
    var prevNetBytesOut: UInt64 = 0
    var prevNetTime: Date = Date()

    // ── Notification state ──
    var prevPressureLevel: Int = 0

    // ── Timer ──
    var refreshTimer: Timer?

    // ── Live menu item refs (updated in-place while menu is open) ──
    var menuIsOpen    = false
    var scrollMonitor: Any?          // NSEvent monitor — clears stale hover on scroll
    var liveToggleRows: [ToggleRowView] = []
    var livePressureItem: NSMenuItem?
    var liveSwapItem:     NSMenuItem?
    var liveNetItem:           NSMenuItem?
    var liveUptimeItem:        NSMenuItem?
    var livePressureGraph:     LineGraphView?   // individual graph views — values updated live
    var liveRAMGraph:          LineGraphView?
    var liveCPUGraph:          LineGraphView?
    var liveSwapPressureGraph: LineGraphView?
    // Pair NSMenuItems — hidden when both graphs in the pair are off
    var liveGraphPair1Item: NSMenuItem?   // Pressure (left) + RAM (right)
    var liveGraphPair2Item: NSMenuItem?   // CPU (left) + Swap (right)
    var liveGraphPair1View: GraphPairView?
    var liveGraphPair2View: GraphPairView?

    // MARK: - UserDefaults

    var showDot: Bool {
        get { UserDefaults.standard.object(forKey: "showDot") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showDot") }
    }
    var showRAM: Bool {
        get { UserDefaults.standard.object(forKey: "showRAM") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "showRAM") }
    }
    var showCPU: Bool {
        get { UserDefaults.standard.object(forKey: "showCPU") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "showCPU") }
    }
    var showPressurePct: Bool {
        get { UserDefaults.standard.object(forKey: "showPressurePct") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "showPressurePct") }
    }
    var showSwapPct: Bool {
        get { UserDefaults.standard.object(forKey: "showSwapPct") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "showSwapPct") }
    }
    var showPressureGraph: Bool {
        get { UserDefaults.standard.object(forKey: "showPressureGraph") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "showPressureGraph") }
    }
    var showRAMGraph: Bool {
        get { UserDefaults.standard.object(forKey: "showRAMGraph") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "showRAMGraph") }
    }
    var showCPUGraph: Bool {
        get { UserDefaults.standard.object(forKey: "showCPUGraph") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "showCPUGraph") }
    }
    var showSwapPressureGraph: Bool {
        get { UserDefaults.standard.object(forKey: "showSwapPressureGraph") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "showSwapPressureGraph") }
    }
    var pressureNotifications: Bool {
        get { UserDefaults.standard.object(forKey: "pressureNotifications") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "pressureNotifications") }
    }
    var autoCheckUpdates: Bool {
        get { UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoCheckUpdates") }
    }
    var refreshInterval: Double {
        get { UserDefaults.standard.object(forKey: "refreshInterval") as? Double ?? 2.0 }
        set { UserDefaults.standard.set(newValue, forKey: "refreshInterval") }
    }

    var launchAgentPlistPath: String {
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/LaunchAgents/com.local.headroom.plist"
    }
    var launchAtLogin: Bool {
        get { FileManager.default.fileExists(atPath: launchAgentPlistPath) }
        set {
            if newValue {
                guard let exec = Bundle.main.executablePath else { return }
                let xml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>
                  <key>Label</key><string>com.local.headroom</string>
                  <key>ProgramArguments</key><array><string>\(exec)</string></array>
                  <key>RunAtLoad</key><true/>
                </dict></plist>
                """
                try? xml.write(toFile: launchAgentPlistPath, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(atPath: launchAgentPlistPath)
            }
        }
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        persistentMenu.delegate = self
        persistentMenu.autoenablesItems = false   // prevent AppKit from muting colours on action-less items
        statusItem.menu = persistentMenu
        tick()
        startTimer()
        if autoCheckUpdates {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkForUpdatesSilently() }
        }
    }

    func startTimer() {
        refreshTimer?.invalidate()
        // Use .common mode so the timer fires even while NSMenu is tracking
        // (NSMenu switches the run loop to .eventTracking, blocking .default-only timers)
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    // MARK: - Tick

    func tick() {
        lastVMStats  = fetchVMStats()
        lastRAM      = ramPercent(from: lastVMStats)
        lastCPU      = cpuPercent()
        lastSwap     = swapUsedGB()
        let net      = networkSpeeds()
        lastNetDown  = net.down; lastNetUp = net.up

        ramHistory.append(lastRAM); if ramHistory.count > historyMax { ramHistory.removeFirst() }
        cpuHistory.append(lastCPU); if cpuHistory.count > historyMax { cpuHistory.removeFirst() }

        // Continuous 0-100 pressure score: 70% weight to RAM compression, 30% to CPU.
        // compRatio hits 1.0 at 0.75 compression (the "High" threshold), CPU hits 1.0 at 90%.
        let compRatio = Double(lastVMStats.compressor_page_count) /
                        max(1, Double(ProcessInfo.processInfo.physicalMemory / UInt64(vm_page_size)))
        lastPressureScore = min((compRatio / 0.75) * 70.0 + (lastCPU / 90.0) * 30.0, 100.0)
        pressureHistory.append(lastPressureScore); if pressureHistory.count > historyMax { pressureHistory.removeFirst() }

        // Dot colour driven by the same score: green < 50, amber 50–74, red ≥ 75
        lastPressure = lastPressureScore >= 75 ? 2 : lastPressureScore >= 50 ? 1 : 0

        // System-wide page fault rate → normalised 0-100 (5 000 faults/s = 100 %)
        let curFaults = lastVMStats.faults
        if prevVMFaults > 0 && curFaults >= prevVMFaults {
            lastSwapScore = min(Double(curFaults - prevVMFaults) / refreshInterval / 5000.0 * 100.0, 100.0)
        } else if prevVMFaults > 0 {
            lastSwapScore = 0
        }
        prevVMFaults = curFaults
        swapPressureHistory.append(lastSwapScore); if swapPressureHistory.count > historyMax { swapPressureHistory.removeFirst() }

        maybeSendPressureNotification(newLevel: lastPressure)
        prevPressureLevel = lastPressure

        procRefreshTick += 1
        let ticksNeeded = max(1, Int(10.0 / refreshInterval))
        if procRefreshTick >= ticksNeeded || cachedTopRAMProcs.isEmpty {
            let all = topProcesses()
            cachedTopRAMProcs  = Array(all.sorted { $0.residentBytes > $1.residentBytes }.prefix(10))
            cachedTopCPUProcs  = Array(all.filter { $0.cpuPercent  > 0.1 }
                                          .sorted { $0.cpuPercent  > $1.cpuPercent  }.prefix(10))
            cachedTopSwapProcs = Array(all.filter { $0.faultRate   > 1.0 }
                                          .sorted { $0.faultRate   > $1.faultRate   }.prefix(10))
            procRefreshTick = 0
        }

        updateBarTitle()

        // Live-update open menu in-place (no rebuild, no flicker)
        if menuIsOpen { updateLiveMenuItems() }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        liveToggleRows.removeAll()
        menu.removeAllItems()
        buildMenuItems(into: menu)
        // When the menu scrolls the mouse doesn't move, so NSTrackingArea never fires
        // mouseExited. Monitor scroll events and force every toggle row to redraw so
        // each one can self-validate its hover state against the actual cursor position.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.liveToggleRows.forEach { $0.needsDisplay = true }
            return event
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        liveToggleRows.removeAll()
        // Clear refs so they can be GC'd
        livePressureItem = nil; liveSwapItem = nil
        liveNetItem = nil; liveUptimeItem = nil
        livePressureGraph = nil; liveRAMGraph = nil; liveCPUGraph = nil; liveSwapPressureGraph = nil
        liveGraphPair1Item = nil; liveGraphPair2Item = nil
        liveGraphPair1View = nil; liveGraphPair2View = nil
    }

    // MARK: - Stats

    func fetchVMStats() -> vm_statistics64 {
        var s = vm_statistics64()
        var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                _ = host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n)
            }
        }
        return s
    }

    func ramPercent(from v: vm_statistics64) -> Double {
        let pg = UInt64(vm_page_size)
        let total = ProcessInfo.processInfo.physicalMemory / pg
        let used  = UInt64(v.active_count) + UInt64(v.wire_count)
        return Double(used) / Double(total) * 100
    }

    func cpuPercent() -> Double {
        var info: processor_info_array_t?; var cnt: mach_msg_type_number_t = 0; var cpuN: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuN, &info, &cnt) == KERN_SUCCESS,
              let cur = info else { return 0 }
        var used: Double = 0; var all: Double = 0
        for i in 0..<Int(cpuN) {
            let b = Int(CPU_STATE_MAX)*i
            let u=Double(cur[b+Int(CPU_STATE_USER)]), s=Double(cur[b+Int(CPU_STATE_SYSTEM)])
            let n=Double(cur[b+Int(CPU_STATE_NICE)]), id=Double(cur[b+Int(CPU_STATE_IDLE)])
            var pu=0.0, ps=0.0, pn=0.0, pi=0.0
            if let p=prevCPUInfo { pu=Double(p[b+Int(CPU_STATE_USER)]); ps=Double(p[b+Int(CPU_STATE_SYSTEM)]); pn=Double(p[b+Int(CPU_STATE_NICE)]); pi=Double(p[b+Int(CPU_STATE_IDLE)]) }
            let d=(u-pu)+(s-ps)+(n-pn); used+=d; all+=d+(id-pi)
        }
        if let p=prevCPUInfo { vm_deallocate(mach_task_self_, vm_address_t(bitPattern:p), vm_size_t(prevCPUInfoCount)*vm_size_t(MemoryLayout<integer_t>.size)) }
        prevCPUInfo=cur; prevCPUInfoCount=cnt
        return all>0 ? used/all*100 : 0
    }

    func swapUsedGB() -> Double {
        var s=xsw_usage(); var sz=MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage",&s,&sz,nil,0)
        return Double(s.xsu_used)/1_073_741_824
    }

    func systemUptime() -> String {
        let t=Int(ProcessInfo.processInfo.systemUptime), d=t/86400, h=(t%86400)/3600, m=(t%3600)/60
        if d>0 { return "\(d)d \(h)h \(m)m" }; if h>0 { return "\(h)h \(m)m" }; return "\(m)m"
    }

    func networkSpeeds() -> (down: Double, up: Double) {
        var p: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&p)==0 else { return (0,0) }
        defer { freeifaddrs(p) }
        var tIn:UInt64=0, tOut:UInt64=0; var cur=p
        while let c=cur {
            let ifa=c.pointee
            if let a=ifa.ifa_addr, a.pointee.sa_family==UInt8(AF_LINK),
               ifa.ifa_flags & UInt32(IFF_LOOPBACK)==0, let raw=ifa.ifa_data {
                let d=raw.assumingMemoryBound(to: if_data.self).pointee
                tIn+=UInt64(d.ifi_ibytes); tOut+=UInt64(d.ifi_obytes)
            }
            cur=ifa.ifa_next
        }
        let now=Date(), el=now.timeIntervalSince(prevNetTime)
        var dn=0.0, up=0.0
        if prevNetBytesIn>0 && el>0.1 {
            if tIn>=prevNetBytesIn  { dn=Double(tIn-prevNetBytesIn)/el }
            if tOut>=prevNetBytesOut { up=Double(tOut-prevNetBytesOut)/el }
        }
        prevNetBytesIn=tIn; prevNetBytesOut=tOut; prevNetTime=now
        return (dn,up)
    }

    func formatSpeed(_ b: Double) -> String {
        if b>=1_048_576 { return String(format:"%.1f MB/s",b/1_048_576) }
        if b>=1_024     { return String(format:"%.0f KB/s",b/1_024) }
        return String(format:"%.0f B/s",b)
    }

    func topProcesses() -> [ProcInfo] {
        var mib:[Int32]=[CTL_KERN,KERN_PROC,KERN_PROC_ALL,0]; var sz=0
        guard sysctl(&mib,4,nil,&sz,nil,0)==0, sz>0 else { return [] }
        var procs=[kinfo_proc](repeating:kinfo_proc(),count:sz/MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib,4,&procs,&sz,nil,0)==0 else { return [] }
        let now=Date(), el=now.timeIntervalSince(prevProcTime)
        var newTicks:[Int32:UInt64]=[:], newFaults:[Int32:Int64]=[:], results:[ProcInfo]=[]
        for p in procs {
            let pid=p.kp_proc.p_pid; guard pid>1 else { continue }
            var ti=proc_taskinfo()
            guard proc_pidinfo(pid,PROC_PIDTASKINFO,0,&ti,Int32(MemoryLayout<proc_taskinfo>.size))>0 else { continue }
            guard ti.pti_resident_size>5*1024*1024 else { continue }
            var nb=[CChar](repeating:0,count:1024); proc_name(pid,&nb,UInt32(nb.count))
            let name=String(cString:nb); guard !name.isEmpty else { continue }
            // CPU %
            let ticks=ti.pti_total_user+ti.pti_total_system; newTicks[pid]=ticks
            var cpu=0.0
            if let prev=prevProcTicks[pid], el>0.1 { cpu=min(999,(Double(ticks-prev)/1e9)/el*100) }
            // Page fault rate — proxy for swap/memory pressure
            let faults=Int64(ti.pti_faults); newFaults[pid]=faults
            var faultRate=0.0
            if let prev=prevProcFaults[pid], el>0.1, faults>=prev { faultRate=(Double(faults-prev))/el }
            results.append(ProcInfo(pid:pid,name:name,residentBytes:ti.pti_resident_size,
                                    cpuPercent:cpu,faultRate:faultRate))
        }
        if el>0.5 { prevProcTicks=newTicks; prevProcFaults=newFaults; prevProcTime=now }
        return results
    }

    // MARK: - Notifications

    func maybeSendPressureNotification(newLevel: Int) {
        guard pressureNotifications, newLevel==2, prevPressureLevel<2 else { return }
        let c=UNMutableNotificationContent()
        c.title="Headroom — System Pressure High"
        c.body="Your Mac is under heavy pressure. Consider closing some apps."
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier:"headroom-\(Date().timeIntervalSince1970)", content:c, trigger:nil))
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler h: @escaping (UNNotificationPresentationOptions)->Void) {
        h([.banner,.sound])
    }

    // MARK: - Bar title

    func updateBarTitle() {
        let font = NSFont.menuBarFont(ofSize: 0)
        let t = NSMutableAttributedString()
        if showDot {
            t.append(NSAttributedString(string: "● ",
                attributes: [.foregroundColor: kDotColors[lastPressure], .font: font]))
        }
        var parts: [String] = []
        if showRAM         { parts.append(String(format: "R %.0f%%",  lastRAM)) }
        if showCPU         { parts.append(String(format: "C %.0f%%",  lastCPU)) }
        if showPressurePct { parts.append(String(format: "P %.0f%%",  lastPressureScore)) }
        if showSwapPct     { parts.append(String(format: "Sw %.0f%%", lastSwapScore)) }
        if !parts.isEmpty {
            t.append(NSAttributedString(string: parts.joined(separator: "  "), attributes: [.font: font]))
        }
        if t.length == 0 { t.append(NSAttributedString(string: "●", attributes: [.font: font])) }
        statusItem.button?.attributedTitle = t
    }

    // MARK: - Live in-place update (called by tick when menu is open)

    func updateLiveMenuItems() {
        let labels = ["Healthy  < 50%", "Moderate  50–74%", "High  ≥ 75%"]
        if let item = livePressureItem {
            let s = NSMutableAttributedString(string: "● ",
                attributes: [.foregroundColor: kDotColors[lastPressure]])
            s.append(NSAttributedString(string: "System Pressure: \(labels[lastPressure])"))
            item.attributedTitle = s
        }
        liveSwapItem?.title   = lastSwap > 0.01 ? String(format: "Swap: %.2f GB", lastSwap) : "Swap: none"
        liveNetItem?.title    = "↓ \(formatSpeed(lastNetDown))   ↑ \(formatSpeed(lastNetUp))"
        liveUptimeItem?.title = "Uptime: \(systemUptime())"

        if let gv = livePressureGraph {
            gv.values = Array(pressureHistory.suffix(20))
            gv.needsDisplay = true
        }
        if let gv = liveRAMGraph {
            gv.values = Array(ramHistory.suffix(20)); gv.needsDisplay = true
        }
        if let gv = liveCPUGraph {
            gv.values = Array(cpuHistory.suffix(20)); gv.needsDisplay = true
        }
        if let gv = liveSwapPressureGraph {
            gv.values = Array(swapPressureHistory.suffix(20)); gv.needsDisplay = true
        }
    }

    // MARK: - Menu builder

    func buildMenuItems(into menu: NSMenu) {
        let labels = ["Healthy  < 50%", "Moderate  50–74%", "High  ≥ 75%"]

        func dotItem(text: String, color: NSColor) -> NSMenuItem {
            let i = NSMenuItem()
            let s = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color])
            s.append(NSAttributedString(string: text))
            i.attributedTitle = s
            return i   // isEnabled defaults to true → full colour, not grayed
        }
        func info(_ t: String) -> NSMenuItem {
            NSMenuItem(title: t, action: nil, keyEquivalent: "")
            // action=nil means not clickable; isEnabled=true means full colour
        }
        func sep() { menu.addItem(.separator()) }

        // ── Summary ──
        let pressureItem = dotItem(text: "System Pressure: \(labels[lastPressure])",
                                    color: kDotColors[lastPressure])
        menu.addItem(pressureItem); livePressureItem = pressureItem

        let swapItem = info(lastSwap > 0.01 ? String(format: "Swap: %.2f GB", lastSwap) : "Swap: none")
        menu.addItem(swapItem); liveSwapItem = swapItem

        let netItem = info("↓ \(formatSpeed(lastNetDown))   ↑ \(formatSpeed(lastNetUp))")
        menu.addItem(netItem); liveNetItem = netItem

        let uptimeItem = info("Uptime: \(systemUptime())")
        menu.addItem(uptimeItem); liveUptimeItem = uptimeItem

        // ── Graphs (2×2 grid) ──
        // Two GraphPairView rows, each holding two LineGraphViews side by side.
        // Toggling a graph hides its cell; the sibling expands to fill. The row
        // NSMenuItem is hidden only when both graphs in that row are off.
        sep()
        let gridW: CGFloat = 240

        func makePair(leftTitle: String,  leftValues: [Double],  leftShown: Bool,
                      rightTitle: String, rightValues: [Double], rightShown: Bool)
                -> (NSMenuItem, GraphPairView) {
            let pv = GraphPairView(width: gridW)
            pv.left.graphTitle  = leftTitle;  pv.left.values  = Array(leftValues.suffix(20))
            pv.right.graphTitle = rightTitle; pv.right.values = Array(rightValues.suffix(20))
            pv.left.isHidden  = !leftShown
            pv.right.isHidden = !rightShown
            let item = NSMenuItem(); item.view = pv
            item.isHidden = !leftShown && !rightShown
            menu.addItem(item)
            return (item, pv)
        }

        let (p1Item, p1View) = makePair(
            leftTitle:  "System Pressure Graph", leftValues:  pressureHistory,     leftShown:  showPressureGraph,
            rightTitle: "RAM Usage Graph",        rightValues: ramHistory,           rightShown: showRAMGraph)
        liveGraphPair1Item = p1Item; liveGraphPair1View = p1View
        livePressureGraph  = p1View.left; liveRAMGraph = p1View.right

        let (p2Item, p2View) = makePair(
            leftTitle:  "CPU Usage Graph",        leftValues:  cpuHistory,           leftShown:  showCPUGraph,
            rightTitle: "Swap Pressure Graph",    rightValues: swapPressureHistory,  rightShown: showSwapPressureGraph)
        liveGraphPair2Item = p2Item; liveGraphPair2View = p2View
        liveCPUGraph       = p2View.left; liveSwapPressureGraph = p2View.right

        // ── Top RAM Apps ──
        if !cachedTopRAMProcs.isEmpty {
            sep()
            let totalB = ProcessInfo.processInfo.physicalMemory
            let usedB  = UInt64(lastVMStats.active_count + lastVMStats.wire_count) * UInt64(vm_page_size)
            let curPct = Double(usedB) / Double(totalB) * 100
            let rs = NSMenu(); rs.autoenablesItems = false
            for p in cachedTopRAMProcs {
                let mb   = Double(p.residentBytes)/1_048_576
                let drop = max(0, curPct - Double(usedB - min(p.residentBytes, usedB)) / Double(totalB) * 100)
                let cs   = p.cpuPercent > 0.1 ? String(format:"  CPU %.0f%%", p.cpuPercent) : ""
                let it   = NSMenuItem(title: String(format:"%@  –  %.0f MB%@  (saves ~%.0f%%)",
                               String(p.name.prefix(22)), mb, cs, drop),
                               action: #selector(copyAppName(_:)), keyEquivalent: "")
                it.representedObject = p.name; it.target = delegate; rs.addItem(it)
            }
            rs.addItem(.separator()); rs.addItem(info("Click app name to copy it"))
            let ri = NSMenuItem(title: "Top RAM Apps", action: nil, keyEquivalent: "")
            ri.submenu = rs; menu.addItem(ri)
        }

        // ── Top CPU Apps ──
        sep()
        let cs2 = NSMenu(); cs2.autoenablesItems = false
        if cachedTopCPUProcs.isEmpty {
            cs2.addItem(info("Warming up — data available after ~20 s"))
        } else {
            for p in cachedTopCPUProcs {
                let it = NSMenuItem(title: String(format:"%@  –  CPU %.0f%%  (%.0f MB)",
                              String(p.name.prefix(26)), p.cpuPercent, Double(p.residentBytes)/1_048_576),
                              action: #selector(copyAppName(_:)), keyEquivalent: "")
                it.representedObject = p.name; it.target = delegate; cs2.addItem(it)
            }
            cs2.addItem(.separator()); cs2.addItem(info("Click app name to copy it"))
        }
        let ci = NSMenuItem(title: "Top CPU Apps", action: nil, keyEquivalent: "")
        ci.submenu = cs2; menu.addItem(ci)

        // ── Top Swap Pressure Apps ──
        sep()
        let ss = NSMenu(); ss.autoenablesItems = false
        if cachedTopSwapProcs.isEmpty {
            ss.addItem(info("Warming up — data available after ~20 s"))
        } else {
            for p in cachedTopSwapProcs {
                let rate = p.faultRate >= 1000 ? String(format:"%.0f k faults/s", p.faultRate/1000)
                                               : String(format:"%.0f faults/s",   p.faultRate)
                let it = NSMenuItem(title: String(format:"%@  –  %@  (%.0f MB)",
                              String(p.name.prefix(24)), rate, Double(p.residentBytes)/1_048_576),
                              action: #selector(copyAppName(_:)), keyEquivalent: "")
                it.representedObject = p.name; it.target = delegate; ss.addItem(it)
            }
            ss.addItem(.separator()); ss.addItem(info("Sorted by page fault rate — click name to copy"))
        }
        let si = NSMenuItem(title: "Top Swap Pressure Apps", action: nil, keyEquivalent: "")
        si.submenu = ss; menu.addItem(si)

        // ── Legend ──
        sep()
        menu.addItem(dotItem(text: "Healthy — System Pressure below 50%",  color: kColorGreen))
        menu.addItem(dotItem(text: "Moderate — System Pressure 50–74%",   color: kColorAmber))
        menu.addItem(dotItem(text: "High — System Pressure 75% or above", color: kColorRed))

        // ── Preferences ──
        sep()
        let prefHeader = info("Preferences"); prefHeader.isEnabled = false; menu.addItem(prefHeader)

        func pref(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.state = on ? .on : .off; i.target = delegate; return i
        }
        menu.addItem(pref("  Auto-check for Updates", autoCheckUpdates, #selector(toggleAutoCheckUpdates(_:))))
        menu.addItem(pref("  Run on Startup",         launchAtLogin,    #selector(toggleLaunchAtLogin(_:))))
        menu.addItem(pref("  System Pressure Notifications", pressureNotifications, #selector(togglePressureNotifications(_:))))

        let rateMenu = NSMenu(); rateMenu.autoenablesItems = false
        for (rate, label) in [(1.0,"1 second"),(2.0,"2 seconds"),(5.0,"5 seconds"),(10.0,"10 seconds")] {
            let ri = NSMenuItem(title: label, action: #selector(setRefreshRate(_:)), keyEquivalent: "")
            ri.representedObject = rate; ri.state = abs(refreshInterval-rate)<0.1 ? .on : .off
            ri.target = delegate; rateMenu.addItem(ri)
        }
        let rrItem = NSMenuItem(title: "  Refresh Rate", action: nil, keyEquivalent: "")
        rrItem.submenu = rateMenu; menu.addItem(rrItem)

        // ── Show / Hide  (custom toggle rows — menu stays open on click) ──
        sep()
        let shHeader = info("Show / Hide"); shHeader.isEnabled = false; menu.addItem(shHeader)

        func toggleRow(_ label: String, _ on: Bool, width: CGFloat = 260,
                       _ handler: @escaping (Bool)->Void) {
            let v = ToggleRowView(frame: NSRect(x: 0, y: 0, width: width, height: 22))
            v.label = label; v.isOn = on; v.onChange = handler
            let i = NSMenuItem(); i.view = v
            i.isEnabled = false   // disabled so NSMenu doesn't treat it as selectable/closeable;
                                  // the custom view still receives mouse events directly
            menu.addItem(i)
            liveToggleRows.append(v)  // tracked so scroll monitor can force redraw
        }

        toggleRow("System Pressure Dot", showDot) { [weak self] on in
            self?.showDot = on; self?.updateBarTitle()
        }
        toggleRow("RAM Usage %", showRAM) { [weak self] on in
            self?.showRAM = on; self?.updateBarTitle()
        }
        toggleRow("CPU Usage %", showCPU) { [weak self] on in
            self?.showCPU = on; self?.updateBarTitle()
        }
        toggleRow("System Pressure %", showPressurePct) { [weak self] on in
            self?.showPressurePct = on; self?.updateBarTitle()
        }
        toggleRow("Swap Pressure %", showSwapPct) { [weak self] on in
            self?.showSwapPct = on; self?.updateBarTitle()
        }
        toggleRow("System Pressure Graph", showPressureGraph) { [weak self] on in
            guard let s = self else { return }
            s.showPressureGraph = on
            s.livePressureGraph?.isHidden = !on
            s.liveGraphPair1View?.needsLayout = true
            s.liveGraphPair1Item?.isHidden = !s.showPressureGraph && !s.showRAMGraph
        }
        toggleRow("RAM Usage Graph", showRAMGraph) { [weak self] on in
            guard let s = self else { return }
            s.showRAMGraph = on
            s.liveRAMGraph?.isHidden = !on
            s.liveGraphPair1View?.needsLayout = true
            s.liveGraphPair1Item?.isHidden = !s.showPressureGraph && !s.showRAMGraph
        }
        toggleRow("CPU Usage Graph", showCPUGraph) { [weak self] on in
            guard let s = self else { return }
            s.showCPUGraph = on
            s.liveCPUGraph?.isHidden = !on
            s.liveGraphPair2View?.needsLayout = true
            s.liveGraphPair2Item?.isHidden = !s.showCPUGraph && !s.showSwapPressureGraph
        }
        toggleRow("Swap Pressure Graph", showSwapPressureGraph) { [weak self] on in
            guard let s = self else { return }
            s.showSwapPressureGraph = on
            s.liveSwapPressureGraph?.isHidden = !on
            s.liveGraphPair2View?.needsLayout = true
            s.liveGraphPair2Item?.isHidden = !s.showCPUGraph && !s.showSwapPressureGraph
        }

        // ── Bottom ──
        sep()
        let ab = NSMenuItem(title: "About Headroom",    action: #selector(showAbout),       keyEquivalent: "")
        ab.target = delegate; menu.addItem(ab)
        let up = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates),  keyEquivalent: "")
        up.target = delegate; menu.addItem(up)
        let ko = NSMenuItem(title: "☕  Buy me a coffee", action: #selector(openKofi),        keyEquivalent: "")
        ko.target = delegate; menu.addItem(ko)
        sep()
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    // MARK: - Actions

    @objc func openKofi() { NSWorkspace.shared.open(URL(string:"https://ko-fi.com/jasa49")!) }
    @objc func toggleAutoCheckUpdates(_ i: NSMenuItem) {
        autoCheckUpdates = !autoCheckUpdates; i.state = autoCheckUpdates ? .on : .off }
    @objc func toggleLaunchAtLogin(_ i: NSMenuItem) {
        launchAtLogin = !launchAtLogin; i.state = launchAtLogin ? .on : .off }
    @objc func togglePressureNotifications(_ i: NSMenuItem) {
        pressureNotifications = !pressureNotifications; i.state = pressureNotifications ? .on : .off
        if pressureNotifications {
            UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]) { _,_ in }
        }
    }
    @objc func setRefreshRate(_ i: NSMenuItem) {
        guard let r = i.representedObject as? Double else { return }
        refreshInterval = r; startTimer()
    }
    @objc func copyAppName(_ i: NSMenuItem) {
        guard let n = i.representedObject as? String else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(n, forType: .string)
    }

    // MARK: - About

    @objc func showAbout() {
        let hf=NSFont.boldSystemFont(ofSize:12), bf=NSFont.systemFont(ofSize:12)
        let ha:[NSAttributedString.Key:Any]=[.font:hf,.foregroundColor:NSColor.labelColor]
        let ba:[NSAttributedString.Key:Any]=[.font:bf,.foregroundColor:NSColor.secondaryLabelColor]
        func h(_ s:String)->NSAttributedString { NSAttributedString(string:s,attributes:ha) }
        func b(_ s:String)->NSAttributedString { NSAttributedString(string:s,attributes:ba) }
        func dot(_ c:NSColor,_ s:String)->NSAttributedString {
            let a=NSMutableAttributedString(string:"● ",attributes:[.font:bf,.foregroundColor:c])
            a.append(NSAttributedString(string:s,attributes:ba)); return a
        }
        let t=NSMutableAttributedString()
        t.append(h("System Pressure Dot\n"))
        t.append(b("Reflects the System Pressure % score directly:\n"))
        t.append(dot(kColorGreen, "Healthy — System Pressure below 50%\n"))
        t.append(dot(kColorAmber, "Moderate — System Pressure between 50–74%\n"))
        t.append(dot(kColorRed,   "High — System Pressure 75% or above, performance may suffer\n\n"))
        t.append(h("RAM Usage %\n")); t.append(b("How much of your physical RAM is actively in use.\n\n"))
        t.append(h("CPU Usage %\n")); t.append(b("The percentage of your processor currently in use.\n\n"))
        t.append(h("System Pressure Graph\n"))
        t.append(b("Line chart of the combined System Pressure level over time. Toggle under Show/Hide.\n\n"))
        t.append(h("RAM Usage Graph\n")); t.append(b("Live line chart of RAM usage % over recent ticks.\n\n"))
        t.append(h("CPU Usage Graph\n")); t.append(b("Live line chart of CPU usage % over recent ticks.\n\n"))
        t.append(h("Network Speed\n")); t.append(b("Live download (↓) and upload (↑) throughput across all active interfaces.\n\n"))
        t.append(h("System Uptime\n")); t.append(b("How long your Mac has been running since the last restart.\n\n"))
        t.append(h("Top RAM Apps\n"))
        t.append(b("10 processes using the most RAM, with CPU and estimated pressure savings. Click to copy name.\n\n"))
        t.append(h("Top CPU Apps\n"))
        t.append(b("10 processes using the most CPU. Data populates after ~20 s. Click to copy name.\n\n"))
        t.append(h("Swap Pressure Graph\n"))
        t.append(b("Live line chart of the system-wide page fault rate, normalised so 5,000 faults/second = 100%. A rising line means the system is increasingly moving data between RAM and disk. Toggle under Show/Hide.\n\n"))
        t.append(h("Top Swap Pressure Apps\n"))
        t.append(b("10 processes with the highest page fault rate — the best available per-process proxy for swap pressure. A high fault rate means the process is frequently requesting memory that isn't resident, driving compression and swap activity. macOS does not expose per-process swap usage directly. Data populates after ~20 s. Click to copy name.\n\n"))
        t.append(h("System Pressure Notifications\n"))
        t.append(b("Sends a notification when pressure rises to High. Fires once per transition.\n\n"))
        t.append(h("Refresh Rate\n"))
        t.append(b("How often stats update — 1s, 2s (default), 5s, or 10s.\n\n"))
        t.append(h("RAM Compression\n"))
        t.append(b("When RAM fills up, macOS compresses inactive data to fit more in.\n\n"))
        t.append(h("Swap\n"))
        t.append(b("When RAM is exhausted, macOS writes data to your SSD. Much slower than RAM."))

        let tv=NSTextView(frame:NSRect(x:0,y:0,width:428,height:10))
        tv.isEditable=false; tv.drawsBackground=false; tv.isVerticallyResizable=true
        tv.isHorizontallyResizable=false; tv.textContainer?.widthTracksTextView=true
        tv.textContainer?.containerSize=NSSize(width:418,height:CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset=NSSize(width:8,height:8); tv.textStorage?.setAttributedString(t); tv.sizeToFit()

        let sv=NSScrollView(frame:NSRect(x:0,y:44,width:450,height:446))
        sv.hasVerticalScroller=true; sv.autohidesScrollers=false; sv.borderType = .noBorder; sv.documentView=tv

        let ok=NSButton(frame:NSRect(x:180,y:9,width:90,height:28))
        ok.title="OK"; ok.bezelStyle = .rounded; ok.keyEquivalent="\r"
        ok.action=#selector(closeAboutWindow); ok.target=self

        let win=NSWindow(contentRect:NSRect(x:0,y:0,width:450,height:490),
                         styleMask:[.titled,.closable],backing:.buffered,defer:false)
        win.title="About Headroom"; win.isReleasedWhenClosed=false
        win.contentView?.addSubview(sv); win.contentView?.addSubview(ok)
        win.center(); win.makeKeyAndOrderFront(nil); NSApp.runModal(for:win); win.orderOut(nil)
    }

    @objc func closeAboutWindow() { NSApp.stopModal() }

    // MARK: - Updates

    func checkForUpdatesSilently() {
        let url=URL(string:"https://raw.githubusercontent.com/rm25s2yh75-hue/headroom/main/version.json")!
        let cur=Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        URLSession.shared.dataTask(with:url) { data,_,error in
            DispatchQueue.main.async {
                guard let data=data, error==nil,
                      let json=try? JSONSerialization.jsonObject(with:data) as? [String:String],
                      let latest=json["version"], let dlURL=json["download_url"],
                      let notes=json["release_notes"],
                      latest.compare(cur,options:.numeric) == .orderedDescending else { return }
                let a=NSAlert()
                a.messageText="Update Available — v\(latest)"; a.informativeText="\(notes)\n\nYou are on v\(cur)."
                a.addButton(withTitle:"Download"); a.addButton(withTitle:"Later")
                if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string:dlURL)!) }
            }
        }.resume()
    }

    @objc func checkForUpdates() {
        let url=URL(string:"https://raw.githubusercontent.com/rm25s2yh75-hue/headroom/main/version.json")!
        let cur=Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        URLSession.shared.dataTask(with:url) { data,_,error in
            DispatchQueue.main.async {
                guard let data=data, error==nil,
                      let json=try? JSONSerialization.jsonObject(with:data) as? [String:String],
                      let latest=json["version"], let dlURL=json["download_url"], let notes=json["release_notes"]
                else { self.showAlert(title:"Update Check Failed", message:"Could not reach the update server."); return }
                if latest.compare(cur,options:.numeric) == .orderedDescending {
                    let a=NSAlert(); a.messageText="Update Available — v\(latest)"; a.informativeText="\(notes)\n\nYou are on v\(cur)."
                    a.addButton(withTitle:"Download"); a.addButton(withTitle:"Later")
                    if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string:dlURL)!) }
                } else { self.showAlert(title:"You're Up to Date", message:"Headroom v\(cur) is the latest version.") }
            }
        }.resume()
    }

    func showAlert(title: String, message: String) {
        let a=NSAlert(); a.messageText=title; a.informativeText=message; a.addButton(withTitle:"OK"); a.runModal()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

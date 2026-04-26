import Cocoa
import UserNotifications
import Darwin

// MARK: - Per-process info

struct ProcInfo {
    let pid: Int32
    let name: String
    let residentBytes: UInt64
    var cpuPercent: Double = 0.0
}

// MARK: - Shared colours  (one definition, used everywhere)

let kColorGreen  = NSColor(srgbRed: 0.30, green: 0.78, blue: 0.46, alpha: 1.0)
let kColorAmber  = NSColor(srgbRed: 0.91, green: 0.75, blue: 0.19, alpha: 1.0)
let kColorRed    = NSColor(srgbRed: 0.91, green: 0.33, blue: 0.33, alpha: 1.0)
let kDotColors   = [kColorGreen, kColorAmber, kColorRed]

// MARK: - Line graph view

class LineGraphView: NSView {
    var values: [Double] = []
    var lineColor: NSColor = kColorGreen
    var graphTitle: String = ""
    private let titleFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    override func draw(_ dirtyRect: NSRect) {
        let padX: CGFloat = 8, titleH: CGFloat = 15, padB: CGFloat = 4
        let ta: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: NSColor.secondaryLabelColor]
        NSAttributedString(string: graphTitle, attributes: ta)
            .draw(at: NSPoint(x: padX, y: bounds.height - titleH - 1))
        if let last = values.last {
            let va: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: lineColor]
            let vs = NSAttributedString(string: String(format: "%.0f%%", last), attributes: va)
            vs.draw(at: NSPoint(x: bounds.width - vs.size().width - padX, y: bounds.height - titleH - 1))
        }
        drawLine(in: NSRect(x: padX, y: padB, width: bounds.width - padX*2,
                            height: bounds.height - titleH - padB - 4))
    }

    private func drawLine(in rect: NSRect) {
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
    var isOn: Bool  = false { didSet { needsDisplay = true } }
    var onChange: ((Bool) -> Void)?

    private var hovering = false
    private let itemFont = NSFont.menuFont(ofSize: 0)

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // Stretch to fill the menu's actual width, which varies based on item content
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
        if hovering { NSColor.selectedContentBackgroundColor.setFill(); bounds.fill() }
        let fg = hovering ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        let attr: [NSAttributedString.Key: Any] = [.font: itemFont, .foregroundColor: fg]
        let midY = bounds.height / 2
        if isOn {
            let ck = NSAttributedString(string: "✓", attributes: attr)
            ck.draw(at: NSPoint(x: 14, y: midY - ck.size().height/2))
        }
        let ls = NSAttributedString(string: label, attributes: attr)
        ls.draw(at: NSPoint(x: 34, y: midY - ls.size().height/2))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true;  needsDisplay = true }
    override func mouseExited(with event:  NSEvent) { hovering = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        isOn = !isOn
        onChange?(isOn)      // update state
        needsDisplay = true  // redraw checkmark — menu stays open
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
    var ramHistory:      [Double] = []
    var cpuHistory:      [Double] = []
    var pressureHistory: [Double] = []
    let historyMax = 20

    // ── Cached computed values ──
    var lastVMStats    = vm_statistics64()
    var lastRAM:      Double = 0
    var lastCPU:      Double = 0
    var lastSwap:     Double = 0
    var lastPressure: Int    = 0
    var lastNetDown:  Double = 0
    var lastNetUp:    Double = 0

    // ── Process cache ──
    var cachedTopRAMProcs: [ProcInfo] = []
    var cachedTopCPUProcs: [ProcInfo] = []
    var procRefreshTick = 0
    var prevProcTicks: [Int32: UInt64] = [:]
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
    var menuIsOpen = false
    var livePressureItem:      NSMenuItem?
    var liveStatsItem:         NSMenuItem?
    var liveSwapItem:          NSMenuItem?
    var liveNetItem:           NSMenuItem?
    var liveUptimeItem:        NSMenuItem?
    var livePressureGraph:     LineGraphView?
    var liveRAMGraph:          LineGraphView?
    var liveCPUGraph:          LineGraphView?
    // Graph wrapper items — always created; isHidden toggled live
    var livePressureGraphItem: NSMenuItem?
    var liveRAMGraphItem:      NSMenuItem?
    var liveCPUGraphItem:      NSMenuItem?

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
        lastPressure = systemPressureLevel(from: lastVMStats, swapGB: lastSwap, cpu: lastCPU)
        let net      = networkSpeeds()
        lastNetDown  = net.down; lastNetUp = net.up

        ramHistory.append(lastRAM);                     if ramHistory.count      > historyMax { ramHistory.removeFirst() }
        cpuHistory.append(lastCPU);                     if cpuHistory.count      > historyMax { cpuHistory.removeFirst() }
        pressureHistory.append(Double(lastPressure)*50); if pressureHistory.count > historyMax { pressureHistory.removeFirst() }

        maybeSendPressureNotification(newLevel: lastPressure)
        prevPressureLevel = lastPressure

        procRefreshTick += 1
        let ticksNeeded = max(1, Int(10.0 / refreshInterval))
        if procRefreshTick >= ticksNeeded || cachedTopRAMProcs.isEmpty {
            let all = topProcesses()
            cachedTopRAMProcs = Array(all.sorted { $0.residentBytes > $1.residentBytes }.prefix(10))
            cachedTopCPUProcs = Array(all.filter { $0.cpuPercent > 0.1 }
                                         .sorted { $0.cpuPercent > $1.cpuPercent }.prefix(10))
            procRefreshTick = 0
        }

        updateBarTitle()

        // Live-update open menu in-place (no rebuild, no flicker)
        if menuIsOpen { updateLiveMenuItems() }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        menu.removeAllItems()
        buildMenuItems(into: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // Clear refs so they can be GC'd
        livePressureItem = nil; liveStatsItem = nil; liveSwapItem = nil
        liveNetItem = nil; liveUptimeItem = nil
        livePressureGraph = nil; liveRAMGraph = nil; liveCPUGraph = nil
        livePressureGraphItem = nil; liveRAMGraphItem = nil; liveCPUGraphItem = nil
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

    func ramPressureLevel(from v: vm_statistics64, swapGB: Double) -> Int {
        let ratio = Double(v.compressor_page_count) / Double(ProcessInfo.processInfo.physicalMemory / UInt64(vm_page_size))
        if ratio > 0.75 || swapGB > 8 { return 2 }
        if ratio > 0.45 || swapGB > 3 { return 1 }
        return 0
    }
    func cpuPressureLevel(cpu: Double) -> Int { cpu > 90 ? 2 : cpu > 75 ? 1 : 0 }
    func systemPressureLevel(from v: vm_statistics64, swapGB: Double, cpu: Double) -> Int {
        max(ramPressureLevel(from: v, swapGB: swapGB), cpuPressureLevel(cpu: cpu))
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
        var newTicks:[Int32:UInt64]=[:], results:[ProcInfo]=[]
        for p in procs {
            let pid=p.kp_proc.p_pid; guard pid>1 else { continue }
            var ti=proc_taskinfo()
            guard proc_pidinfo(pid,PROC_PIDTASKINFO,0,&ti,Int32(MemoryLayout<proc_taskinfo>.size))>0 else { continue }
            guard ti.pti_resident_size>5*1024*1024 else { continue }
            var nb=[CChar](repeating:0,count:1024); proc_name(pid,&nb,UInt32(nb.count))
            let name=String(cString:nb); guard !name.isEmpty else { continue }
            let ticks=ti.pti_total_user+ti.pti_total_system; newTicks[pid]=ticks
            var cpu=0.0
            if let prev=prevProcTicks[pid], el>0.1 { cpu=min(999,(Double(ticks-prev)/1e9)/el*100) }
            results.append(ProcInfo(pid:pid,name:name,residentBytes:ti.pti_resident_size,cpuPercent:cpu))
        }
        if el>0.5 { prevProcTicks=newTicks; prevProcTime=now }
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
        if showRAM { parts.append(String(format: "R %.0f%%", lastRAM)) }
        if showCPU { parts.append(String(format: "C %.0f%%", lastCPU)) }
        if !parts.isEmpty {
            t.append(NSAttributedString(string: parts.joined(separator: "  "), attributes: [.font: font]))
        }
        if t.length == 0 { t.append(NSAttributedString(string: "●", attributes: [.font: font])) }
        statusItem.button?.attributedTitle = t
    }

    // MARK: - Live in-place update (called by tick when menu is open)

    func updateLiveMenuItems() {
        let labels = ["Healthy", "Moderate", "High"]
        if let item = livePressureItem {
            let s = NSMutableAttributedString(string: "● ",
                attributes: [.foregroundColor: kDotColors[lastPressure]])
            s.append(NSAttributedString(string: "System Pressure: \(labels[lastPressure])"))
            item.attributedTitle = s
        }
        liveStatsItem?.title  = String(format: "RAM: %.0f%%   CPU: %.0f%%", lastRAM, lastCPU)
        liveSwapItem?.title   = lastSwap > 0.01 ? String(format: "Swap: %.2f GB", lastSwap) : "Swap: none"
        liveNetItem?.title    = "↓ \(formatSpeed(lastNetDown))   ↑ \(formatSpeed(lastNetUp))"
        liveUptimeItem?.title = "Uptime: \(systemUptime())"

        if let gv = livePressureGraph {
            gv.values     = Array(pressureHistory.suffix(20))
            gv.lineColor  = kDotColors[lastPressure]
            gv.needsDisplay = true
        }
        if let gv = liveRAMGraph {
            gv.values = Array(ramHistory.suffix(20)); gv.needsDisplay = true
        }
        if let gv = liveCPUGraph {
            gv.values = Array(cpuHistory.suffix(20)); gv.needsDisplay = true
        }
    }

    // MARK: - Menu builder

    func buildMenuItems(into menu: NSMenu) {
        let labels = ["Healthy", "Moderate", "High"]

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

        let statsItem = info(String(format: "RAM: %.0f%%   CPU: %.0f%%", lastRAM, lastCPU))
        menu.addItem(statsItem); liveStatsItem = statsItem

        let swapItem = info(lastSwap > 0.01 ? String(format: "Swap: %.2f GB", lastSwap) : "Swap: none")
        menu.addItem(swapItem); liveSwapItem = swapItem

        let netItem = info("↓ \(formatSpeed(lastNetDown))   ↑ \(formatSpeed(lastNetUp))")
        menu.addItem(netItem); liveNetItem = netItem

        let uptimeItem = info("Uptime: \(systemUptime())")
        menu.addItem(uptimeItem); liveUptimeItem = uptimeItem

        // ── Graphs ──
        // Always create all three graph items. isHidden controls visibility so
        // the toggle can flip it in-place without rebuilding the menu.
        sep()
        func makeGraphItem(title: String, values: [Double], color: NSColor, shown: Bool)
                -> (NSMenuItem, LineGraphView) {
            let gv = LineGraphView(frame: NSRect(x: 0, y: 0, width: 240, height: 54))
            gv.graphTitle = title; gv.values = Array(values.suffix(20)); gv.lineColor = color
            let item = NSMenuItem(); item.view = gv
            item.isHidden = !shown || values.count <= 1
            menu.addItem(item)
            return (item, gv)
        }
        let (pgItem, pgView) = makeGraphItem(title: "System Pressure Graph",
                                             values: pressureHistory,
                                             color: kDotColors[lastPressure],
                                             shown: showPressureGraph)
        livePressureGraphItem = pgItem; livePressureGraph = pgView

        let (rgItem, rgView) = makeGraphItem(title: "RAM Usage Graph",
                                             values: ramHistory, color: kColorGreen,
                                             shown: showRAMGraph)
        liveRAMGraphItem = rgItem; liveRAMGraph = rgView

        let (cgItem, cgView) = makeGraphItem(title: "CPU Usage Graph",
                                             values: cpuHistory, color: kColorAmber,
                                             shown: showCPUGraph)
        liveCPUGraphItem = cgItem; liveCPUGraph = cgView

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

        // ── Legend ──
        sep()
        menu.addItem(dotItem(text: "Healthy — RAM and CPU in good shape",     color: kColorGreen))
        menu.addItem(dotItem(text: "Moderate — RAM compressing or CPU > 75%", color: kColorAmber))
        menu.addItem(dotItem(text: "High — heavy swap or CPU > 90%",          color: kColorRed))

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
        toggleRow("System Pressure Graph", showPressureGraph) { [weak self] on in
            self?.showPressureGraph = on
            self?.livePressureGraphItem?.isHidden = !on
        }
        toggleRow("RAM Usage Graph", showRAMGraph) { [weak self] on in
            self?.showRAMGraph = on
            self?.liveRAMGraphItem?.isHidden = !on
        }
        toggleRow("CPU Usage Graph", showCPUGraph) { [weak self] on in
            self?.showCPUGraph = on
            self?.liveCPUGraphItem?.isHidden = !on
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
        t.append(b("A combined RAM + CPU health indicator:\n"))
        t.append(dot(kColorGreen, "Healthy — RAM and CPU both in good shape\n"))
        t.append(dot(kColorAmber, "Moderate — RAM compressing heavily, or CPU above 75%\n"))
        t.append(dot(kColorRed,   "High — heavy swap or CPU above 90%, performance may suffer\n\n"))
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

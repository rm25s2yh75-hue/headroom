import Cocoa
import Darwin

// MARK: - Per-process memory

struct ProcMemInfo {
    let name: String
    let residentBytes: UInt64
}

func topMemoryProcesses(limit: Int = 5) -> [ProcMemInfo] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

    let count = size / MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

    var results: [ProcMemInfo] = []

    for proc in procs {
        let pid = proc.kp_proc.p_pid
        guard pid > 1 else { continue }

        var taskInfo = proc_taskinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo,
                               Int32(MemoryLayout<proc_taskinfo>.size))
        guard ret > 0 else { continue }

        let resident = taskInfo.pti_resident_size
        guard resident > 30 * 1024 * 1024 else { continue } // skip < 30 MB

        var nameBuf = [CChar](repeating: 0, count: 1024)
        proc_name(pid, &nameBuf, UInt32(nameBuf.count))
        let name = String(cString: nameBuf)
        guard !name.isEmpty else { continue }

        results.append(ProcMemInfo(name: name, residentBytes: resident))
    }

    return Array(results.sorted { $0.residentBytes > $1.residentBytes }.prefix(limit))
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var prevCPUInfo: processor_info_array_t?
    var prevCPUInfoCount: mach_msg_type_number_t = 0

    var showDot: Bool = true
    var showRAM: Bool = true
    var showCPU: Bool = true

    var cachedTopProcs: [ProcMemInfo] = []
    var procRefreshTick = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStats()
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
    }

    // MARK: - Stats

    func fetchVMStats() -> vm_statistics64 {
        var vmStats = vm_statistics64()
        var infoCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                _ = host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &infoCount)
            }
        }
        return vmStats
    }

    func ramPercent(from vmStats: vm_statistics64) -> Double {
        let pageSize = UInt64(vm_page_size)
        let totalPages = ProcessInfo.processInfo.physicalMemory / pageSize
        let usedPages = UInt64(vmStats.active_count) + UInt64(vmStats.wire_count)
        return Double(usedPages) / Double(totalPages) * 100
    }

    func cpuPercent() -> Double {
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &cpuInfo, &cpuInfoCount) == KERN_SUCCESS,
              let info = cpuInfo else { return 0 }

        var totalUsed: Double = 0
        var totalAll: Double = 0

        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            let user   = Double(info[base + Int(CPU_STATE_USER)])
            let system = Double(info[base + Int(CPU_STATE_SYSTEM)])
            let nice   = Double(info[base + Int(CPU_STATE_NICE)])
            let idle   = Double(info[base + Int(CPU_STATE_IDLE)])

            var prevUser: Double = 0; var prevSystem: Double = 0
            var prevNice: Double = 0; var prevIdle: Double = 0

            if let prev = prevCPUInfo {
                prevUser   = Double(prev[base + Int(CPU_STATE_USER)])
                prevSystem = Double(prev[base + Int(CPU_STATE_SYSTEM)])
                prevNice   = Double(prev[base + Int(CPU_STATE_NICE)])
                prevIdle   = Double(prev[base + Int(CPU_STATE_IDLE)])
            }

            let used = (user - prevUser) + (system - prevSystem) + (nice - prevNice)
            totalUsed += used
            totalAll  += used + (idle - prevIdle)
        }

        if let prev = prevCPUInfo {
            let sz = vm_size_t(prevCPUInfoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev), sz)
        }
        prevCPUInfo = info
        prevCPUInfoCount = cpuInfoCount

        return totalAll > 0 ? (totalUsed / totalAll) * 100 : 0
    }

    func swapUsedGB() -> Double {
        var swapInfo = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swapInfo, &size, nil, 0)
        return Double(swapInfo.xsu_used) / 1_073_741_824
    }

    func pressureLevel(from vmStats: vm_statistics64, swapGB: Double) -> Int {
        let totalPages = ProcessInfo.processInfo.physicalMemory / UInt64(vm_page_size)
        let compressedRatio = Double(vmStats.compressor_page_count) / Double(totalPages)

        if compressedRatio > 0.75 || swapGB > 8.0 { return 2 }
        if compressedRatio > 0.45 || swapGB > 3.0 { return 1 }
        return 0
    }

    @objc func openKofi() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/jasa49")!)
    }

    // MARK: - Update checker

    @objc func checkForUpdates() {
        let versionURL = URL(string: "https://raw.githubusercontent.com/rm25s2yh75-hue/headroom/main/version.json")!
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

        URLSession.shared.dataTask(with: versionURL) { data, _, error in
            DispatchQueue.main.async {
                guard let data = data, error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                      let latest = json["version"],
                      let downloadURL = json["download_url"],
                      let notes = json["release_notes"]
                else {
                    self.showAlert(title: "Update Check Failed",
                                  message: "Could not reach the update server. Check your internet connection and try again.")
                    return
                }

                if latest.compare(currentVersion, options: .numeric) == .orderedDescending {
                    let alert = NSAlert()
                    alert.messageText = "Update Available — v\(latest)"
                    alert.informativeText = "\(notes)\n\nYou are on v\(currentVersion)."
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(string: downloadURL)!)
                    }
                } else {
                    self.showAlert(title: "You're Up to Date",
                                  message: "Headroom v\(currentVersion) is the latest version.")
                }
            }
        }.resume()
    }

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Toggles

    @objc func toggleDot(_ item: NSMenuItem) {
        showDot = !showDot; item.state = showDot ? .on : .off; updateStats()
    }
    @objc func toggleRAM(_ item: NSMenuItem) {
        showRAM = !showRAM; item.state = showRAM ? .on : .off; updateStats()
    }
    @objc func toggleCPU(_ item: NSMenuItem) {
        showCPU = !showCPU; item.state = showCPU ? .on : .off; updateStats()
    }

    // MARK: - Update

    func updateStats() {
        let vmStats = fetchVMStats()
        let ram = ramPercent(from: vmStats)
        let cpu = cpuPercent()
        let swap = swapUsedGB()
        let pressure = pressureLevel(from: vmStats, swapGB: swap)

        // Refresh process list every 10 seconds (every 5th tick)
        procRefreshTick += 1
        if procRefreshTick >= 5 || cachedTopProcs.isEmpty {
            cachedTopProcs = topMemoryProcesses()
            procRefreshTick = 0
        }

        // --- Menu bar title ---
        let font = NSFont.menuBarFont(ofSize: 0)
        let title = NSMutableAttributedString()

        if showDot {
            let dotColors: [NSColor] = [
                NSColor(calibratedRed: 0.30, green: 0.78, blue: 0.46, alpha: 1.0), // mint green
                NSColor(calibratedRed: 0.91, green: 0.75, blue: 0.19, alpha: 1.0), // amber
                NSColor(calibratedRed: 0.91, green: 0.33, blue: 0.33, alpha: 1.0), // coral red
            ]
            let dotColor = dotColors[pressure]
            title.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: dotColor, .font: font]))
        }
        var parts: [String] = []
        if showRAM { parts.append(String(format: "R %.0f%%", ram)) }
        if showCPU { parts.append(String(format: "C %.0f%%", cpu)) }
        if !parts.isEmpty {
            title.append(NSAttributedString(string: parts.joined(separator: "  "), attributes: [.font: font]))
        }
        if title.length == 0 {
            title.append(NSAttributedString(string: "●", attributes: [.font: font]))
        }
        statusItem.button?.attributedTitle = title

        // --- Menu ---
        let dotColors: [NSColor] = [
            NSColor(calibratedRed: 0.30, green: 0.78, blue: 0.46, alpha: 1.0), // mint green
            NSColor(calibratedRed: 0.91, green: 0.75, blue: 0.19, alpha: 1.0), // amber
            NSColor(calibratedRed: 0.91, green: 0.33, blue: 0.33, alpha: 1.0), // coral red
        ]

        func dotItem(text: String, color: NSColor) -> NSMenuItem {
            let item = NSMenuItem()
            let str = NSMutableAttributedString()
            str.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: color]))
            str.append(NSAttributedString(string: text))
            item.attributedTitle = str
            item.isEnabled = false
            return item
        }

        let pressureLabels = ["Healthy", "Moderate", "High"]
        let menu = NSMenu()

        // System summary
        menu.addItem(dotItem(text: "Memory Pressure: \(pressureLabels[pressure])", color: dotColors[pressure]))
        if swap > 0.01 {
            menu.addItem(withTitle: String(format: "Swap in use: %.2f GB", swap), action: nil, keyEquivalent: "")
        }

        // Top memory apps
        if !cachedTopProcs.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let header = NSMenuItem(title: "Top Memory Apps (est.)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let totalBytes = ProcessInfo.processInfo.physicalMemory
            let usedBytes = UInt64(vmStats.active_count + vmStats.wire_count) * UInt64(vm_page_size)
            let currentPct = Double(usedBytes) / Double(totalBytes) * 100

            for proc in cachedTopProcs {
                let mb = Double(proc.residentBytes) / 1_048_576
                let freed = min(proc.residentBytes, usedBytes)
                let newPct = Double(usedBytes - freed) / Double(totalBytes) * 100
                let drop = max(0, currentPct - newPct)

                let displayName = String(proc.name.prefix(22))
                let line = String(format: "%@  –  %.0f MB  (saves ~%.0f%%)", displayName, mb, drop)
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        // Colour legend
        menu.addItem(NSMenuItem.separator())
        menu.addItem(dotItem(text: "Healthy — memory is in good shape", color: dotColors[0]))
        menu.addItem(dotItem(text: "Moderate — macOS is compressing memory", color: dotColors[1]))
        menu.addItem(dotItem(text: "High — heavy swap use, close some apps", color: dotColors[2]))

        // Show/hide toggles
        menu.addItem(NSMenuItem.separator())
        let toggleHeader = NSMenuItem(title: "Show / Hide", action: nil, keyEquivalent: "")
        toggleHeader.isEnabled = false
        menu.addItem(toggleHeader)

        let dotItem = NSMenuItem(title: "  Pressure Dot", action: #selector(toggleDot(_:)), keyEquivalent: "")
        dotItem.state = showDot ? .on : .off; dotItem.target = delegate
        menu.addItem(dotItem)

        let ramItem = NSMenuItem(title: "  RAM %", action: #selector(toggleRAM(_:)), keyEquivalent: "")
        ramItem.state = showRAM ? .on : .off; ramItem.target = delegate
        menu.addItem(ramItem)

        let cpuItem = NSMenuItem(title: "  CPU %", action: #selector(toggleCPU(_:)), keyEquivalent: "")
        cpuItem.state = showCPU ? .on : .off; cpuItem.target = delegate
        menu.addItem(cpuItem)

        menu.addItem(NSMenuItem.separator())
        let updateItem = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = delegate
        menu.addItem(updateItem)
        let coffeeItem = NSMenuItem(title: "☕  Buy me a coffee", action: #selector(openKofi), keyEquivalent: "")
        coffeeItem.target = delegate
        menu.addItem(coffeeItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

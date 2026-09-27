// SuperCaffeinate: a menu bar item that mirrors ~/bin/supercaffeinate.
//
// State model matches the script exactly. /tmp/supercaffeinate.state holds
// three lines: the "caffeinate -ims" pid, the previous screensaver idleTime,
// and the lid watcher pid. The script's is_on() is "file exists AND kill -0
// pid succeeds", so a state file whose pid is dead is neither on nor off, it
// is broken, and this app says so instead of guessing.

import AppKit

let statePath = "/tmp/supercaffeinate.state"
let scriptPath = NSHomeDirectory() + "/bin/supercaffeinate"

enum CaffState: Equatable {
    case off
    case on(pid: pid_t, since: Date?)
    case broken(pid: pid_t)
}

// Cheap poll: one stat plus one kill(pid, 0). No subprocesses on the tick.
func readState() -> CaffState {
    var st = stat()
    guard stat(statePath, &st) == 0 else { return .off }

    guard let text = try? String(contentsOfFile: statePath, encoding: .utf8) else { return .off }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard let first = lines.first, let pid = pid_t(first.trimmingCharacters(in: .whitespaces)), pid > 0 else {
        return .off
    }

    // The state file is written the moment the script turns on, so its
    // modification time is when the current session started.
    let since = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))

    if kill(pid, 0) == 0 {
        return .on(pid: pid, since: since)
    }
    return .broken(pid: pid)
}

// Only asked for when the menu is about to open, never on a poll tick.
func lidClosed() -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    proc.arguments = ["-r", "-k", "AppleClamshellState", "-d", "1"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
    } catch {
        return false
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    let out = String(data: data, encoding: .utf8) ?? ""
    return out.contains("\"AppleClamshellState\" = Yes")
}

final class Controller: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var state: CaffState = .off
    var timer: Timer?
    var busy = false

    override init() {
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        refresh(force: true)
        let t = Timer(timeInterval: 2.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc func tick() {
        refresh(force: false)
    }

    func refresh(force: Bool) {
        let new = readState()
        if !force && new == state { return }
        state = new
        applyIcon()
        log(describe(new))
    }

    // One line per state change on stdout. Under the LaunchAgent that lands in
    // /tmp/supercaffeinate-menubar.out, which makes "what does the app think
    // the state is" answerable without clicking anything.
    func log(_ message: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        FileHandle.standardOutput.write(Data((fmt.string(from: Date()) + " " + message + "\n").utf8))
    }

    func describe(_ s: CaffState) -> String {
        switch s {
        case .off: return "state=off icon=cup.and.saucer"
        case .on(let pid, _): return "state=on pid=\(pid) icon=cup.and.saucer.fill"
        case .broken(let pid): return "state=broken pid=\(pid) icon=exclamationmark.triangle"
        }
    }

    func applyIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        let describe: String
        switch state {
        case .on:
            symbol = "cup.and.saucer.fill"
            describe = "supercaffeinate is on"
        case .off:
            symbol = "cup.and.saucer"
            describe = "supercaffeinate is off"
        case .broken:
            symbol = "exclamationmark.triangle"
            describe = "supercaffeinate state file is stale"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: describe)
        image?.isTemplate = true
        button.image = image
        button.toolTip = describe
    }

    // Menu contents are rebuilt each time it opens, so nothing is ever stale
    // and the ioreg lid query only runs on a real open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh(force: true)
        menu.removeAllItems()

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"

        switch state {
        case .on(_, let since):
            let when = since.map { " since " + fmt.string(from: $0) } ?? ""
            menu.addItem(disabled("Awake," + (when.isEmpty ? " on" : when)))
            menu.addItem(disabled(lidClosed()
                ? "Lid closed: screen black, system running"
                : "Lid open: display held awake"))
        case .off:
            menu.addItem(disabled("Off"))
        case .broken(let pid):
            menu.addItem(disabled("Broken: state file says pid \(pid), not running"))
            menu.addItem(disabled("Run supercaffeinate off to clean up"))
        }

        menu.addItem(.separator())

        let action: NSMenuItem
        switch state {
        case .on:
            action = NSMenuItem(title: "Turn Off", action: #selector(turnOff), keyEquivalent: "")
        case .off:
            action = NSMenuItem(title: "Turn On", action: #selector(turnOn), keyEquivalent: "")
        case .broken:
            action = NSMenuItem(title: "Clean Up (Turn Off)", action: #selector(turnOff), keyEquivalent: "")
        }
        action.target = self
        action.isEnabled = !busy
        menu.addItem(action)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    @objc func turnOn() { run("on") }
    @objc func turnOff() { run("off") }

    // The script can take a moment (sudo pmset, pkill sweeps), so it never
    // runs on the main thread.
    func run(_ verb: String) {
        if busy { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: scriptPath)
            proc.arguments = [verb]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            DispatchQueue.main.async {
                self.busy = false
                self.refresh(force: true)
            }
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()

// --dump-menu builds the menu exactly as a click would and prints it, so the
// menu can be checked without clicking anything.
if CommandLine.arguments.contains("--dump-menu") {
    controller.menuNeedsUpdate(controller.menu)
    for mi in controller.menu.items {
        print(mi.isSeparatorItem ? "---" : mi.title + (mi.isEnabled ? "" : " (disabled)"))
    }
    exit(0)
}

app.run()

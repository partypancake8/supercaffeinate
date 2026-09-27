// SuperCaffeinate: a menu bar item that mirrors ~/bin/supercaffeinate.
//
// State model matches the script exactly. /tmp/supercaffeinate.state holds
// the "caffeinate -ims" pid, the previous screensaver idleTime, the lid
// watcher pid, and (line 4, optional) the auto-off deadline in epoch seconds,
// 0 or missing when there is no timer. The script's is_on() is "file exists AND kill -0
// pid succeeds", so a state file whose pid is dead is neither on nor off, it
// is broken, and this app says so instead of guessing.

import AppKit

let statePath = "/tmp/supercaffeinate.state"
let scriptPath = NSHomeDirectory() + "/bin/supercaffeinate"

enum CaffState: Equatable {
    case off
    case on(pid: pid_t, since: Date?, deadline: Date?)
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

    // Line 4: auto-off deadline, absent or 0 when the session is indefinite.
    var deadline: Date?
    if lines.count > 3, let secs = TimeInterval(lines[3].trimmingCharacters(in: .whitespaces)), secs > 0 {
        deadline = Date(timeIntervalSince1970: secs)
    }

    if kill(pid, 0) == 0 {
        return .on(pid: pid, since: since, deadline: deadline)
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
        case .on(let pid, _, let deadline):
            let timer = deadline.map { " deadline=\(Int($0.timeIntervalSince1970))" } ?? ""
            return "state=on pid=\(pid)\(timer) icon=cup.and.saucer.fill"
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
        case .on(_, let since, let deadline):
            if let deadline = deadline {
                menu.addItem(disabled("Awake, " + remaining(until: deadline)))
            } else {
                let when = since.map { " since " + fmt.string(from: $0) } ?? ""
                menu.addItem(disabled("Awake," + (when.isEmpty ? " on" : when)))
            }
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

        var actions: [NSMenuItem] = []
        switch state {
        case .on:
            actions.append(NSMenuItem(title: "Turn Off", action: #selector(turnOff), keyEquivalent: ""))
        case .off:
            actions.append(NSMenuItem(title: "Turn On", action: #selector(turnOn), keyEquivalent: ""))
            actions.append(NSMenuItem(title: "Turn On For...", action: #selector(turnOnFor), keyEquivalent: ""))
        case .broken:
            actions.append(NSMenuItem(title: "Clean Up (Turn Off)", action: #selector(turnOff), keyEquivalent: ""))
        }
        for action in actions {
            action.target = self
            action.isEnabled = !busy
            menu.addItem(action)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // "7h 42m left", minutes rounded up so it never reads 0m while still on.
    func remaining(until deadline: Date) -> String {
        let secs = Int(deadline.timeIntervalSinceNow)
        if secs <= 0 { return "turning off" }
        let mins = (secs + 59) / 60
        let h = mins / 60
        let m = mins % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m left" }
        if h > 0 { return "\(h)h left" }
        return "\(m)m left"
    }

    func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    @objc func turnOn() { run(["on"]) }
    @objc func turnOff() { run(["off"]) }

    // Asks for a number of hours. Empty or 0 means indefinite; anything else
    // must be a number greater than 0 and at most 1000, or the alert comes
    // back with an error line and nothing runs.
    @objc func turnOnFor() {
        let prompt = "Enter hours, or leave blank for indefinite. It turns itself off when the time is up."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Hours, e.g. 8 or 0.5"

        let label = NSTextField(labelWithString: "Hours")
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.spacing = 8
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 24)

        var error: String?
        while true {
            let alert = NSAlert()
            alert.messageText = "Turn On For..."
            alert.informativeText = error.map { prompt + "\n" + $0 } ?? prompt
            alert.addButton(withTitle: "Turn On")
            alert.addButton(withTitle: "Cancel")
            alert.accessoryView = row
            alert.window.initialFirstResponder = field

            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                run(["on"])
                return
            }
            guard let hours = Double(text), hours.isFinite, hours >= 0, hours <= 1000 else {
                error = "\"\(text)\" is not a valid number of hours (0 to 1000)."
                continue
            }
            if hours == 0 {
                run(["on"])
                return
            }
            let minutes = Int((hours * 60).rounded())
            if minutes < 1 {
                error = "That is under a minute. Enter at least 0.02 hours."
                continue
            }
            run(["on", "\(minutes)m"])
            return
        }
    }

    // The script can take a moment (sudo pmset, pkill sweeps), so it never
    // runs on the main thread.
    func run(_ args: [String]) {
        if busy { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: scriptPath)
            proc.arguments = args
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

// MoEShift.app — a small native macOS control panel for a local MoEShift server.
//
// Built with swiftc against the Command Line Tools SDK (no Xcode required):
//   swiftc -O -o MoEShift.app/Contents/MacOS/MoEShift main.swift
//
// Design notes:
//  * The server is launched as a child process and killed on quit, so the app
//    can never leave an orphan instance holding port 8080.
//  * Status and "busy" come from the HTTP API (/health, /v1/models). Progress,
//    prompt rate and generation rate come from parsed log lines, because the
//    server exposes no metrics endpoint.
//  * Log files are followed by tracking a byte offset rather than re-reading
//    the whole file every tick.

import Cocoa
import Foundation

// MARK: - Paths

let home = FileManager.default.homeDirectoryForCurrentUser
let moeshiftBin = home.appendingPathComponent(".local/bin/moeshift")
let configPath = home.appendingPathComponent(".config/moeshift/config.json")
let logDir = home.appendingPathComponent("Library/Logs")
let logPath = logDir.appendingPathComponent("moeshift.app.log")
let baseURL = URL(string: "http://127.0.0.1:8080")!

// MARK: - Log parsing

struct LogSnapshot {
    var promptProgress: (tokens: Int, progress: Double)? = nil
    var lastPrompt: (tokens: Int, tps: Double)? = nil
    var lastGen: (tokens: Int, tps: Double)? = nil
    var streaming: (decoded: Int, tps: Double)? = nil
    var model: String? = nil
    var busy = false
    var errors: [String] = []
}

func firstMatch(_ pattern: String, _ line: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    guard let m = re.firstMatch(in: line, range: range) else { return nil }
    var out: [String] = []
    for i in 1..<m.numberOfRanges {
        if let r = Range(m.range(at: i), in: line) { out.append(String(line[r])) }
        else { out.append("") }
    }
    return out
}

func summarize(_ lines: [String]) -> LogSnapshot {
    var s = LogSnapshot()
    for line in lines {
        if let g = firstMatch(#"prompt processing, n_tokens\s*=\s*(\d+), progress = ([\d.]+)"#, line) {
            s.promptProgress = (Int(g[0]) ?? 0, Double(g[1]) ?? 0)
            s.busy = true
        }
        if let g = firstMatch(#"prompt eval time =\s*([\d.]+) ms /\s*(\d+) tokens.*?([\d.]+) tokens per second"#, line) {
            s.lastPrompt = (Int(g[1]) ?? 0, Double(g[2]) ?? 0)
        }
        if let g = firstMatch(#"n_decoded\s*=\s*(\d+), tg\s*=\s*([\d.]+) t/s"#, line) {
            s.streaming = (Int(g[0]) ?? 0, Double(g[1]) ?? 0)
            s.busy = true
        } else if let g = firstMatch(#"eval time =\s*([\d.]+) ms /\s*(\d+) tokens.*?([\d.]+) tokens per second"#, line) {
            s.lastGen = (Int(g[1]) ?? 0, Double(g[2]) ?? 0)
        }
        if let g = firstMatch(#"load_model: loading model '([^']+)'"#, line) {
            s.model = (g[0] as NSString).lastPathComponent
        }
        if line.contains("processing task, is_child") { s.busy = true }
        if line.contains("all slots are idle") {
            s.busy = false
            s.promptProgress = nil
        }
        let lower = line.lowercased()
        if (lower.contains("error") || lower.contains("failed")) && !lower.contains("http client error") {
            s.errors.append(line)
        }
    }
    s.errors = Array(s.errors.suffix(3))
    return s
}

/// Follows one log file by byte offset, keeping a bounded ring of recent lines.
final class LogFollower {
    private(set) var lines: [String] = []
    private var offset: UInt64 = 0
    private let limit = 400

    func reset() {
        lines.removeAll()
        offset = 0
    }

    func append(_ line: String) {
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    func poll() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath.path),
              let size = attrs[.size] as? UInt64 else { return }
        if size < offset { reset() }          // file was rotated or truncated
        guard size > offset else { return }
        guard let handle = try? FileHandle(forReadingFrom: logPath) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset += UInt64(data.count)
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !line.isEmpty { lines.append(String(line)) }
        }
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }
}

// MARK: - HTTP

func httpGet(_ path: String, timeout: TimeInterval, _ done: @escaping (Int?, Data?) -> Void) {
    var req = URLRequest(url: baseURL.appendingPathComponent(path))
    req.timeoutInterval = timeout
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        let code = (resp as? HTTPURLResponse)?.statusCode
        DispatchQueue.main.async { done(code, data) }
    }.resume()
}

/// GET with up to three attempts: the server intermittently answers 404 while a
/// long generation is running, then recovers on its own.
func httpGetRetrying(_ path: String, attempts: Int = 3, _ done: @escaping (Int?) -> Void) {
    var left = attempts
    func attempt() {
        httpGet(path, timeout: 3) { code, _ in
            if code == 200 || left <= 1 {
                done(code)
            } else {
                left -= 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { attempt() }
            }
        }
    }
    attempt()
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var process: Process?
    let follower = LogFollower()

    // UI
    let statusDot = NSView()
    let statusLabel = NSTextField(labelWithString: "stopped")
    let modelLabel = NSTextField(labelWithString: "—")
    let healthLabel = NSTextField(labelWithString: "—")
    let endpointLabel = NSTextField(labelWithString: "http://127.0.0.1:8080/v1")
    let progress = NSProgressIndicator()
    let phaseLabel = NSTextField(labelWithString: "idle")
    let rateLabel = NSTextField(labelWithString: "—")
    let logView = NSTextView()
    let startButton = NSButton(title: "Start", target: nil, action: nil)
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    let followCheck = NSButton(checkboxWithTitle: "Follow log", target: nil, action: nil)
    let settingsButton = NSButton(title: "Settings…", target: nil, action: nil)
    let settingsController = SettingsController()

    var isUp = false

    // MARK: launch

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        buildWindow()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ note: Notification) {
        stopServer(force: true)
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MoEShift", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.onSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MoEShift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    // MARK: window

    func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingMiddle
        return l
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "MoEShift"
        window.center()
        window.setFrameAutosaveName("MoEShiftMain")
        window.isReleasedWhenClosed = false

        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]

        // --- status row
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        startButton.target = self; startButton.action = #selector(onStart)
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "r"
        stopButton.target = self; stopButton.action = #selector(onStop)
        stopButton.bezelStyle = .rounded
        followCheck.state = .on
        followCheck.target = self; followCheck.action = #selector(onToggleFollow)

        settingsButton.title = "Settings…"
        settingsButton.target = self
        settingsButton.action = #selector(onSettings)
        settingsButton.bezelStyle = .rounded

        let statusRow = NSStackView(views: [statusDot, statusLabel, NSView(), followCheck, settingsButton, startButton, stopButton])
        statusRow.orientation = .horizontal
        statusRow.spacing = 10
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),
        ])

        // --- info grid
        let grid = NSGridView(views: [
            [label("Model", weight: .semibold), modelLabel],
            [label("Health", weight: .semibold), healthLabel],
            [label("Endpoint", weight: .semibold), endpointLabel],
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 0).width = 90
        modelLabel.lineBreakMode = .byTruncatingTail
        grid.translatesAutoresizingMaskIntoConstraints = false

        // --- progress
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        progress.controlSize = .regular
        progress.style = .bar
        progress.translatesAutoresizingMaskIntoConstraints = false

        let progressRow = NSStackView(views: [phaseLabel, NSView(), rateLabel])
        progressRow.orientation = .horizontal
        progressRow.translatesAutoresizingMaskIntoConstraints = false

        // --- log
        logView.isEditable = false
        logView.isRichText = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .textColor
        logView.backgroundColor = .textBackgroundColor
        logView.drawsBackground = true
        logView.textContainerInset = NSSize(width: 6, height: 6)
        logView.isVerticallyResizable = true
        logView.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.borderType = .bezelBorder
        scroll.documentView = logView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let logHeader = label("Log  " + logPath.path, size: 11, color: .secondaryLabelColor)

        let stack = NSStackView(views: [statusRow, grid, progress, progressRow, logHeader, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: process control

    @objc func onStart() {
        startServer()
    }

    @objc func onStop() {
        stopServer(force: false)
    }

    @objc func onToggleFollow() {}

    @objc func onSettings() {
        settingsController.onSaved = { [weak self] needsRestart in
            guard let self = self else { return }
            self.appendLogLine("[panel] settings saved")
            if needsRestart {
                let wasRunning = (self.process?.isRunning ?? false) || self.isUp
                if wasRunning {
                    let a = NSAlert()
                    a.messageText = "Restart the server?"
                    a.informativeText = "Server settings changed. Restarting now applies them; the model reloads in about a minute."
                    a.addButton(withTitle: "Restart Now")
                    a.addButton(withTitle: "Later")
                    if a.runModal() == .alertFirstButtonReturn {
                        self.stopServer(force: false)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.startServer()
                        }
                    }
                }
            }
            self.refresh()
        }
        settingsController.show()
    }

    func startServer() {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: moeshiftBin.path) else {
            alert("MoEShift binary not found at \(moeshiftBin.path)")
            return
        }
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            alert("No configuration at \(configPath.path).\nRun the MoEShift setup wizard first.")
            return
        }
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logPath.path) {
            FileManager.default.createFile(atPath: logPath.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logPath) else {
            alert("Cannot open the log file for writing.")
            return
        }
        handle.seekToEndOfFile()
        follower.reset()

        let p = Process()
        p.executableURL = moeshiftBin
        p.arguments = ["--config", configPath.path]
        p.standardOutput = handle
        p.standardError = handle
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.process = nil
                self?.appendLogLine("[panel] server exited with status \(proc.terminationStatus)")
                self?.refresh()
            }
        }
        do {
            try p.run()
            process = p
            appendLogLine("[panel] started pid \(p.processIdentifier)")
            updateControls()
        } catch {
            alert("Failed to start MoEShift:\n\(error.localizedDescription)")
        }
    }

    func stopServer(force: Bool) {
        guard let p = process, p.isRunning else { return }
        p.terminate()                                   // SIGTERM to the group leader
        let deadline = Date().addingTimeInterval(force ? 3 : 8)
        while p.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
        process = nil
        updateControls()
    }

    // MARK: refresh

    func refresh() {
        follower.poll()
        let snap = summarize(follower.lines)
        renderLog()

        httpGetRetrying("/health") { [weak self] code in
            guard let self = self else { return }
            self.isUp = (code == 200)
            // Only describe activity while a server is actually answering;
            // otherwise old log lines would claim a model is generating.
            self.updateStatus(self.isUp ? snap : LogSnapshot())
            if self.isUp {
                self.httpGetModels()
            } else {
                self.modelLabel.stringValue = "—"
                self.healthLabel.stringValue = code == nil ? "not reachable" : "HTTP \(code!)"
            }
        }
        updateControls()
    }

    func httpGetModels() {
        httpGet("/v1/models", timeout: 6) { [weak self] code, data in
            guard let self = self else { return }
            guard code == 200, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["data"] as? [[String: Any]] else {
                self.modelLabel.stringValue = "—"
                self.healthLabel.stringValue = "ok (model list unavailable)"
                return
            }
            let ids = arr.compactMap { $0["id"] as? String }
            self.modelLabel.stringValue = ids.joined(separator: ", ")
            self.healthLabel.stringValue = "ok"
        }
    }

    func updateStatus(_ snap: LogSnapshot) {
        if let p = snap.promptProgress {
            progress.isHidden = false
            progress.doubleValue = p.progress
            phaseLabel.stringValue = String(format: "Reading prompt  %.0f%%  (%d tokens)", p.progress * 100, p.tokens)
        } else {
            progress.doubleValue = 0
            phaseLabel.stringValue = snap.busy ? "Generating…" : "Idle"
        }
        var parts: [String] = []
        if let s = snap.streaming { parts.append(String(format: "streaming %d tok @ %.2f tok/s", s.decoded, s.tps)) }
        if let g = snap.lastGen { parts.append(String(format: "last output %d tok @ %.2f tok/s", g.tokens, g.tps)) }
        if let p = snap.lastPrompt { parts.append(String(format: "prompt %d tok @ %.1f tok/s", p.tokens, p.tps)) }
        rateLabel.stringValue = parts.isEmpty ? "—" : parts.joined(separator: "   ·   ")
        if let m = snap.model, modelLabel.stringValue == "—" { modelLabel.stringValue = m }
    }

    func updateControls() {
        let running = (process?.isRunning ?? false) || isUp
        startButton.isEnabled = !running && process == nil
        stopButton.isEnabled = (process?.isRunning ?? false)
        let color: NSColor = isUp ? .systemGreen : (process == nil ? .secondaryLabelColor : .systemOrange)
        statusDot.layer?.backgroundColor = color.cgColor
        if isUp {
            statusLabel.stringValue = "running"
        } else if let p = process, p.isRunning {
            statusLabel.stringValue = "loading model…"
        } else {
            statusLabel.stringValue = "stopped"
        }
    }

    func renderLog() {
        let shown = follower.lines.suffix(followCheck.state == .on ? 300 : 4000)
        var text = shown.joined(separator: "\n")
        if text.isEmpty {
            text = [
                "No log from this panel yet.",
                "",
                "A server started outside the app writes its output elsewhere,",
                "so this pane stays empty even while one is running.",
                "",
                "Press Start to run your own instance here; the app stops it",
                "automatically when you quit.",
            ].joined(separator: "\n")
        }
        if logView.string != text {
            logView.string = text
            logView.scrollToEndOfDocument(nil)
        }
    }

    func appendLogLine(_ s: String) {
        follower.poll()
        follower.append(s)
        renderLog()
    }

    func alert(_ msg: String) {
        let a = NSAlert()
        a.messageText = "MoEShift"
        a.informativeText = msg
        a.runModal()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

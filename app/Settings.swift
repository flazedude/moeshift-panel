// Settings.swift — editable limits for the local MoEShift server and the DSH route.
//
// Two layers are configured here, because each owns a different part of a request:
//
//   Server (config.json)  ctx-size, prefill batch, expert-cache slots, threads.
//                         Applied by restarting the server. Because MoEShift sets
//                         LLAMA_KV_GROW=1, a larger ctx-size costs almost nothing
//                         until a conversation actually fills it.
//
//   DSH (cordis.patch.yml) contextWindow and maxTokens: what the harness believes
//                         the endpoint can do and how much output it asks for.
//                         Re-read per request, so no restart is needed.
//
// The YAML is edited surgically: a whole-file rewrite would destroy comments,
// ordering and other providers' entries in a file the user owns.

import Cocoa
import Foundation

// MARK: - Model of editable values

struct Limits {
    var ctxSize: Int              // server: args.ctx-size
    var prefillMaxTokens: Int     // server: args.prefill-max-tokens
    var moePrefillBank: Int       // server: args.moe-prefill-bank
    var protectedSlots: Int       // server env: LLAMA_MOE_PROTECTED_SLOTS
    var threads: Int              // server: args.threads
    var contextWindow: Int        // dsh: model contextWindow
    var maxTokens: Int            // dsh: model maxTokens
}

enum LimitsError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

// MARK: - Loading

final class LimitsStore {
    let configURL: URL
    let patchURL: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configURL = home.appendingPathComponent(".config/moeshift/config.json")
        patchURL = home.appendingPathComponent(".dsh/profiles/desktop/cordis.patch.yml")
    }

    /// Values currently on disk. Missing files or fields fall back to defaults.
    func load() -> Limits {
        var ctx = 65536, prefill = 3072, bank = 512, slots = 24
        var threads = max(1, ProcessInfo.processInfo.activeProcessorCount)
        if let data = try? Data(contentsOf: configURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = root["models"] as? [String: Any],
           let first = models.values.first as? [String: Any] {
            let args = first["args"] as? [String: Any] ?? [:]
            let env = first["env"] as? [String: Any] ?? [:]
            ctx = (args["ctx-size"] as? NSNumber)?.intValue ?? ctx
            prefill = (args["prefill-max-tokens"] as? NSNumber)?.intValue ?? prefill
            bank = (args["moe-prefill-bank"] as? NSNumber)?.intValue ?? bank
            threads = (args["threads"] as? NSNumber)?.intValue ?? threads
            slots = (env["LLAMA_MOE_PROTECTED_SLOTS"] as? NSNumber)?.intValue ?? slots
        }
        var window = ctx, maxOut = 8192
        if let text = try? String(contentsOf: patchURL, encoding: .utf8),
           let block = LimitsStore.moeshiftBlock(in: text) {
            if let v = LimitsStore.firstInt(#"(?<![A-Za-z])contextWindow:\s*(\d+)"#, in: block) { window = v }
            if let v = LimitsStore.firstInt(#"(?<![A-Za-z])maxTokens:\s*(\d+)"#, in: block) { maxOut = v }
        }
        return Limits(ctxSize: ctx, prefillMaxTokens: prefill, moePrefillBank: bank,
                      protectedSlots: slots, threads: threads,
                      contextWindow: window, maxTokens: maxOut)
    }

    // MARK: saving

    /// Writes both layers. Returns whether server-side values changed (a restart
    /// is then needed for them to take effect).
    func save(_ l: Limits) throws -> Bool {
        try validate(l)
        let before = load()
        let serverChanged = before.ctxSize != l.ctxSize
            || before.prefillMaxTokens != l.prefillMaxTokens
            || before.moePrefillBank != l.moePrefillBank
            || before.protectedSlots != l.protectedSlots
            || before.threads != l.threads

        try saveServer(l)
        try saveDsh(l)
        return serverChanged
    }

    func saveServer(_ l: Limits) throws {
        guard let data = try? Data(contentsOf: configURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var models = root["models"] as? [String: Any],
              let key = models.keys.first,
              var entry = models[key] as? [String: Any] else {
            throw LimitsError.message("Could not read \(configURL.path)")
        }
        var args = entry["args"] as? [String: Any] ?? [:]
        var env = entry["env"] as? [String: Any] ?? [:]
        args["ctx-size"] = l.ctxSize
        args["prefill-max-tokens"] = l.prefillMaxTokens
        args["moe-prefill-bank"] = l.moePrefillBank
        args["threads"] = l.threads
        env["LLAMA_MOE_PROTECTED_SLOTS"] = l.protectedSlots
        entry["args"] = args
        entry["env"] = env
        models[key] = entry
        root["models"] = models

        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys])
        // Back up once per save so a bad value is always recoverable.
        let backup = configURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: configURL, to: backup)
        try out.write(to: configURL, options: .atomic)
    }

    /// Surgically updates the moeshift provider block, leaving the rest untouched.
    func saveDsh(_ l: Limits) throws {
        guard var text = try? String(contentsOf: patchURL, encoding: .utf8) else {
            throw LimitsError.message("Could not read \(patchURL.path)")
        }
        guard let block = LimitsStore.moeshiftBlock(in: text) else {
            throw LimitsError.message("No `moeshift:` provider found in \(patchURL.lastPathComponent)")
        }
        var updated = block
        updated = LimitsStore.replaceInt(#"((?<![A-Za-z])contextWindow:\s*)\d+"#, in: updated, with: l.contextWindow)
        updated = LimitsStore.replaceInt(#"((?<![A-Za-z])maxTokens:\s*)\d+"#, in: updated, with: l.maxTokens)
        updated = LimitsStore.replaceInt(#"((?<![A-Za-z])defaultContextWindow:\s*)\d+"#, in: updated, with: l.contextWindow)
        updated = LimitsStore.replaceInt(#"((?<![A-Za-z])defaultMaxTokens:\s*)\d+"#, in: updated, with: l.maxTokens)
        text = text.replacingOccurrences(of: block, with: updated)

        let backup = patchURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: patchURL, to: backup)
        try text.write(to: patchURL, atomically: true, encoding: .utf8)
    }

    // MARK: validation

    func validate(_ l: Limits) throws {
        let maxCtx = 262144          // model's n_ctx_train
        if l.ctxSize < 2048 || l.ctxSize > maxCtx {
            throw LimitsError.message("Context length must be between 2048 and \(maxCtx) tokens.")
        }
        if l.ctxSize % 256 != 0 {
            throw LimitsError.message("Context length must be a multiple of 256 (nearest: \(Int((Double(l.ctxSize) / 256).rounded()) * 256)).")
        }
        if l.prefillMaxTokens < 256 || l.prefillMaxTokens > 16384 {
            throw LimitsError.message("Prefill batch must be between 256 and 16384 tokens.")
        }
        if l.moePrefillBank < 64 || l.moePrefillBank > 4096 {
            throw LimitsError.message("Expert cache slots must be between 64 and 4096.")
        }
        if l.protectedSlots < 0 || l.protectedSlots > 256 {
            throw LimitsError.message("Protected slots must be between 0 and 256.")
        }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        if l.threads < 1 || l.threads > cores {
            throw LimitsError.message("Threads must be between 1 and \(cores).")
        }
        if l.contextWindow > l.ctxSize {
            throw LimitsError.message("DSH context window (\(l.contextWindow)) cannot exceed the server's context length (\(l.ctxSize)); the server would reject the request.")
        }
        if l.maxTokens < 1 || l.maxTokens > l.contextWindow {
            throw LimitsError.message("Max output tokens must be between 1 and the DSH context window (\(l.contextWindow)).")
        }
    }

    // MARK: helpers

    /// The `moeshift:` provider block: from its own line up to the next key at
    /// the same indentation, or a top-level list item.
    static func moeshiftBlock(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "moeshift:" }) else {
            return nil
        }
        let indent = lines[start].prefix { $0 == " " }.count
        var end = lines.count
        for i in (start + 1)..<lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let thisIndent = line.prefix { $0 == " " }.count
            if thisIndent <= indent || line.hasPrefix("- ") {
                end = i
                break
            }
        }
        return lines[start..<end].joined(separator: "\n")
    }

    static func firstInt(_ pattern: String, in text: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }

    static func replaceInt(_ pattern: String, in text: String, with value: Int) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var result = ""
        var last = text.startIndex
        re.enumerateMatches(in: text, range: range) { m, _, _ in
            guard let m = m, let whole = Range(m.range(at: 0), in: text),
                  let prefixRange = Range(m.range(at: 1), in: text) else { return }
            result += text[last..<whole.lowerBound]
            result += String(text[prefixRange]) + String(value)
            last = whole.upperBound
        }
        result += text[last...]
        return result
    }
}

// MARK: - Settings window

final class SettingsController: NSObject {
    private var window: NSWindow!
    private let store = LimitsStore()
    private var fields: [String: NSTextField] = [:]

    var onSaved: ((Bool) -> Void)?      // Bool: server restart required

    private struct FieldSpec {
        let key: String
        let label: String
        let help: String
        let section: String
    }

    private let specs = [
        FieldSpec(key: "ctxSize", label: "Context length",
                  help: "Max conversation tokens. Memory grows only as it fills (KV is grown on demand).",
                  section: "Server — needs restart"),
        FieldSpec(key: "prefillMaxTokens", label: "Prefill batch",
                  help: "Tokens processed per batch. Smaller lowers peak memory, larger speeds long prompts.",
                  section: "Server — needs restart"),
        FieldSpec(key: "moePrefillBank", label: "Expert cache slots",
                  help: "Experts cached while reading prompts. More = fewer SSD reads, more RAM.",
                  section: "Server — needs restart"),
        FieldSpec(key: "protectedSlots", label: "Protected slots",
                  help: "Experts pinned in memory during generation. More = faster decode, more RAM.",
                  section: "Server — needs restart"),
        FieldSpec(key: "threads", label: "CPU threads",
                  help: "Threads for CPU work. More competes with other apps and is not always faster.",
                  section: "Server — needs restart"),
        FieldSpec(key: "contextWindow", label: "DSH context window",
                  help: "What the harness believes the endpoint supports. Must not exceed context length.",
                  section: "DeepSeek Harness — applies immediately"),
        FieldSpec(key: "maxTokens", label: "Max output tokens",
                  help: "Upper bound on tokens the harness asks the model to generate per reply.",
                  section: "DeepSeek Harness — applies immediately"),
    ]

    func show() {
        if window == nil { build() }
        populate()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false

        let container = NSView(frame: window.contentView!.bounds)
        var rows: [[NSView]] = []
        var lastSection = ""

        for spec in specs {
            if spec.section != lastSection {
                lastSection = spec.section
                let header = NSTextField(labelWithString: spec.section.uppercased())
                header.font = NSFont.systemFont(ofSize: 10, weight: .bold)
                header.textColor = .secondaryLabelColor
                rows.append([header, NSView()])
            }
            let name = NSTextField(labelWithString: spec.label)
            name.font = NSFont.systemFont(ofSize: 12)
            name.alignment = .right

            let field = NSTextField(string: "")
            field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            field.alignment = .right
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 110).isActive = true
            fields[spec.key] = field

            let help = NSTextField(wrappingLabelWithString: spec.help)
            help.font = NSFont.systemFont(ofSize: 10)
            help.textColor = .secondaryLabelColor
            help.preferredMaxLayoutWidth = 330

            rows.append([name, field])
            rows.append([NSView(), help])
        }

        let grid = NSGridView(views: rows)
        grid.columnSpacing = 10
        grid.rowSpacing = 4
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 140
        grid.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(wrappingLabelWithString:
            "Server settings are written to ~/.config/moeshift/config.json and need a restart. "
            + "Harness settings are written to cordis.patch.yml and apply on the next request. "
            + "A .bak copy is kept beside each file.")
        note.font = NSFont.systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 560

        let revert = NSButton(title: "Restore Defaults", target: self, action: #selector(onDefaults))
        revert.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(onCancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(onSave))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"

        let buttons = NSStackView(views: [revert, NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [grid, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -18),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.contentView = container
    }

    private func populate(_ l: Limits? = nil) {
        let v = l ?? store.load()
        fields["ctxSize"]?.stringValue = String(v.ctxSize)
        fields["prefillMaxTokens"]?.stringValue = String(v.prefillMaxTokens)
        fields["moePrefillBank"]?.stringValue = String(v.moePrefillBank)
        fields["protectedSlots"]?.stringValue = String(v.protectedSlots)
        fields["threads"]?.stringValue = String(v.threads)
        fields["contextWindow"]?.stringValue = String(v.contextWindow)
        fields["maxTokens"]?.stringValue = String(v.maxTokens)
    }

    @objc private func onDefaults() {
        populate(Limits(ctxSize: 65536, prefillMaxTokens: 3072, moePrefillBank: 512,
                        protectedSlots: 24,
                        threads: ProcessInfo.processInfo.activeProcessorCount,
                        contextWindow: 65536, maxTokens: 8192))
    }

    @objc private func onCancel() {
        window.orderOut(nil)
    }

    @objc private func onSave() {
        func int(_ key: String) -> Int? { Int(fields[key]?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") }
        guard let ctx = int("ctxSize"), let prefill = int("prefillMaxTokens"),
              let bank = int("moePrefillBank"), let slots = int("protectedSlots"),
              let threads = int("threads"), let ctxWindow = int("contextWindow"),
              let maxOut = int("maxTokens") else {
            alert("Every field needs a whole number.")
            return
        }
        let limits = Limits(ctxSize: ctx, prefillMaxTokens: prefill, moePrefillBank: bank,
                            protectedSlots: slots, threads: threads,
                            contextWindow: ctxWindow, maxTokens: maxOut)
        do {
            let needsRestart = try store.save(limits)
            window.orderOut(nil)
            onSaved?(needsRestart)
        } catch {
            alert(error.localizedDescription)
        }
    }

    private func alert(_ msg: String) {
        let a = NSAlert()
        a.messageText = "Settings not saved"
        a.informativeText = msg
        a.runModal()
    }
}

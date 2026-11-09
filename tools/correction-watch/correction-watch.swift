import ApplicationServices
import Cocoa

setvbuf(stdout, nil, _IOLBF, 0)

struct Options {
    var command = "watch"
    var historyDir: URL?
    var logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/correction-watch", isDirectory: true)
    var window = 30.0
    var keepText = true
    var days = 7
}

func usage() -> Never {
    print("""
    usage:
      correction-watch watch  [--history-dir DIR] [--log-dir DIR] [--window SECONDS] [--no-text]
      correction-watch report [--log-dir DIR] [--days N]
    """)
    exit(64)
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    if let first = args.first, !first.hasPrefix("-") { o.command = first; args.removeFirst() }
    var i = 0
    func next() -> String {
        i += 1
        guard i < args.count else { usage() }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--history-dir": o.historyDir = URL(fileURLWithPath: (next() as NSString).expandingTildeInPath)
        case "--log-dir": o.logDir = URL(fileURLWithPath: (next() as NSString).expandingTildeInPath)
        case "--window": o.window = Double(next()) ?? o.window
        case "--days": o.days = Int(next()) ?? o.days
        case "--no-text": o.keepText = false
        default: usage()
        }
        i += 1
    }
    guard ["watch", "report"].contains(o.command) else { usage() }
    return o
}

let opts = parseOptions()

func jsonlFiles(in dir: URL) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasSuffix(".jsonl") }.sorted().map { dir.appendingPathComponent($0) }
}

func modified(_ url: URL) -> Date {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
}

func detectHistoryDir() -> URL? {
    let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    let folders = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
    let candidates = folders.compactMap { folder -> (URL, Date)? in
        let dir = base.appendingPathComponent(folder).appendingPathComponent("history")
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("../settings.toml").standardized.path),
              let newest = jsonlFiles(in: dir).last else { return nil }
        return (dir, modified(newest))
    }.sorted { $0.1 > $1.1 }
    for (dir, date) in candidates { print("history candidate: \(dir.path) (last written \(date))") }
    return candidates.first?.0
}

struct Word {
    let raw: String
    let norm: String
}

let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "│┃"))
let trimmed = CharacterSet.punctuationCharacters.union(.symbols)

func words(_ text: String) -> [Word] {
    text.components(separatedBy: separators).compactMap { raw in
        guard !raw.isEmpty else { return nil }
        let norm = raw.trimmingCharacters(in: trimmed).lowercased()
        return Word(raw: raw, norm: norm.isEmpty ? raw : norm)
    }
}

func editRow(_ a: [Word], _ b: ArraySlice<Word>) -> [Int] {
    var prev = Array(0...b.count)
    var cur = prev
    for i in 1...max(a.count, 1) where !a.isEmpty {
        cur[0] = i
        for (j, w) in b.enumerated() {
            let cost = a[i - 1].norm == w.norm ? 0 : 1
            cur[j + 1] = min(prev[j] + cost, prev[j + 1] + 1, cur[j] + 1)
        }
        swap(&prev, &cur)
    }
    return prev
}

struct Match {
    let start: Int
    let length: Int
    let cost: Int
}

func locate(_ target: [Word], in field: [Word], near: Int?, maxCost: Int) -> Match? {
    let n = target.count
    guard n > 0, !field.isEmpty else { return nil }
    var starts = Set<Int>()
    if let near {
        let lo = max(0, near - 30), hi = min(field.count - 1, near + 30)
        if lo <= hi { for s in lo...hi { starts.insert(s) } }
    }
    let heads = Set(target.prefix(3).map(\.norm))
    let tails = Dictionary(target.suffix(3).enumerated().map { ($0.element.norm, n - min(3, n) + $0.offset) },
                           uniquingKeysWith: { a, _ in a })
    for (i, w) in field.enumerated() {
        if heads.contains(w.norm) {
            for (k, t) in target.prefix(3).enumerated() where t.norm == w.norm && i - k >= 0 { starts.insert(i - k) }
        }
        if let k = tails[w.norm], i - k >= 0 { starts.insert(i - k) }
    }
    var best: Match?
    for s in starts where s < field.count {
        let end = min(field.count, s + n + 3)
        let row = editRow(target, field[s..<end])
        let minLen = max(1, n - 3)
        guard end - s >= minLen else { continue }
        for len in minLen...(end - s) where len < row.count {
            let m = Match(start: s, length: len, cost: row[len])
            guard m.cost <= maxCost else { continue }
            if let b = best {
                let distance = { (x: Match) in near.map { abs(x.start - $0) } ?? -x.start }
                let rank = { (x: Match) in (x.cost, distance(x), abs(x.length - n)) }
                if rank(m) < rank(b) { best = m }
            } else {
                best = m
            }
        }
    }
    return best
}

struct Hunk: Codable {
    let from: String
    let to: String
    var kind: String {
        from.isEmpty ? "insert" : to.isEmpty ? "delete" : "replace"
    }
}

func hunks(_ a: [Word], _ b: [Word]) -> [Hunk] {
    let n = a.count, m = b.count
    var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in 0...n { d[i][0] = i }
    for j in 0...m { d[0][j] = j }
    if n > 0, m > 0 {
        for i in 1...n {
            for j in 1...m {
                let cost = a[i - 1].raw == b[j - 1].raw ? 0 : 1
                d[i][j] = min(d[i - 1][j - 1] + cost, d[i - 1][j] + 1, d[i][j - 1] + 1)
            }
        }
    }
    var ops: [(String?, String?)] = []
    var i = n, j = m
    while i > 0 || j > 0 {
        if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (a[i - 1].raw == b[j - 1].raw ? 0 : 1) {
            ops.append(a[i - 1].raw == b[j - 1].raw ? (nil, nil) : (a[i - 1].raw, b[j - 1].raw))
            i -= 1; j -= 1
        } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
            ops.append((a[i - 1].raw, "")); i -= 1
        } else {
            ops.append(("", b[j - 1].raw)); j -= 1
        }
    }
    var out: [Hunk] = []
    var from: [String] = [], to: [String] = []
    func flush() {
        if !from.isEmpty || !to.isEmpty { out.append(Hunk(from: from.joined(separator: " "), to: to.joined(separator: " "))) }
        from = []; to = []
    }
    for op in ops.reversed() {
        if op.0 == nil { flush(); continue }
        if let f = op.0, !f.isEmpty { from.append(f) }
        if let t = op.1, !t.isEmpty { to.append(t) }
    }
    flush()
    return out
}

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

func readText(_ e: AXUIElement) -> (String, String)? {
    if let s = attr(e, kAXValueAttribute) as? String, !s.isEmpty { return (s, "value") }
    if let n = attr(e, kAXNumberOfCharactersAttribute) as? Int, n > 0 {
        var r = CFRange(location: 0, length: n)
        let rv = AXValueCreate(.cfRange, &r)!
        var out: AnyObject?
        if AXUIElementCopyParameterizedAttributeValue(e, kAXStringForRangeParameterizedAttribute as CFString, rv, &out) == .success,
           let s = out as? String { return (s, "stringForRange") }
    }
    return nil
}

let tailLimit = 200_000

func fieldWords(_ text: String) -> [Word] {
    words(text.count > tailLimit ? String(text.suffix(tailLimit)) : text)
}

let isoFormatter = ISO8601DateFormatter()
let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
}()
let clockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

struct LogRecord: Codable {
    var at: String
    var dictatedAt: String?
    var historyLagSeconds: Double?
    var app: String
    var appName: String
    var outcome: String
    var dictatedWords: Int
    var focusRole: String?
    var readMethod: String?
    var located: Bool
    var initialMismatch: Int?
    var endReason: String
    var watchedSeconds: Double
    var changed: Bool
    var hunks: [Hunk]?
    var hunkKinds: [String]
    var dictated: String?
    var inField: String?
    var final: String?
}

var wokenPids = Set<pid_t>()

final class Session {
    let started = Date()
    let entryTime: Date?
    let outcome: String
    let dictated: [Word]
    let dictatedText: String
    let app: NSRunningApplication?
    let axApp: AXUIElement?
    var element: AXUIElement?
    var focusRole: String?
    var readMethod: String?
    var baseline: [Word]?
    var initialMismatch: Int?
    var last: [Word]?
    var lastStart: Int?
    var lastSeen = Date()
    var finished = false

    init(text: String, outcome: String, entryTime: Date?) {
        dictatedText = text
        dictated = words(text)
        self.outcome = outcome
        self.entryTime = entryTime
        app = NSWorkspace.shared.frontmostApplication
        axApp = app.map { AXUIElementCreateApplication($0.processIdentifier) }
        if let axApp { AXUIElementSetMessagingTimeout(axApp, 0.5) }
    }

    func acquireElement() -> AXUIElement? {
        if let element { return element }
        guard let axApp, let app else { return nil }
        if let f = attr(axApp, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() {
            let el = f as! AXUIElement
            if readText(el) != nil {
                element = el
                focusRole = attr(el, kAXRoleAttribute) as? String
                return el
            }
        }
        if !wokenPids.contains(app.processIdentifier) {
            wokenPids.insert(app.processIdentifier)
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        return nil
    }

    func isSecure(_ el: AXUIElement) -> Bool {
        ((attr(el, kAXSubroleAttribute) as? String) ?? "").localizedCaseInsensitiveContains("secure")
    }

    func tick() -> String? {
        let age = Date().timeIntervalSince(started)
        guard let el = acquireElement() else { return age > 4 ? "unreadable" : nil }
        if isSecure(el) { return "secure" }
        guard let read = readText(el) else {
            return baseline == nil ? (age > 4 ? "unreadable" : nil) : (Date().timeIntervalSince(lastSeen) > 2 ? "lost" : nil)
        }
        readMethod = read.1
        let fw = fieldWords(read.0)
        if baseline == nil {
            if let m = locate(dictated, in: fw, near: nil, maxCost: max(1, dictated.count / 5)) {
                baseline = Array(fw[m.start..<(m.start + m.length)])
                initialMismatch = m.cost
                last = baseline
                lastStart = m.start
                lastSeen = Date()
            } else if age > 4 {
                return "notFound"
            }
            return nil
        }
        guard let baseline else { return nil }
        if let m = locate(baseline, in: fw, near: lastStart, maxCost: max(2, baseline.count / 3)) {
            last = Array(fw[m.start..<(m.start + m.length)])
            lastStart = m.start
            lastSeen = Date()
        } else if Date().timeIntervalSince(lastSeen) > 2 {
            return "gone"
        }
        return age >= opts.window ? "window" : nil
    }

    func record(endReason: String) -> LogRecord {
        let found = hunks(baseline ?? [], last ?? [])
        let meaningful = found.filter { h in
            words(h.from).map(\.norm) != words(h.to).map(\.norm)
        }
        return LogRecord(
            at: isoFormatter.string(from: started),
            dictatedAt: entryTime.map { isoFormatter.string(from: $0) },
            historyLagSeconds: entryTime.map { (started.timeIntervalSince($0) * 10).rounded() / 10 },
            app: app?.bundleIdentifier ?? "?",
            appName: app?.localizedName ?? "?",
            outcome: outcome,
            dictatedWords: dictated.count,
            focusRole: focusRole,
            readMethod: readMethod,
            located: baseline != nil,
            initialMismatch: initialMismatch,
            endReason: endReason,
            watchedSeconds: (Date().timeIntervalSince(started) * 10).rounded() / 10,
            changed: !meaningful.isEmpty,
            hunks: opts.keepText ? meaningful : nil,
            hunkKinds: meaningful.map(\.kind),
            dictated: opts.keepText ? dictatedText : nil,
            inField: opts.keepText ? baseline.map { $0.map(\.raw).joined(separator: " ") } : nil,
            final: opts.keepText ? last.map { $0.map(\.raw).joined(separator: " ") } : nil)
    }
}

final class HistoryTail {
    let dir: URL
    var seen = Set<String>()
    var mtimes: [String: Date] = [:]

    init(dir: URL) {
        self.dir = dir
        for file in recentFiles() { _ = newEntries(in: file) }
    }

    func recentFiles() -> [URL] { Array(jsonlFiles(in: dir).suffix(2)) }

    func newEntries(in file: URL) -> [[String: Any]] {
        mtimes[file.lastPathComponent] = modified(file)
        guard let data = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var out: [[String: Any]] = []
        for line in data.split(separator: "\n") where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let key = (obj["id"] as? String) ?? String(line)
            if seen.insert(key).inserted { out.append(obj) }
        }
        return out
    }

    func poll() -> [[String: Any]] {
        recentFiles().flatMap { file -> [[String: Any]] in
            modified(file) == mtimes[file.lastPathComponent] ? [] : newEntries(in: file)
        }
    }
}

func appendLog(_ r: LogRecord) {
    try? FileManager.default.createDirectory(at: opts.logDir, withIntermediateDirectories: true)
    let file = opts.logDir.appendingPathComponent(dayFormatter.string(from: Date()) + ".jsonl")
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? enc.encode(r) else { return }
    let line = data + Data("\n".utf8)
    if let h = FileHandle(forWritingAtPath: file.path) {
        h.seekToEndOfFile()
        h.write(line)
        h.closeFile()
    } else {
        FileManager.default.createFile(atPath: file.path, contents: line, attributes: [.posixPermissions: 0o600])
    }
}

func describe(_ r: LogRecord) -> String {
    let what: String
    if !r.located {
        what = r.endReason
    } else if let hs = r.hunks, !hs.isEmpty {
        what = "changed: " + hs.map { "\($0.from.isEmpty ? "∅" : $0.from) → \($0.to.isEmpty ? "∅" : $0.to)" }.joined(separator: "; ")
    } else if r.changed {
        what = "changed: " + r.hunkKinds.joined(separator: ",")
    } else {
        what = "unchanged"
    }
    return "\(clockFormatter.string(from: Date()))  \(r.appName.padding(toLength: 14, withPad: " ", startingAt: 0))  \(what)"
}

func watch() {
    guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else {
        print("Accessibility access is needed. Allow the app running this command (your terminal) in")
        print("System Settings > Privacy & Security > Accessibility, then run it again.")
        exit(1)
    }
    guard let dir = opts.historyDir ?? detectHistoryDir() else {
        print("No dictation history found. Pass --history-dir, and make sure History is turned on.")
        exit(1)
    }
    let tail = HistoryTail(dir: dir)
    print("watching \(dir.path)")
    print("logging to \(opts.logDir.path)\(opts.keepText ? "" : " (no text)")  window \(Int(opts.window))s  ctrl-C to stop")
    var sessions: [Session] = []
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        for entry in tail.poll() {
            let outcome = entry["outcome"] as? String ?? ""
            let text = entry["result"] as? String ?? ""
            guard ["inserted", "local_fallback"].contains(outcome), !text.isEmpty else { continue }
            let time = (entry["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) }
            sessions.append(Session(text: text, outcome: outcome, entryTime: time))
        }
        for s in sessions where !s.finished {
            if let reason = s.tick() {
                s.finished = true
                let r = s.record(endReason: reason)
                appendLog(r)
                print(describe(r))
            }
        }
        sessions.removeAll { $0.finished }
    }
    RunLoop.main.run()
}

func report() {
    let dec = JSONDecoder()
    let cutoff = Calendar.current.date(byAdding: .day, value: -opts.days, to: Date())!
    let files = jsonlFiles(in: opts.logDir).filter { url in
        dayFormatter.date(from: url.deletingPathExtension().lastPathComponent).map { $0 >= cutoff } ?? false
    }
    let records = files.flatMap { url -> [LogRecord] in
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            try? dec.decode(LogRecord.self, from: Data($0.utf8))
        }
    }
    guard !records.isEmpty else { print("No records in \(opts.logDir.path) for the last \(opts.days) days."); return }
    func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : "\(a * 100 / b)%" }
    print("\(records.count) dictations, last \(opts.days) days\n")
    print("app                       dictations  readable  changed  end reasons")
    let byApp = Dictionary(grouping: records, by: \.appName).sorted { $0.value.count > $1.value.count }
    for (app, rs) in byApp {
        let located = rs.filter(\.located).count
        let changed = rs.filter(\.changed).count
        let reasons = Dictionary(grouping: rs, by: \.endReason).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")
        print(app.padding(toLength: 26, withPad: " ", startingAt: 0)
              + String(rs.count).padding(toLength: 12, withPad: " ", startingAt: 0)
              + pct(located, rs.count).padding(toLength: 10, withPad: " ", startingAt: 0)
              + pct(changed, located).padding(toLength: 9, withPad: " ", startingAt: 0)
              + reasons)
    }
    let replaces = records.flatMap { r in (r.hunks ?? []).filter { $0.kind == "replace" }.map { ($0, r.appName) } }
    guard !replaces.isEmpty else { return }
    print("\nreplaced words (heard → fixed), most frequent first")
    let grouped = Dictionary(grouping: replaces, by: { "\($0.0.from) → \($0.0.to)" })
        .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
    for (pair, items) in grouped.prefix(60) {
        let apps = Set(items.map(\.1)).sorted().joined(separator: ", ")
        print("  \(String(items.count).padding(toLength: 4, withPad: " ", startingAt: 0)) \(pair)   [\(apps)]")
    }
}

opts.command == "watch" ? watch() : report()

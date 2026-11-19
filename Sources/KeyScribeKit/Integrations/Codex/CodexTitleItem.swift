import Foundation
import TOMLKit

public enum CodexTitleItem {
    public static let item = "thread-id"
    public static let defaultItems = ["spinner", "project"]
    public static let table = "tui"
    public static let key = "terminal_title"

    public enum State: Equatable, Sendable {
        case present, missing, unreadable, unsupported
    }

    public enum Record: Codable, Equatable, Sendable {
        case createdKey(createdTable: Bool, addedLineBreak: Bool)
        case appended
        case alreadyPresent
    }

    public static func keeping(_ earlier: Record, over added: Record) -> Record {
        if case .createdKey = earlier, added == .appended { return earlier }
        return added
    }

    static var createdLine: String {
        "\(key) = [" + (defaultItems + [item]).map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }

    private static let byteOrderMark = "\u{FEFF}"

    private static func withoutMark(_ text: String?) -> (mark: String, body: String?) {
        guard let text, text.hasPrefix(byteOrderMark) else { return ("", text) }
        return (byteOrderMark, String(text.dropFirst()))
    }

    public static func inspect(_ text: String?) -> State {
        switch read(withoutMark(text).body ?? "") {
        case .failed(let state): return state
        case .read(let reading):
            if case .array(_, let values, _) = reading.shape, values.contains(where: { $0 as? String == item }) { return .present }
            return .missing
        }
    }

    public static func adding(to text: String?) -> (text: String, record: Record)? {
        let (mark, body) = withoutMark(text)
        return addingUnmarked(to: body).map { (mark + $0.text, $0.record) }
    }

    private static func addingUnmarked(to text: String?) -> (text: String, record: Record)? {
        let original = text ?? ""
        guard case .read(let reading) = read(original) else { return nil }
        let bytes = reading.scan.bytes
        let edits: [Edit]
        let record: Record
        let expected: [Any]
        switch reading.shape {
        case .noTable:
            let addedLineBreak = bytes.last.map { $0 != newline } ?? false
            let end = lineEnding(of: bytes)
            let separator = bytes.isEmpty ? "" : addedLineBreak ? end + end : end
            edits = [Edit(at: bytes.count, insert: separator + "[\(table)]" + end + createdLine + end)]
            record = .createdKey(createdTable: true, addedLineBreak: addedLineBreak)
            expected = defaultItems + [item]
        case .tableWithoutKey(let header):
            if header.lineEnd > header.lineStart, bytes[header.lineEnd - 1] == newline {
                edits = [Edit(at: header.lineEnd, insert: createdLine + terminator(endingAt: header.lineEnd - 1, in: bytes))]
            } else {
                edits = [Edit(at: header.lineEnd, insert: lineEnding(of: bytes) + createdLine)]
            }
            record = .createdKey(createdTable: false, addedLineBreak: false)
            expected = defaultItems + [item]
        case .array(let entry, let values, let layout):
            if values.contains(where: { $0 as? String == item }) { return (original, .alreadyPresent) }
            guard let insertion = appending(to: layout, entry: entry, in: bytes) else { return nil }
            edits = insertion
            record = .appended
            expected = values + [item]
        }
        let changed = apply(edits, to: bytes)
        guard verify(changed, against: reading.json, expecting: expected) else { return nil }
        return (changed, record)
    }

    public static func removing(from text: String?, record: Record) -> String? {
        let (mark, body) = withoutMark(text)
        return removingUnmarked(from: body, record: record).map { mark + $0 }
    }

    private static func removingUnmarked(from text: String?, record: Record) -> String? {
        let original = text ?? ""
        if record == .alreadyPresent { return original }
        guard case .read(let reading) = read(original) else { return nil }
        guard case .array(let entry, let values, let layout) = reading.shape, let last = values.lastIndex(where: { $0 as? String == item })
        else { return original }
        let bytes = reading.scan.bytes
        var edits: [Edit]
        var expected: [Any]? = values.enumerated().filter { $0.offset != last }.map(\.element)
        if case .createdKey(let createdTable, let addedLineBreak) = record, isOurLine(entry, values: values, in: bytes) {
            edits = [lineRemoval(entry, in: bytes)]
            expected = nil
            if createdTable, let header = reading.scan.header, onlyOurs(entry, header: header, reading: reading) {
                edits.append(headerRemoval(header, entry: entry, addedLineBreak: addedLineBreak, in: bytes))
            }
        } else {
            guard let removal = elementRemoval(layout, in: bytes) else { return nil }
            edits = removal
        }
        let changed = apply(edits, to: bytes)
        guard verify(changed, against: reading.json, expecting: expected) else { return nil }
        return changed
    }

    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    private struct Edit {
        var start: Int
        var end: Int
        var insert: String

        init(at position: Int, insert: String) {
            start = position
            end = position
            self.insert = insert
        }

        init(removing range: Range<Int>) {
            start = range.lowerBound
            end = range.upperBound
            insert = ""
        }
    }

    private static func apply(_ edits: [Edit], to bytes: [UInt8]) -> String {
        var changed = bytes
        let ordered = edits.enumerated().sorted { ($0.element.start, $0.offset) > ($1.element.start, $1.offset) }
        for edit in ordered.map(\.element) {
            changed.replaceSubrange(edit.start..<edit.end, with: Array(edit.insert.utf8))
        }
        return String(decoding: changed, as: UTF8.self)
    }

    private static func lineEnding(of bytes: [UInt8]) -> String {
        bytes.firstIndex(of: newline).map { terminator(endingAt: $0, in: bytes) } ?? "\n"
    }

    private static func terminator(endingAt newlineIndex: Int, in bytes: [UInt8]) -> String {
        newlineIndex > 0 && bytes[newlineIndex - 1] == carriageReturn ? "\r\n" : "\n"
    }

    private enum Shape {
        case noTable
        case tableWithoutKey(CodexTOMLScan.Header)
        case array(CodexTOMLScan.Entry, values: [Any], layout: CodexTOMLScan.ArrayLayout)
    }

    private struct Reading {
        var scan: CodexTOMLScan
        var json: [String: Any]
        var shape: Shape
    }

    private enum Outcome {
        case read(Reading)
        case failed(State)
    }

    private static func json(_ text: String) -> [String: Any]? {
        guard let document = try? TOMLTable(string: text) else { return nil }
        return CodexJSON.object(Data(document.convert(to: .json).utf8))
    }

    private static func read(_ text: String) -> Outcome {
        guard (try? TOMLTable(string: text)) != nil else { return .failed(.unreadable) }
        guard let json = json(text), let scan = CodexTOMLScan(Array(text.utf8)) else { return .failed(.unsupported) }
        guard let tui = json[table] else {
            return scan.header == nil ? .read(Reading(scan: scan, json: json, shape: .noTable)) : .failed(.unsupported)
        }
        guard tui is [String: Any], let section = scan.tuiSection,
              !scan.entries.contains(where: { $0.section == nil && $0.path.first == table })
        else { return .failed(.unsupported) }
        let header = scan.headers[section]
        let entries = scan.entries.filter { $0.section == section && $0.path.first == key }
        guard let title = (tui as? [String: Any])?[key] else {
            return entries.isEmpty ? .read(Reading(scan: scan, json: json, shape: .tableWithoutKey(header))) : .failed(.unsupported)
        }
        guard let values = title as? [Any], entries.count == 1, let entry = entries.first, entry.path == [key], let layout = scan.layout(of: entry)
        else { return .failed(.unsupported) }
        return .read(Reading(scan: scan, json: json, shape: .array(entry, values: values, layout: layout)))
    }

    private static func verify(_ changed: String, against original: [String: Any], expecting expected: [Any]?) -> Bool {
        guard let after = json(changed), CodexTOMLScan(Array(changed.utf8)) != nil else { return false }
        let found = (after[table] as? [String: Any])?[key]
        if let expected {
            guard let found = found as? [Any], (found as NSArray).isEqual(to: expected) else { return false }
        } else if found != nil {
            return false
        }
        return (withoutKey(after) as NSDictionary).isEqual(to: withoutKey(original))
    }

    private static func withoutKey(_ document: [String: Any]) -> [String: Any] {
        var document = document
        guard var tui = document[table] as? [String: Any] else { return document }
        tui[key] = nil
        document[table] = tui.isEmpty ? nil : tui
        return document
    }

    private static func indent(before position: Int, layout: CodexTOMLScan.ArrayLayout, in bytes: [UInt8]) -> String {
        var lineStart = position
        while lineStart > 0, bytes[lineStart - 1] != newline { lineStart -= 1 }
        var end = lineStart
        while end < bytes.count, bytes[end] == UInt8(ascii: " ") || bytes[end] == UInt8(ascii: "\t") { end += 1 }
        let leading = String(decoding: bytes[lineStart..<end], as: UTF8.self)
        return lineStart <= layout.open.lowerBound ? leading + "    " : leading
    }

    private static func firstNewline(in range: Range<Int>, of bytes: [UInt8]) -> Int? {
        range.first { bytes[$0] == newline }
    }

    private static func appending(to layout: CodexTOMLScan.ArrayLayout, entry: CodexTOMLScan.Entry, in bytes: [UInt8]) -> [Edit]? {
        let quoted = "\"\(item)\""
        guard let lastIndex = layout.items.lastIndex(where: { $0.isElement }) else {
            return [Edit(at: layout.open.upperBound, insert: quoted)]
        }
        let last = layout.items[lastIndex].range
        let comma = layout.items[(lastIndex + 1)...].first { !$0.isElement }?.range
        let indentation = indent(before: last.lowerBound, layout: layout, in: bytes)
        if let comma {
            guard let lineBreak = firstNewline(in: comma.upperBound..<layout.close.lowerBound, of: bytes) else {
                return [Edit(at: comma.upperBound, insert: " \(quoted),")]
            }
            return [Edit(at: lineBreak + 1, insert: indentation + quoted + "," + terminator(endingAt: lineBreak, in: bytes))]
        }
        guard let lineBreak = firstNewline(in: last.upperBound..<layout.close.lowerBound, of: bytes) else {
            return [Edit(at: last.upperBound, insert: ", \(quoted)")]
        }
        let term = terminator(endingAt: lineBreak, in: bytes)
        let lineEnd = term == "\r\n" ? lineBreak - 1 : lineBreak
        return [Edit(at: last.upperBound, insert: ","), Edit(at: lineEnd, insert: term + indentation + quoted)]
    }

    private static func elementRemoval(_ layout: CodexTOMLScan.ArrayLayout, in bytes: [UInt8]) -> [Edit]? {
        guard let ours = layout.items.lastIndex(where: { $0.isElement && isOurs($0.range, in: bytes) }) else { return nil }
        let element = layout.items[ours].range
        let before = ours > 0 ? layout.items[ours - 1] : nil
        let after = ours + 1 < layout.items.count ? layout.items[ours + 1] : nil
        if let after, !after.isElement {
            if let line = ownLine(element, comma: after.range, in: bytes) { return [Edit(removing: line)] }
            guard let before else {
                var end = after.range.upperBound
                while end < layout.close.lowerBound, isBlank(bytes[end]) { end += 1 }
                return [Edit(removing: element.lowerBound..<end)]
            }
            return [Edit(removing: before.range.upperBound..<after.range.upperBound)]
        }
        guard let before, !before.isElement else { return [Edit(removing: element)] }
        let gap = before.range.upperBound..<element.lowerBound
        guard let lineBreak = gap.last(where: { bytes[$0] == newline }) else {
            return [Edit(removing: before.range.lowerBound..<element.upperBound)]
        }
        let start = lineBreak > gap.lowerBound && bytes[lineBreak - 1] == carriageReturn ? lineBreak - 1 : lineBreak
        return [Edit(removing: start..<element.upperBound), Edit(removing: before.range)]
    }

    private static func isOurs(_ range: Range<Int>, in bytes: [UInt8]) -> Bool {
        let raw = String(decoding: bytes[range], as: UTF8.self)
        return raw == "\"\(item)\"" || raw == "'\(item)'"
    }

    private static func isBlank(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
    }

    private static func ownLine(_ element: Range<Int>, comma: Range<Int>, in bytes: [UInt8]) -> Range<Int>? {
        var start = element.lowerBound
        while start > 0, isBlank(bytes[start - 1]) { start -= 1 }
        guard start == 0 || bytes[start - 1] == newline, bytes[element.upperBound..<comma.lowerBound].allSatisfy(isBlank) else { return nil }
        var end = comma.upperBound
        while end < bytes.count, isBlank(bytes[end]) || bytes[end] == carriageReturn { end += 1 }
        guard end < bytes.count, bytes[end] == newline else { return nil }
        return start..<(end + 1)
    }

    private static func isOurLine(_ entry: CodexTOMLScan.Entry, values: [Any], in bytes: [UInt8]) -> Bool {
        let line = String(decoding: bytes[entry.lineStart..<entry.lineEnd], as: UTF8.self)
        return (values as NSArray).isEqual(to: defaultItems + [item]) && [createdLine, createdLine + "\n", createdLine + "\r\n"].contains(line)
    }

    private static func lineRemoval(_ entry: CodexTOMLScan.Entry, in bytes: [UInt8]) -> Edit {
        if entry.lineEnd > entry.lineStart, bytes[entry.lineEnd - 1] == newline { return Edit(removing: entry.lineStart..<entry.lineEnd) }
        return Edit(removing: (entry.lineStart - terminatorLength(before: entry.lineStart, in: bytes))..<entry.lineEnd)
    }

    private static func onlyOurs(_ entry: CodexTOMLScan.Entry, header: CodexTOMLScan.Header, reading: Reading) -> Bool {
        guard let tui = reading.json[table] as? [String: Any], tui.count == 1 else { return false }
        let scan = reading.scan
        let next = scan.headers.first { $0.lineStart >= header.lineEnd }?.lineStart ?? scan.bytes.count
        let rest = (header.lineEnd..<next).filter { !(entry.lineStart..<entry.lineEnd).contains($0) }
        return rest.allSatisfy { isBlank(scan.bytes[$0]) || scan.bytes[$0] == newline || scan.bytes[$0] == carriageReturn }
    }

    private static func headerRemoval(_ header: CodexTOMLScan.Header, entry: CodexTOMLScan.Entry, addedLineBreak: Bool, in bytes: [UInt8]) -> Edit {
        var start = header.lineStart
        let blank = terminatorLength(before: start, in: bytes)
        if blank > 0, terminatorLength(before: start - blank, in: bytes) > 0 { start -= blank }
        if addedLineBreak, entry.lineEnd == bytes.count { start -= terminatorLength(before: start, in: bytes) }
        return Edit(removing: start..<header.lineEnd)
    }

    private static func terminatorLength(before position: Int, in bytes: [UInt8]) -> Int {
        guard position >= 1, bytes[position - 1] == newline else { return 0 }
        return position >= 2 && bytes[position - 2] == carriageReturn ? 2 : 1
    }
}

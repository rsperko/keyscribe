import Foundation
import KeyScribeKit
import Testing
@testable import KeyScribeApp

struct CodexHookScriptTests {
    final class Bridge {
        let root: URL
        let temporary: URL
        let script: URL
        private let listener: Int32

        init() throws {
            root = URL(fileURLWithPath: "/tmp/ksh-\(UUID().uuidString.prefix(8))", isDirectory: true)
            temporary = root.appendingPathComponent("tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            try Data("secret".utf8).write(to: root.appendingPathComponent("token"))
            let source = try #require(CodexConnector.script)
            let filled = source.replacingOccurrences(of: "__AGENTS_DIR__", with: ShellWord.quoted(root.path))
                .replacingOccurrences(of: "__APP_NAME__", with: "App")
            script = root.appendingPathComponent("keyscribe-codex")
            try Data(filled.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = root.appendingPathComponent("bridge.sock").path
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                for (index, byte) in path.utf8.enumerated() where index < bytes.count - 1 { bytes[index] = byte }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            try #require(bound == 0)
            try #require(listen(listener, 8) == 0)
        }

        deinit {
            close(listener)
            try? FileManager.default.removeItem(at: root)
        }

        func hook(_ body: String) throws -> TimeInterval {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, "hook", "inst-1"]
            process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": temporary.path]
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            let began = Date()
            try process.run()
            input.fileHandleForWriting.write(Data(body.utf8))
            try input.fileHandleForWriting.close()
            _ = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Date().timeIntervalSince(began)
        }
    }

    @Test func aHookWaitsOnlyBrieflyWhenTheAppAcceptsButNeverAnswers() throws {
        let bridge = try Bridge()
        let took = try bridge.hook(#"{"hook_event_name":"Stop","session_id":"s1","turn_id":"t1"}"#)
        #expect(took < 1.5)
    }

    @Test func aHookThatCutsALongPayloadLeavesNoTemporaryFilesBehind() throws {
        let bridge = try Bridge()
        let long = String(repeating: "word ", count: 60_000)
        _ = try bridge.hook(#"{"hook_event_name":"Stop","session_id":"s1","turn_id":"t1","last_assistant_message":"\#(long)"}"#)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bridge.temporary.path).isEmpty)
    }
}

import Carbon
import Foundation
import KeyScribeKit
import OSAKit

enum PinnedAppleScript {
    enum Reply {
        case value(NSAppleEventDescriptor)
        case refused
        case gone
        case failed(Int)
    }

    private static let notPermitted = -1743
    static let timedOut = -1712

    private final class PinnedProcess {
        let pid: pid_t
        let isCurrent: () -> Bool
        var gone = false
        init(pid: pid_t, isCurrent: @escaping () -> Bool) {
            self.pid = pid
            self.isCurrent = isCurrent
        }
    }

    // A command abandoned mid-script sends nothing more, so a slow app cannot be acted on after the user moved on.
    private static let sendToProcess: OSASendUPP = { event, reply, mode, _, timeout, _, _, refCon in
        guard let event, let reply, let refCon else { return OSErr(paramErr) }
        let process = Unmanaged<PinnedProcess>.fromOpaque(refCon).takeUnretainedValue()
        guard process.isCurrent() else { return OSErr(userCanceledErr) }
        var addressed = AppleEvent()
        var status = AEDuplicateDesc(event, &addressed)
        guard status == noErr else { return status }
        defer { AEDisposeDesc(&addressed) }
        var pid = process.pid
        var address = AEAddressDesc()
        status = AECreateDesc(DescType(typeKernelProcessID), &pid, MemoryLayout<pid_t>.size, &address)
        guard status == noErr else { return status }
        defer { AEDisposeDesc(&address) }
        status = AEPutAttributeDesc(&addressed, AEKeyword(keyAddressAttr), &address)
        guard status == noErr else { return status }
        let sent = AESendMessage(&addressed, reply, mode, Int(timeout))
        if sent == procNotFound || sent == connectionInvalid { process.gone = true }
        return OSErr(truncatingIfNeeded: sent)
    }

    static func run(_ source: String, pid: Int32, isCurrent: () -> Bool) -> Reply {
        guard let language = OSALanguage(forName: "AppleScript") else { return .failed(0) }
        let instance = OSALanguageInstance(language: language)
        return withoutActuallyEscaping(isCurrent) { isCurrent in
            let process = PinnedProcess(pid: pid, isCurrent: isCurrent)
            return withExtendedLifetime(process) {
                guard OSASetSendProc(instance.componentInstance, sendToProcess, Unmanaged.passUnretained(process).toOpaque()) == noErr
                else { return .failed(0) }
                let script = OSAScript(source: source, from: nil, languageInstance: instance, using: [])
                var error: NSDictionary?
                let result = script.executeAndReturnError(&error)
                if process.gone { return .gone }
                if let result, error == nil { return .value(result) }
                let code = (error?[OSAScriptErrorNumber] as? Int) ?? 0
                return code == notPermitted ? .refused : .failed(code)
            }
        }
    }

    // AppleScript starts any app a script tells that is not running, so the script tells only itself and
    // `run(_:pid:)` sends each event to the target process; a quit app fails instead of restarting.
    // Scripted apps here have a static dictionary, so reading their terms does not start one either.
    static func pinned(to bundleId: String, timeout: Int, _ statements: String) -> String {
        """
        with timeout of \(timeout) seconds
        using terms from application id \(literal(bundleId))
        tell current application
        \(statements)
        end tell
        end using terms from
        end timeout
        """
    }

    static func literal(_ value: String) -> String { AppleScriptText.literal(value) }
}

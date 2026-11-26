import CoreGraphics
import Foundation
import os

private let tapLog = Logger(subsystem: "com.keyscribe.app", category: "hotkey")

final class EventTapThread: @unchecked Sendable {
    typealias Handler = @Sendable (CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    private let name: String
    fileprivate let handler: Handler
    private var port: CFMachPort?

    init(name: String, handler: @escaping Handler) {
        self.name = name
        self.handler = handler
    }

    var userInfo: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    func start(port: CFMachPort) {
        CGEvent.tapEnable(tap: port, enable: false)
        self.port = port
        let thread = Thread { self.run() }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func run() {
        guard let port else { return }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopRun()
    }

    fileprivate func reEnable(reason: CGEventType) {
        guard let port else { return }
        tapLog.error("\(self.name, privacy: .public) disabled (type=\(reason.rawValue, privacy: .public)); re-enabling")
        CGEvent.tapEnable(tap: port, enable: true)
    }
}

func eventTapThreadCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let thread = Unmanaged<EventTapThread>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        thread.reEnable(reason: type)
        return Unmanaged.passUnretained(event)
    }
    return thread.handler(type, event)
}

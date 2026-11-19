import Foundation
import KeyScribeKit

struct OpencodeReply: Equatable, Sendable {
    var status: Int
    var body: Data

    var ok: Bool { (200..<300).contains(status) }
}

protocol OpencodeStream: AnyObject, Sendable {
    func cancel()
}

protocol OpencodeTransport: Sendable {
    func call(_ method: String, _ path: String, body: Data?, to service: OpencodeService, timeout: TimeInterval) async -> OpencodeReply?
    func stream(
        from service: OpencodeService, onEvent: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void
    ) -> any OpencodeStream
}

struct OpencodeHTTP: OpencodeTransport {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = .infinity
        return URLSession(configuration: configuration)
    }()

    static func request(_ method: String, _ path: String, body: Data?, to service: OpencodeService, timeout: TimeInterval) -> URLRequest? {
        guard let url = URL(string: path, relativeTo: service.url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let authorization = service.authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func call(_ method: String, _ path: String, body: Data?, to service: OpencodeService, timeout: TimeInterval) async -> OpencodeReply? {
        guard let request = Self.request(method, path, body: body, to: service, timeout: timeout),
              let (data, response) = try? await Self.session.data(for: request), let http = response as? HTTPURLResponse
        else { return nil }
        return OpencodeReply(status: http.statusCode, body: data)
    }

    func stream(
        from service: OpencodeService, onEvent: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void
    ) -> any OpencodeStream {
        let task = Task.detached {
            defer { onClose() }
            guard var request = Self.request("GET", "/api/event", body: nil, to: service, timeout: OpencodeHost.streamSilence) else { return }
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            guard let (bytes, response) = try? await Self.session.bytes(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            do {
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    guard line.hasPrefix("data:") else { continue }
                    onEvent(Data(line.dropFirst(5).utf8))
                }
            } catch {
                return
            }
        }
        return TaskStream(task: task)
    }

    private final class TaskStream: OpencodeStream {
        let task: Task<Void, Never>

        init(task: Task<Void, Never>) { self.task = task }

        func cancel() { task.cancel() }
    }
}

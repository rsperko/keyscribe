import CryptoKit
import Foundation
import KeyScribeKit
import Security

enum AgentBridgeToken {
    static func loadOrCreate(in dir: URL) throws -> String {
        let url = dir.appendingPathComponent("token")
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), existing.count >= 32 {
            return existing
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        chmod(dir.path, 0o700)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        guard FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return token
    }
}

struct ClaudeConnectorInstaller {
    struct InstallError: Error, Equatable {
        var command: [String]
        var status: Int32
        var output: String
    }

    let agentsDir: URL
    let pluginName: String
    let claude: String
    let socketPath: String
    let tokenPath: String
    let run: ([String]) -> (Int32, String)

    var marketplaceName: String { "\(pluginName)-local" }
    var marketplaceDir: URL { agentsDir.appendingPathComponent("claude-connector", isDirectory: true) }
    private var pluginId: String { "\(pluginName)@\(marketplaceName)" }

    static func pluginName(for variant: AppVariant) -> String {
        switch variant {
        case .production: return "keyscribe"
        case .dev: return "keyscribe-dev"
        case .custom(let displayName, _):
            let slug = displayName.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            return String(slug).split(separator: "-").joined(separator: "-")
        }
    }

    func install() throws {
        try writeFiles()
        try claudeCommand(["plugin", "marketplace", "add", marketplaceDir.path])
        try claudeCommand(["plugin", "install", pluginId, "--scope", "user"])
    }

    func update() throws {
        try writeFiles()
        try claudeCommand(["plugin", "marketplace", "update", marketplaceName])
        try claudeCommand(["plugin", "update", pluginId])
    }

    func uninstall() throws {
        try claudeCommand(["plugin", "uninstall", pluginId])
        try claudeCommand(["plugin", "marketplace", "remove", marketplaceName])
        try? FileManager.default.removeItem(at: marketplaceDir)
    }

    private func claudeCommand(_ args: [String]) throws {
        let argv = [claude] + args
        let (status, output) = run(argv)
        guard status == 0 else { throw InstallError(command: argv, status: status, output: output) }
    }

    private func writeFiles() throws {
        let plugin = marketplaceDir.appendingPathComponent(pluginName, isDirectory: true)
        let files: [(URL, String)] = [
            (marketplaceDir.appendingPathComponent(".claude-plugin/marketplace.json"), ClaudeConnectorFiles.marketplaceJSON(name: marketplaceName, plugin: pluginName)),
            (plugin.appendingPathComponent(".claude-plugin/plugin.json"), ClaudeConnectorFiles.pluginJSON(name: pluginName)),
            (plugin.appendingPathComponent("hooks/hooks.json"), ClaudeConnectorFiles.hooksJSON),
            (plugin.appendingPathComponent("hooks/register.js"), ClaudeConnectorFiles.registerJS),
            (plugin.appendingPathComponent("keyscribe.json"), ClaudeConnectorFiles.configJSON(socketPath: socketPath, tokenPath: tokenPath)),
        ]
        for (url, text) in files {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        }
    }
}

enum ClaudeConnectorFiles {
    static let version = version(for: registerJS)

    static func version(for script: String) -> String {
        "0.1.0-" + SHA256.hash(data: Data(script.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func marketplaceJSON(name: String, plugin: String) -> String {
        json([
            "name": name,
            "description": "\(Branding.appName) voice connector for Claude Code",
            "owner": ["name": Branding.appName],
            "plugins": [["name": plugin, "source": "./\(plugin)", "description": "Lets \(Branding.appName) send what you say to this session."]],
        ])
    }

    static func pluginJSON(name: String) -> String {
        json([
            "name": name,
            "version": version,
            "description": "Lets \(Branding.appName) send what you say to this Claude Code session.",
            "author": ["name": Branding.appName],
        ])
    }

    static let hooksJSON = json(["description": "Voice connector", "modules": ["./register.js"]])

    static func configJSON(socketPath: String, tokenPath: String) -> String {
        json(["protocol": AgentBridgeCodec.protocolVersion, "socketPath": socketPath, "tokenPath": tokenPath])
    }

    static let registerJS = #"""
    const instance = Math.random().toString(36).slice(2, 10)
    let config = null
    let token = ''
    let helloSession = null
    let currentTurn = null
    let pendingButton = null
    let looping = false
    let titleSession = null
    let lastTitle = null

    async function loadConfig($) {
      config = JSON.parse(await $.fs.read($.plugin.root + '/keyscribe.json'))
      token = (await $.fs.read(config.tokenPath)).trim()
    }

    async function post($, path, body) {
      return $.http.fetch('http://keyscribe' + path, {
        method: 'POST',
        body: JSON.stringify(body),
        socketPath: config.socketPath,
        headers: { authorization: 'Bearer ' + token },
      })
    }

    async function emit($, event) {
      try {
        const res = await post($, '/event', event)
        return res.ok
      } catch (err) {
        $.ui.log('bridge unreachable: ' + String(err), { to: 'debug' })
        return false
      }
    }

    async function sayHello($, session) {
      const ok = await emit($, {
        op: 'hello', protocol: config.protocol, agent: 'claude', agentVersion: '', instance, session, pid: 0,
        features: ['focus', 'label'], title: (titleSession === session && lastTitle) || undefined,
      })
      helloSession = ok ? session : null
      return ok
    }

    function asText(text) {
      return text.startsWith('/') ? '​' + text : text
    }

    async function submit($, id, text) {
      let result
      try {
        result = await $.prompt.submit({ text: asText(text), asUser: true })
      } catch (err) {
        return emit($, { op: 'refused', request: id, reason: String(err && err.message || err) })
      }
      if (result && result.drop) return emit($, { op: 'refused', request: id, reason: result.drop })
      return emit($, { op: 'submitted', request: id, turn: currentTurn || '' })
    }

    async function abort($, id, expectedTurn) {
      if (!currentTurn || currentTurn !== expectedTurn) return emit($, { op: 'refused', request: id, reason: 'turnChanged' })
      try {
        await $.turn.abort({ turnId: currentTurn })
        return emit($, { op: 'ack', request: id })
      } catch (err) {
        return emit($, { op: 'refused', request: id, reason: 'notRunning' })
      }
    }

    async function fill($, id, text) {
      const box = await $.prompt.read()
      if (box.text.trim()) return emit($, { op: 'refused', request: id, reason: 'draft' })
      const result = await $.prompt.fill({ text, mode: 'replace' })
      return emit($, result.isFilled ? { op: 'ack', request: id } : { op: 'refused', request: id, reason: 'notFilled' })
    }

    async function noteTitle($, e) {
      if (!('session_title' in e)) return
      const session = await $.session.id()
      const next = e.session_title || null
      if (session !== titleSession) {
        titleSession = session
        lastTitle = null
      }
      if (next === lastTitle) return
      lastTitle = next
      if (config && helloSession === session) await emit($, { op: 'title', session, text: next || '' })
    }

    async function focus($, id, expiresAt) {
      const surface = await $.env.get("CMUX_SURFACE_ID")
      if (!surface) return emit($, { op: 'refused', request: id, reason: 'notInCmux' })
      if (!(Date.now() < expiresAt)) return emit($, { op: 'refused', request: id, reason: 'expired' })
      try {
        const result = await $.process.run(['/usr/bin/env', 'cmux', 'focus-panel', '--panel', surface], { timeoutMs: 3000 })
        return emit($, result.exitCode === 0 ? { op: 'focused', request: id } : { op: 'refused', request: id, reason: 'focusFailed' })
      } catch (err) {
        return emit($, { op: 'refused', request: id, reason: 'focusFailed' })
      }
    }

    async function handle($, cmd) {
      const live = await $.session.id()
      if (cmd.expectedSession !== live) return emit($, { op: 'refused', request: cmd.id, reason: 'sessionChanged' })
      if (cmd.op === 'submit') return submit($, cmd.id, cmd.text)
      if (cmd.op === 'abort') return abort($, cmd.id, cmd.expectedTurn)
      if (cmd.op === 'fill') return fill($, cmd.id, cmd.text)
      if (cmd.op === 'focus') return focus($, cmd.id, cmd.expiresAt)
      if (cmd.op === 'offerButton') {
        pendingButton = { id: cmd.id, text: cmd.text, session: cmd.expectedSession }
        $.ui.invalidate('ui.render')
        return
      }
      if (cmd.op === 'status') {
        $.ui.status(cmd.text)
        return
      }
    }

    async function pollLoop($) {
      for (;;) {
        if (!config) {
          try {
            await loadConfig($)
          } catch (err) {
            config = null
            $.ui.log('voice connector waiting for its bridge: ' + String(err), { to: 'debug' })
            await $.clock.sleep(5000)
            continue
          }
        }
        const session = await $.session.id()
        if (session !== helloSession && !(await sayHello($, session))) {
          $.ui.status('')
          await $.clock.sleep(2000)
          continue
        }
        let commands = []
        try {
          const res = await post($, '/poll', { session, instance })
          if (res.status === 409) {
            helloSession = null
            continue
          }
          if (res.ok) {
            commands = JSON.parse(res.text)
          } else {
            await $.clock.sleep(2000)
          }
        } catch (err) {
          helloSession = null
          $.ui.status('')
          await $.clock.sleep(2000)
          continue
        }
        for (const cmd of commands) {
          const key = 'done-' + cmd.id
          if (await $.store.get(key)) {
            await emit($, { op: 'ack', request: cmd.id })
            continue
          }
          await $.store.set(key, Date.now())
          await emit($, { op: 'ack', request: cmd.id })
          void handle($, cmd)
        }
      }
    }

    async function announceReplacement($, ended) {
      for (let i = 0; i < 50; i++) {
        await $.clock.sleep(100)
        const session = await $.session.id()
        if (session !== ended) return sayHello($, session)
      }
    }

    async function pressButton($) {
      const pending = pendingButton
      pendingButton = null
      $.ui.invalidate('ui.render')
      if (!pending) return
      if (pending.session !== await $.session.id()) return emit($, { op: 'refused', request: pending.id, reason: 'sessionChanged' })
      await submit($, pending.id, pending.text)
    }

    export function register(on) {
      on('session.start', async ($, e, next) => {
        const started = await next(e)
        if (!looping) {
          looping = true
          void pollLoop($)
        }
        return started
      })

      on('session.end', async ($, e, next) => {
        const ended = await $.session.id()
        const result = await next(e)
        if (config) void announceReplacement($, ended)
        return result
      })

      on('classic.SessionStart', async ($, e, next) => {
        const result = await next(e)
        void noteTitle($, e)
        return result
      })

      on('classic.UserPromptSubmit', async ($, e, next) => {
        const result = await next(e)
        void noteTitle($, e)
        return result
      })

      on('prompt.submit', async ($, e, next) => {
        const typed = e.origin && (e.origin.kind === 'composer' || e.origin.kind === 'bridge')
        if (config && typed) await emit($, { op: 'typed', session: await $.session.id() })
        return next(e)
      })

      on('turn.start', async ($, e, next) => {
        if (e.agentId === undefined) {
          currentTurn = e.turnId
          if (config) await emit($, { op: 'turnStarted', session: await $.session.id(), turn: e.turnId })
        }
        return next(e)
      })

      on('turn.complete', async ($, e, next) => {
        const result = await next(e)
        if (e.agentId === undefined && currentTurn === e.turnId) currentTurn = null
        if (config && e.agentId === undefined) {
          await emit($, { op: 'turnComplete', session: await $.session.id(), reason: e.reason, answer: String(e.answer || '').slice(0, 4000) })
        }
        return result
      })

      on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
        if (!pendingButton || pendingButton.session !== await $.session.id()) return next(e)
        const { Box, Button } = $.ui.resolve(e)
        return Box({ children: [Button({ key: 'keyscribe-send', label: 'Send dictated correction', variant: 'primary', onPress: async () => { await pressButton($) } })] })
      })
    }
    """#
}

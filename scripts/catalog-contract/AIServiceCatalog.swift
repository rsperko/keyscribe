import Foundation

// The stand-in lineup scripts/check-catalog-contract.sh swaps in. It takes every freedom the swap contract
// gives a downstream at once: no first-party providers, Custom left out of the picker, a policy that refuses
// everything but one endpoint, and no API-key sign-in anywhere. That endpoint is offered twice, differing only
// in sign-in: a token-command-only default and a no-auth-only alternative.
public enum AIServiceCatalog {
    public static let proxy = ConnectionPreset(
        id: "proxy", name: "Proxy", provider: .openaiCompatible,
        baseURL: "https://proxy.example.com/v1", defaultModel: "standard-model",
        allowedAuthMethods: [.tokenCommand], defaultAuthMethod: .tokenCommand,
        defaultTokenCommand: "proxy-cli token")

    public static let openProxy = ConnectionPreset(
        id: "proxy-open", name: "Proxy (No Auth)", provider: .openaiCompatible,
        baseURL: "https://proxy.example.com/v1", defaultModel: "standard-model",
        allowedAuthMethods: [.none], defaultAuthMethod: .none)

    public static let custom = ConnectionPreset(
        id: "custom", name: "Custom AI", provider: .openaiCompatible,
        baseURL: nil, defaultModel: "", keysURL: nil,
        allowedAuthMethods: [.none, .tokenCommand], defaultAuthMethod: .tokenCommand,
        pickerLabelOverride: "Custom (OpenAI-compatible)")

    public static let all: [ConnectionPreset] = [proxy, openProxy]

    public static let defaultPreset = proxy

    public static func permits(_ connection: Connection) -> Bool {
        connection.provider == .openaiCompatible
            && ConnectionPreset.normalize(connection.baseUrl) == ConnectionPreset.normalize(proxy.baseURL)
    }
}

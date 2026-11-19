import KeyScribeKit
import Testing

struct CodexInstallTests {
    @Test func aCopyInsideAnAppBundleIsNotTheCommandLineCodexEvenWhenItIsCalledCodex() {
        #expect(!CodexInstall.isCommandLine(resolved: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"))
        #expect(!CodexInstall.isCommandLine(resolved: "/Users/me/Applications/ChatGPT.app/Contents/MacOS/codex"))
        #expect(!CodexInstall.isCommandLine(resolved: "/Applications/Other.APP/Contents/codex"))
    }

    @Test func homebrewAndPackageManagerCopiesAreTheCommandLineCodex() {
        #expect(CodexInstall.isCommandLine(resolved: "/opt/homebrew/Caskroom/codex/0.170.0/codex-aarch64-apple-darwin"))
        #expect(CodexInstall.isCommandLine(resolved: "/Users/me/.local/share/npm/lib/node_modules/@openai/codex/bin/codex.js"))
        #expect(CodexInstall.isCommandLine(resolved: "/Users/me/my.application/codex"))
    }
}

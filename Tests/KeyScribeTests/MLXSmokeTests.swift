import Testing
@testable import KeyScribeApp

struct MLXSmokeTests {
    @Test func withoutAMetalDeviceTheSmokeFailsBeforeTouchingMLX() {
        #expect(MLXSmoke.run(hasMetalDevice: false) == 1)
    }
}

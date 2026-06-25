import Foundation
import ObjCSupport

// Run a block, surfacing any raised NSException as a thrown Swift error (Swift can't catch them natively).
enum ObjCException {
    static func catching(_ block: () -> Void) throws {
        var error: NSError?
        if !KSRunCatchingNSException(block, &error) {
            throw error ?? NSError(domain: "com.keyscribe.ObjCException", code: 0)
        }
    }
}

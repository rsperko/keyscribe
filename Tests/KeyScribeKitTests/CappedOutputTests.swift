import Foundation
import Testing
@testable import KeyScribeKit

struct CappedOutputTests {
    @Test func outputUnderTheLimitIsKeptWhole() {
        var output = CappedOutput(limit: 10)
        output.append(Data("abc".utf8))
        output.append(Data("def".utf8))
        #expect(output.text == "abcdef")
        #expect(!output.truncated)
    }

    @Test func outputPastTheLimitKeepsItsStartAndSaysItWasCut() {
        var output = CappedOutput(limit: 5)
        output.append(Data("abc".utf8))
        output.append(Data("defgh".utf8))
        output.append(Data("ijk".utf8))
        #expect(output.text == "abcde")
        #expect(output.truncated)
    }

    @Test func outputExactlyAtTheLimitIsNotCut() {
        var output = CappedOutput(limit: 3)
        output.append(Data("abc".utf8))
        #expect(output.text == "abc")
        #expect(!output.truncated)
    }

    @Test func aCharacterSplitAtTheLimitDoesNotBreakTheText() {
        var output = CappedOutput(limit: 2)
        output.append(Data("aé".utf8))
        #expect(output.text.hasPrefix("a"))
        #expect(output.truncated)
    }
}

import Testing
@testable import KeyScribeKit

struct ChordMatchingTests {
    private func desc(_ s: String) -> KeyDescriptor { try! KeyDescriptor(parsing: s) }
    private let lKey = 37  // keyCode for "l"
    private let aKey = 0   // keyCode for "a"

    @Test func exactModifiersMatch() {
        #expect(desc("option+l").matchesChord(keyCode: lKey, activeModifiers: [.option]))
    }

    // Regression (reported): option+l must NOT fire when hyper+l is pressed.
    @Test func optionChordDoesNotMatchUnderHyper() {
        #expect(!desc("option+l").matchesChord(
            keyCode: lKey, activeModifiers: [.control, .option, .shift, .command]))
    }

    @Test func anyExtraModifierBreaksTheMatch() {
        #expect(!desc("option+l").matchesChord(keyCode: lKey, activeModifiers: [.option, .shift]))
        #expect(!desc("option+l").matchesChord(keyCode: lKey, activeModifiers: [.option, .command]))
    }

    @Test func missingRequiredModifierDoesNotMatch() {
        #expect(!desc("control+option+a").matchesChord(keyCode: aKey, activeModifiers: [.control]))
        #expect(!desc("control+option+a").matchesChord(keyCode: aKey, activeModifiers: []))
    }

    @Test func wrongKeyCodeDoesNotMatch() {
        #expect(!desc("option+l").matchesChord(keyCode: aKey, activeModifiers: [.option]))
    }

    @Test func fullChordMatchesOnlyWithExactlyThoseModifiers() {
        let chord = desc("control+option+shift+command+a")
        #expect(chord.matchesChord(keyCode: aKey, activeModifiers: [.control, .option, .shift, .command]))
        #expect(!chord.matchesChord(keyCode: aKey, activeModifiers: [.control, .option, .shift]))
    }

    @Test func namedDescriptorsAreNotChords() {
        #expect(!desc("fn").matchesChord(keyCode: 63, activeModifiers: []))
        #expect(!desc("right_option").matchesChord(keyCode: 61, activeModifiers: [.option]))
        #expect(!desc("hyper").matchesChord(keyCode: 55, activeModifiers: [.control, .option, .shift, .command]))
    }

    @Test func maskFormMatchesSetForm() {
        #expect(desc("option+l").matchesChord(keyCode: lKey, activeModifierMask: [.option]))
        #expect(!desc("option+l").matchesChord(keyCode: lKey, activeModifierMask: [.option, .shift]))
        #expect(!desc("control+option+a").matchesChord(keyCode: aKey, activeModifierMask: [.control]))
        #expect(desc("control+option+shift+command+a")
            .matchesChord(keyCode: aKey, activeModifierMask: [.control, .option, .shift, .command]))
    }

    @Test func modifierSetRoundTripsFromSet() {
        #expect(ModifierSet([.option, .command]) == [.option, .command])
        #expect(ModifierSet([]) == [])
        #expect(ModifierSet(Set(Modifier.allCases)) == [.control, .option, .shift, .command])
    }
}

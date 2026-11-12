import AppKit
import KeyScribeKit
import Testing
@testable import KeyScribeApp

@MainActor
struct HUDPositionPickerTests {
    typealias Display = HUDPositionPickerController.Display

    static let primary = Display(
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), visibleFrame: CGRect(x: 0, y: 70, width: 1728, height: 1009))
    static let secondary = Display(
        frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055))

    @MainActor
    final class Fixture {
        let hud: HUDController
        let defaults: UserDefaults
        var hudDisplay: Display? = HUDPositionPickerTests.primary
        var displays = [HUDPositionPickerTests.primary, HUDPositionPickerTests.secondary]
        var resolutions = 0
        var selections: [HUDAnchor] = []
        var ordered: [(frame: CGRect, key: Bool)] = []
        private(set) var picker: HUDPositionPickerController!

        init() {
            let defaults = UserDefaults(suiteName: "hud-position-\(UUID().uuidString)")!
            self.defaults = defaults
            let hud = HUDController(defaults: defaults)
            self.hud = hud
            picker = HUDPositionPickerController(
                currentAnchor: { hud.currentAnchor },
                select: { [unowned self] in
                    self.selections.append($0)
                    hud.setAnchor($0)
                },
                hudDisplay: { [unowned self] in
                    self.resolutions += 1
                    return self.hudDisplay
                },
                displays: { [unowned self] in self.displays },
                order: { [unowned self] panel, key in self.ordered.append((panel.frame, key)) })
        }
    }

    @Test func offersEveryAnchorWithTheSavedOneMarked() {
        let fixture = Fixture()
        fixture.hud.setAnchor(.topRight)
        fixture.picker.open()

        #expect(fixture.picker.layout?.targets.map(\.anchor) == HUDAnchor.allCases)
        #expect(fixture.picker.markedAnchor == .topRight)
    }

    @Test(arguments: HUDAnchor.allCases)
    func choosingSavesTheAnchorEverywhereAndCloses(_ anchor: HUDAnchor) {
        let fixture = Fixture()
        fixture.picker.open()
        fixture.picker.choose(anchor)

        #expect(fixture.selections == [anchor])
        #expect(fixture.hud.currentAnchor == anchor)
        #expect(HUDAnchorStore.load(fixture.defaults) == anchor)
        #expect(!fixture.picker.isOpen)

        fixture.picker.open()
        #expect(fixture.picker.markedAnchor == anchor)
    }

    @Test func cancellingSavesNothing() {
        let fixture = Fixture()
        fixture.hud.setAnchor(.centerLeft)
        fixture.picker.open()
        fixture.picker.cancel()

        #expect(fixture.selections.isEmpty)
        #expect(fixture.hud.currentAnchor == .centerLeft)
        #expect(HUDAnchorStore.load(fixture.defaults) == .centerLeft)
        #expect(!fixture.picker.isOpen)
    }

    @Test func aChoiceAfterThePickerClosedIsIgnored() {
        let fixture = Fixture()
        fixture.picker.open()
        fixture.picker.cancel()
        fixture.picker.choose(.topLeft)

        #expect(fixture.selections.isEmpty)
    }

    @Test func targetsAppearOnTheHUDDisplayAndTheOthersOnlyCatchClicks() {
        let fixture = Fixture()
        fixture.hudDisplay = Self.secondary
        fixture.picker.open()

        #expect(fixture.picker.display == Self.secondary)
        #expect(fixture.ordered.filter(\.key).map(\.frame) == [Self.secondary.frame])
        #expect(fixture.ordered.filter { !$0.key }.map(\.frame) == [Self.primary.frame])
        let usable = Self.secondary.visibleFrame.offsetBy(dx: -Self.secondary.frame.minX, dy: -Self.secondary.frame.minY)
        for target in fixture.picker.layout?.targets ?? [] {
            #expect(usable.contains(target.frame))
        }
    }

    @Test func theDisplayIsResolvedOnceAndStaysFixedWhileOpen() {
        let fixture = Fixture()
        fixture.picker.open()
        fixture.hudDisplay = Self.secondary
        fixture.picker.open()

        #expect(fixture.resolutions == 1)
        #expect(fixture.picker.display == Self.primary)
        #expect(fixture.picker.panelCount == 2)
    }

    @Test func withNoDisplayItDoesNotOpen() {
        let fixture = Fixture()
        fixture.hudDisplay = nil
        fixture.picker.open()

        #expect(!fixture.picker.isOpen)
        #expect(!fixture.picker.isObservingDisplays)
    }

    @Test func aDisplayChangeClosesItWithoutSaving() {
        let fixture = Fixture()
        fixture.picker.open()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        #expect(!fixture.picker.isOpen)
        #expect(fixture.selections.isEmpty)
    }

    @Test func everyExitReleasesItsPanelsAndObserver() {
        let fixture = Fixture()
        for exit in [{ fixture.picker.cancel() }, { fixture.picker.choose(.topCenter) }] {
            fixture.picker.open()
            #expect(fixture.picker.panelCount == 2)
            #expect(fixture.picker.isObservingDisplays)
            exit()
            #expect(fixture.picker.panelCount == 0)
            #expect(!fixture.picker.isObservingDisplays)
            #expect(fixture.picker.layout == nil)
        }
    }

    @Test func resetAndThePickerShareOneAnchor() {
        let fixture = Fixture()
        fixture.picker.open()
        fixture.picker.choose(.topLeft)
        fixture.hud.resetAnchor()

        #expect(fixture.hud.currentAnchor == .default)
        #expect(HUDAnchorStore.load(fixture.defaults) == .default)
        fixture.picker.open()
        #expect(fixture.picker.markedAnchor == .default)
    }
}

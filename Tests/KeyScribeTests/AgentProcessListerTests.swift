import Foundation
import Testing
@testable import KeyScribeApp
@testable import KeyScribeKit

struct AgentProcessListerTests {
    @Test func theScanKeepsEachRulesSetupAndProfileVariablesBesideTheTerminalOnes() {
        let kept = AgentProcessLister.environmentKeys(keeping: ["TMUX_PANE"], rules: [.pi, .omp])
        #expect(kept == ["TMUX_PANE", "PI_CODING_AGENT_DIR", "OMP_PROFILE", "PI_PROFILE"])
    }
}

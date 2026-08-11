import Foundation
import Testing
@testable import VeniceVideoCreator

/// fix_panel close-up guard (harness anti-pattern 6): multi-edit on tight framing
/// tends to re-crop and drift off-aspect, so the tool warns and points at a clean
/// regeneration for those shots.
@Suite("fix_panel close-up detection")
struct FixPanelCloseUpTests {

    @Test func detectsCloseUpFraming() {
        for text in ["Close-up on her eyes", "extreme close up of the watch", "TIGHT ON the trigger", "macro shot of dew"] {
            let shot = Shot(id: "s", summary: text, prompt: "")
            #expect(ToolExecutor.isLikelyCloseUp(shot), "expected close-up for: \(text)")
        }
    }

    @Test func wideAndMediumShotsAreNotCloseUps() {
        for text in ["Wide establishing shot of the valley", "Medium two-shot at the bar", "A dolly through the corridor"] {
            let shot = Shot(id: "s", summary: text, prompt: "")
            #expect(!ToolExecutor.isLikelyCloseUp(shot), "did not expect close-up for: \(text)")
        }
    }

    @Test func scansPromptAndBlockingToo() {
        let shot = Shot(id: "s", summary: "", prompt: "she turns", blocking: "closeup on the hands, screen center")
        #expect(ToolExecutor.isLikelyCloseUp(shot))
    }
}

/// fix_panel reference-anchored correction (harness item #6 tail): with character
/// refs attached the instruction must name image 1 as the panel to preserve, so
/// multi-edit corrects likeness against the refs instead of recomposing the frame.
@Suite("fix_panel instruction composition")
struct FixPanelInstructionTests {

    @Test func noRefsReturnsBaseUnchanged() {
        let base = "Fix these problems while keeping the same shot: wrong jacket color."
        #expect(ToolExecutor.fixPanelInstruction(base: base, refCount: 0) == base)
    }

    @Test func singleRefNamesImageTwoAndAnchorsPanel() {
        let base = "Match Bruno's face."
        let out = ToolExecutor.fixPanelInstruction(base: base, refCount: 1)
        #expect(out.contains("image 1 (the storyboard panel)"))
        #expect(out.contains("(image 2)"))
        #expect(out.hasSuffix(base))
    }

    @Test func multipleRefsNameTheImageRange() {
        let base = "Correct both faces."
        let out = ToolExecutor.fixPanelInstruction(base: base, refCount: 3)
        // panel is image 1, three refs are images 2–4.
        #expect(out.contains("(images 2–4)"))
        #expect(out.contains("composition, framing and aspect ratio of image 1"))
        #expect(out.hasSuffix(base))
    }
}

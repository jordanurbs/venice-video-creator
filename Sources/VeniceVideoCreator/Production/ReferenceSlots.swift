import Foundation

/// The ordered `@Image1..@ImageN` slot plan for @Image-tag video models
/// (the Seedance R2V family — harness rule 42, ported from
/// `src/mini-drama/reference-slots.ts`). The @ImageN index in the prompt MUST
/// match the push order of `reference_image_urls` in the queue body, so the
/// prompt builder and the generator consume the SAME ordered slot list built
/// here — the two can never disagree about which reference is whom.
///
/// Slot / fill order (within the per-model budget): character primaries →
/// storyboard blocking plate (protected) → location angles → extra character
/// angles. Overflow drops from the bottom: extra character angles first, then
/// trailing location angles.
enum ReferenceSlots {
    enum Kind: Equatable, Sendable {
        case characterPrimary, characterAngle, storyboard, location
    }

    /// A ready reference plus its prompt role (without the `@ImageN` prefix).
    struct Candidate {
        let kind: Kind
        let asset: MediaAsset
        /// Character name (character slots), location name, or panel slug.
        let label: String
        /// Role clause emitted verbatim after `@ImageN` for non-character slots.
        let roleClause: String
    }

    struct Slot {
        let imageIndex: Int   // 1-based; @Image<imageIndex>
        let kind: Kind
        let asset: MediaAsset
        let label: String
        let roleClause: String
    }

    struct Plan {
        let slots: [Slot]
        /// Uppercased character name → its primary slot's 1-based index.
        let characterSlotByName: [String: Int]

        /// Push order for `reference_image_urls` — identical to the tiered stack
        /// the non-tag path builds, so refs are unchanged; only the prompt gains
        /// the @ImageN bindings.
        var imageRefs: [MediaAsset] { slots.map(\.asset) }
        var isEmpty: Bool { slots.isEmpty }

        /// Up-front identity declarations for character primaries:
        /// "@Image1 is Bob — use this reference for Bob's face, hair, and wardrobe."
        var identityDeclarations: [String] {
            slots.filter { $0.kind == .characterPrimary }.map {
                "@Image\($0.imageIndex) is \($0.label) — use this reference for \($0.label)'s face, hair, and wardrobe."
            }
        }

        /// Role clauses for the non-character slots (storyboard, location):
        /// "@Image5 is a second angle of the same location …"
        var roleClauseLines: [String] {
            slots.filter { $0.kind != .characterPrimary && !$0.roleClause.isEmpty }
                .map { "@Image\($0.imageIndex) \($0.roleClause)." }
        }

        /// Replaces character names in `text` with their `@ImageN` tag (whole
        /// word, case-insensitive), longest names first so overlapping names
        /// don't partially match.
        func substitutingNames(in text: String) -> String {
            guard !characterSlotByName.isEmpty, !text.isEmpty else { return text }
            var out = text
            let byLength = characterSlotByName.keys.sorted { $0.count > $1.count }
            for upperName in byLength {
                guard let index = characterSlotByName[upperName] else { continue }
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: upperName))\\b"
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(out.startIndex..<out.endIndex, in: out)
                out = re.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "@Image\(index)")
            }
            return out
        }
    }

    /// Allocates candidates into slots up to `budget`, assigning 1-based indices
    /// in fill order. Characters always occupy the first slots so a drop never
    /// renumbers a character's @ImageN.
    static func build(
        primaries: [Candidate],
        storyboard: [Candidate],
        location: [Candidate],
        characterAngles: [Candidate],
        budget: Int
    ) -> Plan {
        let fillOrder = primaries + storyboard + location + characterAngles
        var slots: [Slot] = []
        for candidate in fillOrder {
            guard slots.count < max(1, budget) else { break }
            slots.append(Slot(
                imageIndex: slots.count + 1, kind: candidate.kind,
                asset: candidate.asset, label: candidate.label, roleClause: candidate.roleClause
            ))
        }
        var byName: [String: Int] = [:]
        for slot in slots where slot.kind == .characterPrimary {
            byName[slot.label.uppercased()] = slot.imageIndex
        }
        return Plan(slots: slots, characterSlotByName: byName)
    }

    // MARK: - Role clauses (mirror the harness wording)

    static func locationRoleClause(name: String, angleIndex: Int) -> String {
        angleIndex == 0
            ? "is the location environment reference (\(name)) — match its setting, architecture, and lighting; it is not a character"
            : "is another angle of the same location (\(name)) — same place, different angle; keep the environment consistent with it"
    }

    static let storyboardRoleClause =
        "is the storyboard blocking reference — it shows where the characters are positioned "
        + "in the location and in relation to each other; use it ONLY for composition, blocking, "
        + "and spatial relationships. Take each character's appearance from their own reference "
        + "image and the environment from the location references. It is not a character and not "
        + "a style reference"

    /// Per-beat blocking plate for a multi-shot unit (harness rule 42 plates):
    /// each beat carries its OWN composition anchor so beats 2+ aren't left
    /// guessing their layout. Names the beat when a slug is known so the model
    /// ties the plate to the right moment.
    static func storyboardBeatRoleClause(slug: String?) -> String {
        let beat = (slug?.isEmpty == false) ? " for the beat \"\(slug!)\"" : ""
        return "is a storyboard blocking plate\(beat) — it shows where the characters stand in the "
            + "location and in relation to each other for that beat; use it ONLY for composition, "
            + "blocking, and spatial relationships. Take each character's appearance from their own "
            + "reference image and the environment from the location references. It is not a character "
            + "and not a style reference"
    }

    static func characterAngleRoleClause(name: String) -> String {
        "is a second angle of \(name) — same person as \(name)'s primary reference"
    }
}

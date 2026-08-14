import Foundation

/// List-selection arithmetic, kept pure and AppKit-free so the fiddly parts
/// (shift-ranges across a re-ordered list, an anchor pointing at a row that has
/// since disappeared) can be tested directly.
enum Selection {
    /// What the click meant. `TorrentStore` maps SwiftUI's `EventModifiers`
    /// onto this so the rules don't depend on the UI framework.
    enum Gesture {
        /// Plain click — replaces the selection.
        case replace
        /// Shift-click — selects the range from the anchor to here.
        case extend
        /// Command-click — toggles this row, leaving the rest alone.
        case toggle
    }

    /// The new selection and anchor after `gesture` on `id`.
    ///
    /// `order` is the *visual* order (what the user sees top to bottom), which
    /// is what a shift-range must walk — grouping means it differs from the
    /// server's order. An `extend` with no usable anchor degrades to a plain
    /// click rather than selecting nothing.
    static func apply(
        _ gesture: Gesture,
        to id: Int,
        current: Set<Int>,
        anchor: Int?,
        order: [Int]
    ) -> (selection: Set<Int>, anchor: Int?) {
        switch gesture {
        case .extend:
            if let anchor,
               let from = order.firstIndex(of: anchor),
               let to = order.firstIndex(of: id) {
                let range = from <= to ? from...to : to...from
                // The anchor stays put, so dragging the shift-click back and
                // forth grows and shrinks one range instead of ratcheting.
                return (Set(order[range]), anchor)
            }
            return ([id], id)

        case .toggle:
            var selection = current
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            return (selection, id)

        case .replace:
            return ([id], id)
        }
    }

    /// What one Escape press should do.
    enum EscapeStep {
        case clearSelection
        case clearSearch
        case close
    }

    /// Escape peels back one layer of transient state per press: selection
    /// first (the lightest, most recently made), then the search filter, and
    /// only then the panel itself. Same order as the Linux popup.
    static func escape(hasSelection: Bool, hasSearch: Bool) -> EscapeStep {
        if hasSelection { return .clearSelection }
        if hasSearch { return .clearSearch }
        return .close
    }

    /// The row an Up (`direction` -1) or Down (+1) keypress lands on, or nil
    /// when the list is empty.
    ///
    /// `cursor` is the moving end of the selection — the row last clicked or
    /// arrowed onto. It's distinct from the anchor: shift-arrowing walks the
    /// cursor while the anchor stays put, which is what lets a range grow *and*
    /// shrink. When the cursor has been filtered away, movement resumes from
    /// the last still-visible selected row; with nothing selected at all, Down
    /// starts at the top and Up at the bottom. Movement stops at the ends
    /// rather than wrapping.
    static func step(_ direction: Int, current: Set<Int>, cursor: Int?, order: [Int]) -> Int? {
        guard !order.isEmpty else { return nil }
        let index: Int? = cursor.flatMap { order.firstIndex(of: $0) }
            ?? order.lastIndex(where: { current.contains($0) })
        guard let index else { return direction > 0 ? order.first : order.last }
        return order[min(max(index + direction, 0), order.count - 1)]
    }

    /// What Right (`expanded` true) or Left does to the expanded set: every
    /// highlighted row moves together, the way Pause and Remove already treat a
    /// multi-row selection as one thing.
    ///
    /// Deliberately idempotent — Right on an already-open row leaves it open
    /// rather than toggling. Arrow keys get held down and repeated, and a
    /// toggle under key repeat flickers the row open and shut.
    static func expansion(_ current: Set<Int>, setting expanded: Bool,
                          for ids: Set<Int>) -> Set<Int> {
        expanded ? current.union(ids) : current.subtracting(ids)
    }
}

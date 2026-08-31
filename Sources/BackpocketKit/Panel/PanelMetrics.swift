import SwiftUI

/// The panel's row grid, shared by the first-run window size and the section
/// frames. Once the user drags an edge their own frame is what reopens
/// (`PanelSize`); these numbers only decide where a fresh install starts and
/// how tall the links section sits inside whatever height it is given.
enum PanelMetrics {
    /// Row insets that keep the input field's icon and the list rows' icons
    /// on the same vertical line.
    static let rowInsets = EdgeInsets(top: 0.5, leading: 6, bottom: 0.5, trailing: 6)
    /// The padding List(.plain) adds on its own on top of listRowInsets.
    /// Measured from a screenshot to match.
    static let listInset: CGFloat = 6
    /// Where row icons start. The field, headers, and empty-state text align to this.
    static let textLeading = rowInsets.leading + listInset + 8

    /// Column floors in points, not fractions: a narrow panel must still show
    /// two usable columns. Only turning the notes off in Settings removes one.
    /// Their sum stays under PanelSize.minWidth so both always fit.
    static let minNotesColumn: CGFloat = 200
    static let minLeftColumn: CGFloat = 260

    /// A 30pt row plus the 1pt list gap.
    static let rowPitch: CGFloat = 31
    /// Section header text with its padding, plus the list's own top inset.
    static let sectionHeader: CGFloat = 30
    static let fieldRow: CGFloat = 41
    static let footer: CGFloat = 33
    /// A headerless links section collapsed to its hint line.
    static let emptyLinksHeight: CGFloat = 96

    static func linksSectionHeight(rows: Int) -> CGFloat {
        sectionHeader + CGFloat(rows) * rowPitch
    }

    /// The links row count is a parameter rather than a read of `LinkRows`, so
    /// this stays pure geometry: the height for a given number of rows, which
    /// a caller can ask about without the answer depending on what is stored.
    static func panelHeight(showsLinks: Bool, linkRows: Int = LinkRows.current) -> CGFloat {
        // The first-run row count; after that the user's dragged frame is
        // what reopens, so this is a starting size and not a preference.
        let clips = 9 * rowPitch
        let chrome = fieldRow + 1 + 1 + footer

        if showsLinks {
            return chrome + sectionHeader + clips + 1 + linksSectionHeight(rows: linkRows)
        }
        // The single headerless list carries only its own top inset.
        return chrome + 6 + clips
    }
}

import Foundation
import Testing

@testable import BackpocketKit

/// The panel's height math. What matters is that the pieces add up: the window
/// a fresh install opens has room for exactly the rows it claims, and every
/// section lands on the row grid. A height that is a few points wrong is what
/// puts the footer half off the bottom or leaves a strip of dead list under the
/// last row.
///
/// Every row count here is passed in, never read from the defaults database, so
/// nothing in this suite depends on — or can be disturbed by — what another
/// suite has stored.
@MainActor
@Suite("PanelMetrics")
struct PanelMetricsTests {
    /// Field, both dividers, and the footer: the part of the window that is
    /// never list, at any row count or layout.
    private let chrome = PanelMetrics.fieldRow + 1 + 1 + PanelMetrics.footer

    @Test func theFirstRunHeightIsNineWholeRowsPlusChrome() {
        // The single headerless list carries only its own inset, so the height
        // left over for rows has to be a whole number of them: a remainder
        // shows as a sliver of a tenth row under the ninth.
        let height = PanelMetrics.panelHeight(showsLinks: false)
        let list = height - chrome - PanelMetrics.listInset

        #expect(list == 9 * PanelMetrics.rowPitch)
        #expect(height >= PanelSize.minHeight)
    }

    @Test func splittingLinksOutAddsAHeaderADividerAndTheLinksSection() {
        // The split layout trades the plain list's inset for a section header,
        // a divider, and the whole links section — the clips list itself keeps
        // its nine rows either way.
        for rows in LinkRows.range {
            let split = PanelMetrics.panelHeight(showsLinks: true, linkRows: rows)
            let expected =
                chrome + PanelMetrics.sectionHeader + 9 * PanelMetrics.rowPitch + 1
                + PanelMetrics.linksSectionHeight(rows: rows)

            #expect(split == expected)
            #expect(split >= PanelSize.minHeight)
        }
    }

    @Test func eachExtraLinkRowGrowsOnlyTheSplitLayout() {
        // The clipboard side is a fixed starting size now that the user drags
        // the frame, so the row-count preference may move exactly one number.
        for rows in LinkRows.range.dropLast() {
            #expect(
                PanelMetrics.panelHeight(showsLinks: true, linkRows: rows + 1)
                    == PanelMetrics.panelHeight(showsLinks: true, linkRows: rows)
                    + PanelMetrics.rowPitch
            )
            #expect(
                PanelMetrics.panelHeight(showsLinks: false, linkRows: rows + 1)
                    == PanelMetrics.panelHeight(showsLinks: false, linkRows: rows)
            )
        }
    }

    @Test func theRowCountUsedForHeightDefaultsToThePreference() throws {
        // The one place the preference still reaches the geometry: the default
        // argument the panel relies on. Read from a store of this test's own,
        // so the stored value cannot change between the two calls below.
        try withScratchPreferences { defaults in
            defaults.set(7, forKey: PreferenceKey.linkRows)
            #expect(
                PanelMetrics.panelHeight(showsLinks: true)
                    == PanelMetrics.panelHeight(showsLinks: true, linkRows: 7)
            )
        }
    }

    @Test func theLinksSectionIsAHeaderPlusWholeRows() {
        // The section sits on the same grid as the list it shares space with;
        // a fractional height here shows as a clipped last row.
        for rows in LinkRows.range {
            let height = PanelMetrics.linksSectionHeight(rows: rows)
            #expect(height == PanelMetrics.sectionHeader + CGFloat(rows) * PanelMetrics.rowPitch)
            #expect(
                (height - PanelMetrics.sectionHeader)
                    .truncatingRemainder(dividingBy: PanelMetrics.rowPitch) == 0
            )
        }
    }

    @Test func aCollapsedLinksSectionIsShorterThanEveryPopulatedOne() {
        // The window reserves linksSectionHeight for the section; collapsed to
        // its hint line it hands the difference back to the clips list. A
        // collapsed height that exceeded a populated one would make the list
        // shrink when the links ran out.
        for rows in LinkRows.range {
            #expect(PanelMetrics.emptyLinksHeight < PanelMetrics.linksSectionHeight(rows: rows))
        }
    }

    @Test func withRoomToSpareTheLinksSectionFitsItsContent() {
        // Sized to the links it holds up to the preferred row count, and
        // collapsed to its hint line when there are none. The cap below only
        // ever takes height away from this.
        let ample: CGFloat = 10_000
        for rows in LinkRows.range {
            #expect(
                PanelMetrics.cappedLinksSectionHeight(
                    linkCount: 0, linkRows: rows, available: ample)
                    == PanelMetrics.emptyLinksHeight
            )
            for count in 1...12 {
                #expect(
                    PanelMetrics.cappedLinksSectionHeight(
                        linkCount: count, linkRows: rows, available: ample)
                        == PanelMetrics.linksSectionHeight(rows: min(count, rows))
                )
            }
        }
    }

    @Test func theLinksSectionLeavesTheClipsListARow() {
        // The frame is rigid, so on a short panel an uncapped links section
        // would run past the footer and squeeze the clipboard list to nothing.
        // A header, one row and the divider between the sections must survive.
        let clipsFloor = PanelMetrics.sectionHeader + PanelMetrics.rowPitch + 1
        let shortest = clipsFloor + PanelMetrics.rowPitch

        // The smallest panel the user can drag to is inside that range, so the
        // promise holds for every frame they can choose.
        #expect(PanelSize.minHeight - chrome >= shortest)

        for available in stride(from: shortest, through: 600, by: 0.5) {
            for rows in LinkRows.range {
                for count in [0, 1, rows, 12] {
                    let links = PanelMetrics.cappedLinksSectionHeight(
                        linkCount: count, linkRows: rows, available: available)
                    #expect(available - links >= clipsFloor)
                }
            }
        }
    }

    @Test func belowThatTheLinksSectionBottomsOutAtOneRowPitch() {
        // Too short for both lists, the cap is floored rather than following
        // the column down, so the rigid frame it sets never reaches zero or
        // goes negative.
        let shortest = PanelMetrics.sectionHeader + 2 * PanelMetrics.rowPitch + 1
        for available in stride(from: 0, to: shortest, by: 0.5) {
            for rows in LinkRows.range {
                for count in [0, 1, rows, 12] {
                    #expect(
                        PanelMetrics.cappedLinksSectionHeight(
                            linkCount: count, linkRows: rows, available: available)
                            == PanelMetrics.rowPitch
                    )
                }
            }
        }
    }

    @Test func theColumnFloorsBothFitInsideTheMinimumWidth() {
        // Two usable columns at the narrowest allowed panel is the promise;
        // floors that summed past the minimum would clip one of them.
        #expect(PanelMetrics.minNotesColumn + PanelMetrics.minLeftColumn <= PanelSize.minWidth)
    }
}

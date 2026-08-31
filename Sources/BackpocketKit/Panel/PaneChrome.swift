import SwiftUI

/// Chrome shared by the panel's two column builders. Written once because
/// the copies had already started to drift — only one of them carried the
/// comments explaining the scroll pinning below.

/// A section title with its count capsule.
struct SectionTitle: View {
    let title: LocalizedStringKey
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .padding(.leading, PanelMetrics.textLeading)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// What a section shows instead of rows when it has none.
struct EmptyLine: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.leading, PanelMetrics.textLeading)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

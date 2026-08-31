import AppKit
import SwiftUI

/// Shown alone, instead of the lists, when the accessibility permission is missing.
/// This is the first drop-off point, so the screen narrows the job to a single task.
struct Onboarding: View {
    /// The panel's open counter. Hiding the panel only orders the window out
    /// — this view stays mounted — so the poll below has to be restarted per
    /// open rather than left running for the app's lifetime.
    var tick: Int
    var onRecheck: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("onboarding.title")
                .font(.headline)

            Text("onboarding.body")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // One button, no recheck, no troubleshooting copy: granting is
            // detected automatically below, so the screen stays a single task.
            Button("onboarding.openSettings") {
                Paster.requestAccessibility()
                Paster.openAccessibilitySettings()
            }
            .keyboardShortcut(.defaultAction)

            Text("onboarding.hint")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Granting happens in System Settings, where this app cannot know the
        // moment it lands — poll while visible so the panel flips to the real
        // UI by itself instead of demanding a manual recheck.
        .task(id: tick) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                // Checked again after the sleep: try? swallows the
                // cancellation, and a state write into a view being torn
                // down is what this avoids.
                guard !Task.isCancelled else { return }
                // A hidden panel keeps its view tree, so "while visible" is
                // something to verify, not assume; the next open restarts it.
                guard NSApp.windows.contains(where: { $0 is BackpocketPanel && $0.isVisible })
                else { return }
                onRecheck()
            }
        }
    }
}

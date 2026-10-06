import AppKit
import SwiftUI

/// Storage problems must be visible where people capture and use their notes.
struct StorageStatusView: View {
    @ObservedObject var store: Store

    var body: some View {
        if store.hasStorageFailure || store.recoveryDirectory != nil {
            VStack(alignment: .leading, spacing: 6) {
                if store.hasStorageFailure {
                    Label(
                        store.isUsingTemporaryStorage
                            ? "storage.temporary" : "settings.storageError",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                }
                if let directory = store.recoveryDirectory {
                    Label("storage.recovered", systemImage: "externaldrive.badge.exclamationmark")
                    HStack {
                        Button("storage.showBackups") {
                            NSWorkspace.shared.open(directory)
                        }
                        Button("storage.dismissRecovery") { store.acknowledgeRecovery() }
                    }
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.yellow.opacity(0.12))
        }
    }
}

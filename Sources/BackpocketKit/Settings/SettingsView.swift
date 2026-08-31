import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// The five preference panes hosted by SettingsWindow's toolbar tabs.
/// Each is a self-sizing grouped form of a single concern.

private let paneWidth: CGFloat = 500

extension Notification.Name {
    /// "Reset everything" moved state that every other pane snapshotted when
    /// it mounted. Panes stay mounted behind the tab bar, so appearing again
    /// is not something they can count on being told about.
    static let settingsDidReset = Notification.Name("dev.m2na.backpocket.settingsDidReset")
}

// MARK: - General

struct GeneralPane: View {
    @AppStorage(PreferenceKey.popupPosition)
    private var popupPosition = PopupPosition.default.rawValue

    // Deliberately not @AppStorage: bound to the store, the removal that
    // "Reset everything" performs comes back through the picker as a change
    // and gets written straight out again, undoing that half of the reset.
    @State private var language = AppLanguage.current.rawValue
    @State private var launch = LaunchAtLogin(status: SMAppService.mainApp.status)

    /// The chosen language differs from the one the app is running in, so a
    /// relaunch would change something. Derived rather than latched: a reset
    /// on another tab moves the answer without going through the picker.
    private var languageChanged: Bool {
        AppLanguage.restartPending(selection: language, running: .atLaunch)
    }

    var body: some View {
        Form {
            Section {
                // Both rows write through their binding rather than react to
                // the state changing: `refresh` moves the same state, and a
                // value pulled in from outside must not be written back out.
                Picker(
                    "settings.language",
                    selection: Binding(get: { language }, set: { setLanguage($0) })
                ) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }

                Toggle(
                    "settings.launchAtLogin",
                    isOn: Binding(get: { launch.isOn }, set: { setLaunchAtLogin($0) })
                )

                // Reads and writes Sparkle's own stored setting rather than a
                // PreferenceKey of ours: Sparkle consults its copy when it
                // decides whether to run a scheduled check, so a separate
                // preference would show the user a switch that changed
                // nothing. This is also the switch the READMEs promise, so it
                // has to be the one that actually governs the request.
                Toggle(
                    "settings.checkForUpdates",
                    isOn: Binding(
                        get: { Updater.checksAutomatically },
                        set: { Updater.checksAutomatically = $0 }
                    )
                )
            } footer: {
                if let launchError = launch.failure {
                    Text(launchError).foregroundStyle(.red)
                } else if languageChanged {
                    HStack {
                        Text("settings.restartNote")
                        Spacer()
                        Button("settings.restart") { AppRestart.now() }
                    }
                }
            }

            Section {
                Picker("settings.popupPosition", selection: $popupPosition) {
                    ForEach(PopupPosition.allCases) { position in
                        Text(position.labelKey).tag(position.rawValue)
                    }
                }

                LabeledContent("settings.panelSize") {
                    Button("settings.panelSize.reset") {
                        PanelSize.forget()
                        PreferenceStore.defaults.removeObject(forKey: PreferenceKey.notesFraction)
                    }
                }
            } footer: {
                Text("settings.panelSize.note")
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
        // Login Items can be flipped in System Settings, and the reset on the
        // Data tab moves the language — neither passes through this pane.
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidReset)) { _ in
            refresh()
        }
    }

    private func refresh() {
        language = AppLanguage.current.rawValue
        launch.refresh(status: SMAppService.mainApp.status)
    }

    private func setLanguage(_ raw: String) {
        language = raw
        AppLanguage(rawValue: raw)?.apply()
    }

    /// Only the two service calls live here; which one to make, and what the
    /// row shows before and after, belong to `LaunchAtLogin`.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            switch launch.requested(enabled) {
            case .register:
                try SMAppService.mainApp.register()
            case .unregister:
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launch.failed(
                String(
                    format: String(localized: "settings.launchError"),
                    error.localizedDescription
                ),
                status: SMAppService.mainApp.status
            )
        }
    }
}

// MARK: - Shortcuts

/// Every rebindable shortcut, each behind the same click-to-record button
/// as the global hotkey — plus one reset for the lot.
struct ShortcutsPane: View {
    /// Registration is the app's, not this view's. See `HotKeyControl`.
    let hotKeyControl: HotKeyControl

    @State private var hotKey = HotKeyBinding.current
    @State private var status = HotKeyStatus.active
    @State private var bindings: [PanelShortcut: KeyBinding] = Self.currentBindings()
    @State private var conflicted = false

    /// The one row currently recording: the global hotkey or a panel action.
    private enum Recording: Equatable {
        case global
        case action(PanelShortcut)
    }
    @State private var recording: Recording?
    @State private var keyMonitor: Any?
    /// The global shortcut is torn down for the duration of its own recording.
    @State private var globalSuspended = false

    private static func currentBindings() -> [PanelShortcut: KeyBinding] {
        Dictionary(uniqueKeysWithValues: PanelShortcut.allCases.map { ($0, $0.current) })
    }

    private var hotKeyMessage: LocalizedStringKey? {
        switch status {
        case .active: nil
        case .inactive: "settings.hotkey.inactive"
        case .rejected: "settings.hotkey.error"
        case .reserved: "settings.hotkey.reserved"
        case .taken: "settings.hotkey.taken"
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("settings.hotkey.open") {
                    recorderButton(
                        title: hotKey.label,
                        active: recording == .global
                    ) {
                        toggle(.global)
                    }
                }
            } footer: {
                if let hotKeyMessage {
                    Text(hotKeyMessage).foregroundStyle(.red)
                }
            }

            Section {
                ForEach(PanelShortcut.allCases) { shortcut in
                    LabeledContent(shortcut.labelKey) {
                        recorderButton(
                            title: bindings[shortcut]?.label ?? shortcut.defaultBinding.label,
                            active: recording == .action(shortcut)
                        ) {
                            toggle(.action(shortcut))
                        }
                    }
                }
            } header: {
                Text("settings.shortcuts.items")
            } footer: {
                if conflicted {
                    Text("settings.shortcuts.conflict").foregroundStyle(.red)
                } else {
                    Text("settings.shortcuts.note")
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("settings.shortcuts.resetAll") { resetAll() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
        // Every value here is a snapshot, and "Reset everything" on the Data
        // tab moves all of them without this pane hearing about it.
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidReset)) { _ in
            stopRecording()
            refresh()
        }
        .onDisappear { stopRecording() }
        // An armed recorder swallows every keystroke app-wide — the monitor
        // returns nil on all paths — so anything typed into the panel opened
        // by the global hotkey would silently rebind a shortcut. Losing key
        // focus disarms it; onDisappear alone does not fire for a tab that
        // stays mounted behind another window.
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
        ) { _ in
            stopRecording()
        }
    }

    private func recorderButton(
        title: String, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if active {
                Text("settings.hotkey.recording")
                    .foregroundStyle(.secondary)
            } else {
                Text(title)
                    .monospaced()
            }
        }
        .buttonStyle(.bordered)
    }

    private func refresh() {
        hotKey = HotKeyBinding.current
        bindings = Self.currentBindings()
        conflicted = false
        status = hotKeyControl.isActive() ? .active : .inactive
    }

    private func resetAll() {
        stopRecording()
        conflicted = false
        PanelShortcut.resetAll()
        bindings = Self.currentBindings()
        applyGlobal(.standard)
    }

    // MARK: Recording

    private func toggle(_ target: Recording) {
        if recording == target {
            stopRecording()
        } else {
            startRecording(target)
        }
    }

    /// A local monitor beats a focused invisible field: it captures ANY
    /// combination — including ones a text field would consume — and
    /// swallows the event so recording never types into the form.
    private func startRecording(_ target: Recording) {
        stopRecording()
        recording = target
        conflicted = false

        if target == .global {
            // Carbon consumes the registered combination before this monitor
            // sees it, so the shortcut in force is the one combination that
            // could never be re-recorded — pressing it would just open the
            // panel and cancel the recording.
            hotKeyControl.suspend()
            globalSuspended = true
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if ShortcutRecorder.cancels(
                keyCode: Int(event.keyCode), modifiers: event.modifierFlags
            ) {
                stopRecording()
                return nil
            }

            switch target {
            case .global:
                guard let captured = HotKeyBinding(capturing: event) else { return nil }
                // applyGlobal registers on every path, refusal included, so
                // the suspended shortcut needs no separate restore here.
                globalSuspended = false
                stopRecording()
                applyGlobal(captured)
            case .action(let shortcut):
                guard let captured = KeyBinding(capturing: event) else { return nil }
                stopRecording()
                apply(captured, to: shortcut)
            }
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        recording = nil

        // A recording that ended without a capture — Esc, a click elsewhere,
        // the window losing focus — has to put the shortcut back.
        if globalSuspended {
            globalSuspended = false
            if !registerCurrent() {
                status = .inactive
            }
        }
    }

    private func apply(_ binding: KeyBinding, to shortcut: PanelShortcut) {
        // Which combinations are refused is PanelShortcut's rule, where it
        // can be tested; this only reports the answer to the recorder.
        guard
            !PanelShortcut.conflicts(binding, assignedTo: shortcut, globalHotKeyLabel: hotKey.label)
        else {
            conflicted = true
            return
        }

        conflicted = false
        shortcut.persist(binding)
        bindings[shortcut] = binding
    }

    /// Only the persisting and the registering live here; which of the five
    /// outcomes a recorded combination reaches, and what to roll back to,
    /// belong to `GlobalShortcutChange`.
    private func applyGlobal(_ binding: HotKeyBinding) {
        let change = GlobalShortcutChange(
            binding: binding,
            previous: hotKey,
            isReserved: binding.isReserved,
            claimedByPanelShortcut: PanelShortcut.anyClaims(label: binding.label)
        )

        if let accepted = change.bindingToPersist {
            accepted.persist()
            hotKey = accepted
        }

        switch change.registered(registerCurrent()) {
        case .settled(let settled):
            status = settled
        case .rollBack(let previous):
            previous.persist()
            hotKey = previous
            status = GlobalShortcutChange.rolledBack(registerCurrent())
        }
    }

    /// Registers whatever is persisted right now.
    private func registerCurrent() -> Bool {
        hotKeyControl.apply()
    }
}

// MARK: - Clipboard

struct HistoryPane: View {
    // Every default here is the one the matching accessor in Preferences falls
    // back to, named rather than spelled out: a control that started from a
    // different value than the app reads would show the user a setting the app
    // is not obeying.
    @AppStorage(PreferenceKey.pasteAutomatically)
    private var pasteAutomatically = PasteBehavior.default
    @AppStorage(PreferenceKey.showPreview) private var showPreview = PreviewBehavior.default
    @AppStorage(PreferenceKey.showNotes) private var showNotes = NotesVisibility.default
    @AppStorage(PreferenceKey.collectLinks)
    private var collectLinks = LinkCollection.default.rawValue
    @AppStorage(PreferenceKey.linkRows) private var linkRows = LinkRows.default
    @AppStorage(PreferenceKey.linkClick) private var linkClick = LinkClickAction.default.rawValue
    @AppStorage(PreferenceKey.fetchFavicons) private var fetchFavicons = FaviconFetching.default
    @AppStorage(PreferenceKey.historyLimit)
    private var historyLimit = HistoryLimit.default.rawValue
    @AppStorage(PreferenceKey.expiryDays) private var expiryDays = ExpiryOption.default.rawValue

    /// The rows below the picker configure a links section, so they follow
    /// whether there IS one — not whether links were moved out of the
    /// clipboard list to fill it.
    private var showsLinksSection: Bool {
        LinkCollection(rawValue: collectLinks)?.showsLinks ?? LinkCollection.default.showsLinks
    }

    var body: some View {
        Form {
            Section {
                Toggle("settings.pasteAutomatically", isOn: $pasteAutomatically)
                Toggle("settings.showPreview", isOn: $showPreview)
                Toggle("settings.showNotes", isOn: $showNotes)
            } footer: {
                Text("settings.pasteAutomatically.note")
            }

            Section {
                Picker("settings.collectLinks", selection: $collectLinks) {
                    ForEach(LinkCollection.allCases) { option in
                        Text(option.labelKey).tag(option.rawValue)
                    }
                }

                if showsLinksSection {
                    LabeledContent("settings.linkRows") {
                        HStack(spacing: 8) {
                            Text("\(linkRows)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Stepper("", value: $linkRows, in: LinkRows.range)
                                .labelsHidden()
                        }
                    }

                    Picker("settings.linkClick", selection: $linkClick) {
                        ForEach(LinkClickAction.allCases) { action in
                            Text(action.labelKey).tag(action.rawValue)
                        }
                    }

                    Toggle("settings.fetchFavicons", isOn: $fetchFavicons)
                }

                // Outside the branch above: the icons already on disk name
                // every site the user copied a link from, and turning link
                // collection off must not hide the way to be rid of them.
                LabeledContent("settings.favicons.cache") {
                    Button("settings.favicons.clear") {
                        Favicons.clearCachedIcons()
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("settings.collectLinks.note")
                    if showsLinksSection {
                        Text("settings.fetchFavicons.note")
                    }
                }
            }

            Section {
                Picker("settings.historyLimit", selection: $historyLimit) {
                    ForEach(HistoryLimit.allCases) { option in
                        Text(option.labelKey).tag(option.rawValue)
                    }
                }

                Picker("settings.retention", selection: $expiryDays) {
                    ForEach(ExpiryOption.allCases) { option in
                        Text(option.labelKey).tag(option.rawValue)
                    }
                }
            } footer: {
                Text("settings.retention.note")
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
    }
}

// MARK: - Ignored apps

struct IgnorePane: View {
    @State private var bundleIDs = IgnoredApps.bundleIDs
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.ignore.note")
                .font(.callout)
                .foregroundStyle(.secondary)

            listBox

            // The native +/- pattern from System Settings list editors.
            HStack(spacing: 0) {
                Button(action: addApp) {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 20)
                }
                .help("settings.ignore.add")
                Divider().frame(height: 14)
                Button(action: removeSelected) {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 20)
                }
                .help("settings.ignore.remove")
                .disabled(selection == nil)
            }
            .buttonStyle(.borderless)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(20)
        .frame(width: paneWidth)
        // The list is a snapshot, and + / − write the whole array back: left
        // stale, they would restore apps that "Reset everything" just cleared.
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidReset)) { _ in
            refresh()
        }
    }

    @ViewBuilder
    private var listBox: some View {
        Group {
            if bundleIDs.isEmpty {
                Text("settings.ignore.empty")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(bundleIDs, id: \.self, selection: $selection) { bundleID in
                    HStack(spacing: 8) {
                        if let icon = IgnoredApps.icon(for: bundleID) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 18, height: 18)
                        }
                        Text(IgnoredApps.name(for: bundleID))
                    }
                    .tag(bundleID)
                }
                .listStyle(.bordered)
            }
        }
        .frame(height: 220)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    private func refresh() {
        bundleIDs = IgnoredApps.bundleIDs
        selection = nil
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK else { return }

        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        bundleIDs = Array(Set(bundleIDs + added)).sorted {
            IgnoredApps.name(for: $0) < IgnoredApps.name(for: $1)
        }
        IgnoredApps.bundleIDs = bundleIDs
    }

    private func removeSelected() {
        guard let selection else { return }
        bundleIDs.removeAll { $0 == selection }
        IgnoredApps.bundleIDs = bundleIDs
        self.selection = nil
    }
}

// MARK: - Data

struct DataPane: View {
    @ObservedObject var store: Store
    /// The reset can restore the default combination, which then has to be
    /// registered. See `HotKeyControl`.
    let hotKeyControl: HotKeyControl

    @State private var pendingWipe: WipeAction?

    enum WipeAction: String, Identifiable {
        case history
        case notes
        case everything

        var id: String { rawValue }

        var labelKey: LocalizedStringKey {
            switch self {
            case .history: "settings.clearHistory"
            case .notes: "settings.clearNotes"
            case .everything: "settings.resetAll"
            }
        }
    }

    private var historyCount: Int { store.items.filter(\.isDisposable).count }
    private var noteCount: Int { store.items.filter(\.isNote).count }

    var body: some View {
        Form {
            Section {
                wipeRow("settings.clearHistory", count: historyCount, action: .history)
                wipeRow("settings.clearNotes", count: noteCount, action: .notes)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("settings.clearHistory.note")
                    // These actions promise the deletion cannot be undone;
                    // when the store cannot write, what they promise did not
                    // reach the disk either.
                    if store.hasStorageFailure {
                        Text("settings.storageError")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                HStack {
                    Button("settings.resetAll", role: .destructive) {
                        pendingWipe = .everything
                    }
                    Spacer()
                }
            } footer: {
                Text("settings.resetAll.note")
            }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
        .confirmationDialog(
            pendingWipe?.labelKey ?? "",
            isPresented: .init(
                get: { pendingWipe != nil },
                set: { if !$0 { pendingWipe = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingWipe
        ) { action in
            Button(action.labelKey, role: .destructive) { perform(action) }
        } message: { _ in
            Text("confirm.cannotUndo")
        }
    }

    private func wipeRow(
        _ key: LocalizedStringKey,
        count: Int,
        action: WipeAction
    ) -> some View {
        HStack {
            Button(key) { pendingWipe = action }
                .disabled(count == 0)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func perform(_ action: WipeAction) {
        switch action {
        case .history:
            store.clearHistory()
        case .notes:
            store.clearNotes()
        case .everything:
            store.clearAll()
            PreferenceKey.resetAll()
            // Nothing else touches the icon directory, so without this the
            // reset leaves behind a list of every domain the user copied.
            Favicons.clearCachedIcons()
            // The hotkey may have just changed back to the default.
            _ = hotKeyControl.apply()
            NotificationCenter.default.post(name: .settingsDidReset, object: nil)
        }
    }
}

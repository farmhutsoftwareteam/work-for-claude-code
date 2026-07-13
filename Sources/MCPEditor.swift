import SwiftUI

// MARK: - MCP Editor sheet (add or edit)

struct MCPEditor: View {
    enum Mode: Identifiable {
        case add(defaultScope: MCPConfigWriter.Scope)
        case addFromMarketplace(draft: MCPDraft, defaultScope: MCPConfigWriter.Scope)
        case edit(MCPServer, scope: MCPConfigWriter.Scope)
        /// "Use in this project": copy an existing (usually user-scope)
        /// server down to project/local scope, prefilled, SAME NAME — Claude
        /// Code's scope precedence (local > project > user, whole entry, no
        /// merging) makes the same-named copy a per-project override. This
        /// is how "supabase, but pointed at THIS project's project_ref"
        /// works without a second hand-rolled `supabase-myproject` entry.
        case useInProject(draft: MCPDraft, cwd: String)

        var id: String {
            switch self {
            case .add: return "add"
            case .addFromMarketplace(let draft, _): return "marketplace-\(draft.name)"
            case .edit(let mcp, _): return "edit-\(mcp.name)"
            case .useInProject(let draft, let cwd): return "useinproject-\(draft.name)-\(cwd)"
            }
        }
    }

    let mode: Mode
    let onSaved: () -> Void

    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    // Form state
    @State private var draft: MCPDraft
    @State private var selectedType: TransportType
    @State private var scope: MCPConfigWriter.Scope
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// Secret guardrail: .mcp.json (project scope) is committed to git.
    /// Saving a literal token/key into it is the "oops, pushed a secret"
    /// class of accident — intercept once with a choice, don't hard-block.
    @State private var showSecretWarning = false

    enum TransportType: String, CaseIterable {
        case stdio, http, sse
        var label: String {
            switch self {
            case .stdio: "Command (stdio)"
            case .http: "HTTP"
            case .sse: "SSE"
            }
        }
    }

    private var isEditMode: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var isMarketplaceInstall: Bool {
        if case .addFromMarketplace = mode { return true }
        return false
    }

    private var isUseInProject: Bool {
        if case .useInProject = mode { return true }
        return false
    }

    private var originalName: String? {
        if case .edit(let mcp, _) = mode { return mcp.name }
        return nil
    }

    private var titleText: String {
        if isEditMode { return "Edit \(originalName ?? "")" }
        if isMarketplaceInstall { return "Install from Marketplace" }
        if case .useInProject(let draft, _) = mode { return "Use \(draft.name) in this project" }
        return "New MCP Server"
    }

    private var saveText: String {
        if isEditMode { return "Save Changes" }
        if isMarketplaceInstall { return "Install" }
        if isUseInProject { return "Add to Project" }
        return "Create MCP"
    }

    init(mode: Mode, onSaved: @escaping () -> Void) {
        self.mode = mode
        self.onSaved = onSaved

        switch mode {
        case .add(let defaultScope):
            _draft = State(initialValue: .empty())
            _selectedType = State(initialValue: .stdio)
            _scope = State(initialValue: defaultScope)
        case .addFromMarketplace(let prefilled, let defaultScope):
            _draft = State(initialValue: prefilled)
            switch prefilled.transport {
            case .stdio: _selectedType = State(initialValue: .stdio)
            case .http: _selectedType = State(initialValue: .http)
            case .sse: _selectedType = State(initialValue: .sse)
            default: _selectedType = State(initialValue: .stdio)
            }
            _scope = State(initialValue: defaultScope)
        case .edit(let mcp, let s):
            _draft = State(initialValue: .from(mcp))
            switch mcp.transport {
            case .stdio: _selectedType = State(initialValue: .stdio)
            case .http: _selectedType = State(initialValue: .http)
            case .sse: _selectedType = State(initialValue: .sse)
            default: _selectedType = State(initialValue: .stdio)
            }
            _scope = State(initialValue: s)
        case .useInProject(let prefilled, let cwd):
            _draft = State(initialValue: prefilled)
            switch prefilled.transport {
            case .stdio: _selectedType = State(initialValue: .stdio)
            case .http: _selectedType = State(initialValue: .http)
            case .sse: _selectedType = State(initialValue: .sse)
            default: _selectedType = State(initialValue: .stdio)
            }
            // Local, not project: matches `claude mcp add`'s own default and
            // is the safe choice for a copy that usually carries credentials
            // (local never touches version control). Scope picker still
            // offers .project for teams that want it shared.
            _scope = State(initialValue: .local(cwd: cwd))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(titleText)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameField
                    typePicker
                    transportFields
                    envEditor
                    advancedAuthSection
                    advancedServerOptionsSection
                    scopePicker

                    if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.red)
                            .padding(.top, 8)
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button(action: save) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(saveText)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
            .padding(16)
        }
        .frame(width: 520, height: 620)
        .confirmationDialog(
            "This looks like a secret headed for git",
            isPresented: $showSecretWarning,
            titleVisibility: .visible
        ) {
            if let localScope = warningLocalScope {
                Button("Save to Local scope instead (private)") { performSave(overrideScope: localScope) }
            }
            Button("Save to .mcp.json anyway", role: .destructive) { performSave() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(literalSecrets.joined(separator: ", ")) contain\(literalSecrets.count == 1 ? "s" : "") a literal value, and Project scope writes .mcp.json — a file meant to be committed. Local scope keeps it out of version control, or reference an environment variable instead (e.g. ${SUPABASE_ACCESS_TOKEN}).")
        }
        .onChange(of: selectedType) { _, newType in
            // When switching types, preserve the URL between http/sse and clear env when
            // switching away from stdio (env vars are stdio-only).
            let existingURL: String = {
                switch draft.transport {
                case .http(let u), .sse(let u): return u
                default: return ""
                }
            }()

            switch newType {
            case .stdio:
                if case .stdio = draft.transport { return }
                draft.transport = .stdio(command: "", args: [])
            case .http:
                if case .http = draft.transport { return }
                draft.transport = .http(url: existingURL)
                draft.env = [:]
            case .sse:
                if case .sse = draft.transport { return }
                draft.transport = .sse(url: existingURL)
                draft.env = [:]
            }
        }
    }

    // MARK: - Form sections

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Name", systemImage: "tag")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("e.g. my-mcp-server", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .disabled(isEditMode)
                .help(isEditMode ? "Names can't be changed — delete and re-add to rename" : "")
            if isUseInProject {
                Text("Keeping the same name makes this a per-project override: in this project Claude uses THIS entry instead of the user-scope one (local > project > user — the whole entry wins, nothing merges). Adjust the project-specific bits below, e.g. a Supabase project_ref.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Transport", systemImage: "antenna.radiowaves.left.and.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: $selectedType) {
                ForEach(TransportType.allCases, id: \.self) { type in
                    Text(type.label).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var transportFields: some View {
        switch draft.transport {
        case .stdio(let cmd, let args):
            stdioFields(command: cmd, args: args)
        case .http(let url):
            urlField(label: "URL", url: url) { newURL in
                draft.transport = .http(url: newURL)
            }
        case .sse(let url):
            urlField(label: "URL", url: url) { newURL in
                draft.transport = .sse(url: newURL)
            }
        default:
            EmptyView()
        }
    }

    private func stdioFields(command: String, args: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Command", systemImage: "terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("e.g. npx", text: Binding(
                    get: { command },
                    set: { new in
                        if case .stdio(_, let a) = draft.transport {
                            draft.transport = .stdio(command: new, args: a)
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Arguments", systemImage: "list.bullet")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        if case .stdio(let c, var a) = draft.transport {
                            a.append("")
                            draft.transport = .stdio(command: c, args: a)
                        }
                    } label: {
                        Label("Add", systemImage: "plus.circle").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(args.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        TextField("", text: Binding(
                            get: { args[safe: index] ?? "" },
                            set: { new in
                                if case .stdio(let c, var a) = draft.transport, index < a.count {
                                    a[index] = new
                                    draft.transport = .stdio(command: c, args: a)
                                }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Button {
                            if case .stdio(let c, var a) = draft.transport, index < a.count {
                                a.remove(at: index)
                                draft.transport = .stdio(command: c, args: a)
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func urlField(label: String, url: String, set: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: "link")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("https://…", text: Binding(get: { url }, set: set))
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var envEditor: some View {
        // Env vars: stdio only. Headers: http/sse only. Both use the shared
        // KeyValueEditor — same masking, same add/remove, different label
        // and add-key prefix.
        switch draft.transport {
        case .stdio:
            KeyValueEditor(
                entries: $draft.env,
                title: "Environment Variables",
                icon: "lock",
                addPlaceholder: "ENV_VAR"
            )
        case .http, .sse:
            KeyValueEditor(
                entries: $draft.headers,
                title: "Headers",
                icon: "doc.text",
                addPlaceholder: "X-Custom-Header",
                emptyHint: "No custom headers. Add one if your MCP server needs a Bearer token or API key.",
                secretsNote: "Header values containing 'Authorization', 'Bearer', 'Token' or 'Key' are masked by default."
            )
        default:
            EmptyView()
        }
    }

    /// Disclosure group for pre-configured OAuth — only relevant for http /
    /// sse transports, and only for the small fraction of MCP servers that
    /// don't support Dynamic Client Registration. Hidden behind a
    /// disclosure so the common case (no OAuth config) doesn't get a
    /// wall of empty fields.
    @ViewBuilder
    private var advancedAuthSection: some View {
        switch draft.transport {
        case .http, .sse:
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Most servers don't need any of this. Fill in only if your MCP server's docs tell you to.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    oauthField(
                        label: "Client ID",
                        text: Binding(
                            get: { draft.oauth.clientId ?? "" },
                            set: { draft.oauth.clientId = $0.isEmpty ? nil : $0 }
                        ),
                        placeholder: "e.g. cli_abc123"
                    )
                    oauthField(
                        label: "Callback port",
                        text: Binding(
                            get: { draft.oauth.callbackPort.map(String.init) ?? "" },
                            set: { draft.oauth.callbackPort = Int($0) }
                        ),
                        placeholder: "e.g. 8080 (1-65535)"
                    )
                    oauthField(
                        label: "Scopes",
                        text: Binding(
                            get: { draft.oauth.scopes ?? "" },
                            set: { draft.oauth.scopes = $0.isEmpty ? nil : $0 }
                        ),
                        placeholder: "e.g. channels:read chat:write"
                    )
                    oauthField(
                        label: "Auth-server metadata URL",
                        text: Binding(
                            get: { draft.oauth.authServerMetadataUrl ?? "" },
                            set: { draft.oauth.authServerMetadataUrl = $0.isEmpty ? nil : $0 }
                        ),
                        placeholder: "https://auth.example.com/.well-known/…"
                    )
                }
                .padding(.top, 8)
            } label: {
                Label("Advanced auth (optional)", systemImage: "key")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    private func oauthField(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(.tertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// Disclosure group for the two transport-agnostic knobs Claude Code
    /// exposes per server: `alwaysLoad` (skip Tool Search deferral) and
    /// `timeout` (per-server tool-call wall-clock limit). Both are advanced
    /// — the safe defaults are "don't set."
    private var advancedServerOptionsSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $draft.alwaysLoad) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Always load this server's tools at startup")
                            .font(.system(size: 12))
                        Text("Keeps tools in context every turn. Use only for a server you genuinely need on every prompt — costs context window space.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)

                VStack(alignment: .leading, spacing: 4) {
                    Text("TOOL CALL TIMEOUT (seconds)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(.tertiary)
                    TextField("default: 60", text: Binding(
                        get: {
                            // Show seconds in the UI; writer emits milliseconds.
                            draft.timeoutMs.map { String($0 / 1000) } ?? ""
                        },
                        set: { newValue in
                            if let seconds = Int(newValue), seconds > 0 {
                                draft.timeoutMs = seconds * 1000
                            } else {
                                draft.timeoutMs = nil
                            }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Text("Per-server hard limit on any one tool call. Min 1 second. Leave blank for Claude's default (60s).")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Advanced server options", systemImage: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Scope", systemImage: "folder")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("", selection: Binding(
                get: { scope.stableKey },
                set: { newTag in
                    if let resolved = MCPEditor.parseScopeTag(newTag) {
                        scope = resolved
                    }
                }
            )) {
                Text("User — all your projects (~/.claude.json)").tag("user")
                ForEach(store.projects, id: \.cwd) { project in
                    Text("Local: \(project.displayName) (private to you)").tag("local:\(project.cwd)")
                }
                ForEach(store.projects, id: \.cwd) { project in
                    Text("Project: \(project.displayName) (shared via .mcp.json)").tag("project:\(project.cwd)")
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(isEditMode)
            .help(isEditMode ? "Scope can't change in edit mode — delete and re-add to move" : "")

            // Plain-language hint clarifying what each scope does.
            Text(scopeHint)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scopeHint: String {
        switch scope {
        case .user:
            return "Available in every project, only to you."
        case .local:
            return "Available only in this project, only to you. This is what `claude mcp add` does by default."
        case .project:
            return "Available to anyone who clones this repo. Commits to .mcp.json."
        }
    }

    /// Parse a Picker tag (matches `Scope.stableKey`) back into a Scope.
    /// Returns nil for unrecognized tags rather than crashing — the Picker
    /// shouldn't ever emit those but we'd rather no-op than misclassify.
    fileprivate static func parseScopeTag(_ tag: String) -> MCPConfigWriter.Scope? {
        if tag == "user" { return .user }
        if let cwd = tag.stripPrefix("local:")   { return .local(cwd: cwd) }
        if let cwd = tag.stripPrefix("project:") { return .project(cwd: cwd) }
        return nil
    }

    // MARK: - Save

    /// env/header entries that look like literal secrets: key smells like a
    /// credential, value is non-empty and NOT a `${VAR}` reference (env
    /// expansion is the git-safe way to put secrets in a committed file —
    /// both Claude Code and Atelier's MCPEnvExpand resolve it at load).
    private var literalSecrets: [String] {
        let pattern = try? NSRegularExpression(
            pattern: "(?i)(token|secret|password|passwd|credential|api.?key|access.?key|private.?key|authorization|bearer)"
        )
        func smells(_ key: String) -> Bool {
            guard let pattern else { return false }
            return pattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
        }
        var out: [String] = []
        for (k, v) in draft.env where smells(k) && !v.isEmpty && !v.contains("${") { out.append(k) }
        for (k, v) in draft.headers where smells(k) && !v.isEmpty && !v.contains("${") { out.append(k) }
        return out.sorted()
    }

    private func save() {
        // Guard against double-invocation (rapid clicks, keyboard repeat)
        guard !isSaving else { return }

        // Validate the advanced fields before kicking off the disk write.
        // Surfaces a single clear error rather than letting Claude reject
        // a malformed config later at connect time.
        if let validationError = validateAdvancedFields() {
            errorMessage = validationError
            return
        }

        // Secret guardrail: project scope writes .mcp.json, which is meant
        // to be committed. A literal token in there ends up in git history.
        // The dialog's buttons call performSave() directly (bypassing this
        // gate — SwiftUI flips isPresented false BEFORE the button action
        // runs, so re-entering save() here would just re-arm the dialog);
        // "save anyway" stays available since some teams knowingly put
        // throwaway/dev tokens in .mcp.json.
        if case .project = scope, !literalSecrets.isEmpty {
            showSecretWarning = true
            return
        }

        performSave()
    }

    /// The actual write — past validation and the secret gate.
    /// `overrideScope` lets the guardrail dialog redirect a risky
    /// project-scope save to local scope in one tap.
    private func performSave(overrideScope: MCPConfigWriter.Scope? = nil) {
        if let overrideScope { scope = overrideScope }
        isSaving = true
        errorMessage = nil
        let currentDraft = draft
        let currentScope = overrideScope ?? scope
        let original = originalName

        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try MCPConfigWriter.save(currentDraft, scope: currentScope, originalName: original)
                }.value

                await store.reloadMCPs()
                onSaved()
                dismiss()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }

    /// The project-scope cwd while the secret warning is up (the dialog's
    /// "keep it private" button retargets the save there as local scope).
    private var warningLocalScope: MCPConfigWriter.Scope? {
        if case .project(let cwd) = scope { return .local(cwd: cwd) }
        return nil
    }

    /// Cross-field validation for the Phase-1D / 1E advanced sections.
    /// Returns the first error message, or nil if everything checks out.
    private func validateAdvancedFields() -> String? {
        // OAuth: callbackPort must be a real TCP port if set.
        if let port = draft.oauth.callbackPort, !(1...65535).contains(port) {
            return "OAuth callback port must be between 1 and 65535."
        }
        // OAuth: metadata URL must use https.
        if let url = draft.oauth.authServerMetadataUrl, !url.isEmpty,
           !url.lowercased().hasPrefix("https://") {
            return "OAuth metadata URL must start with https://"
        }
        // Timeout: positive milliseconds. (UI collected seconds, writer
        // already multiplied; this guards the unhappy path where someone
        // typed 0 or a non-numeric value that became nil.)
        if let ms = draft.timeoutMs, ms <= 0 {
            return "Timeout must be a positive number of seconds."
        }
        return nil
    }
}

// (EnvVarsEditor was removed in Phase 1C — its UI is now provided by the
// shared `KeyValueEditor` in `Sources/KeyValueEditor.swift`, which serves
// both env vars and HTTP headers.)

// MARK: - Array safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - String prefix helper

private extension String {
    /// Returns the substring after `prefix` if `self` starts with it, else nil.
    /// Used by `MCPEditor.parseScopeTag` to peel `"local:" / "project:"` apart
    /// from the cwd that follows.
    func stripPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

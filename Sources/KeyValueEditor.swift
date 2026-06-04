import SwiftUI

/// Reusable key/value pair editor with secret detection + masked reveal.
/// Extracted from the original `EnvVarsEditor` so MCP environment variables
/// AND HTTP headers can share the same UI affordances (add row, edit key,
/// secret masking, eye toggle, delete row).
///
/// Two callers in the MCP editor:
/// - **Env vars** (stdio MCPs): `title = "Environment Variables"`,
///   `addPlaceholder = "ENV_VAR"`, `icon = "lock"`
/// - **Headers** (http/sse MCPs): `title = "Headers"`,
///   `addPlaceholder = "X-Custom-Header"`, `icon = "doc.text"`
struct KeyValueEditor: View {
    @Binding var entries: [String: String]
    var title: String
    var icon: String = "lock"
    /// Prefix used when generating a fresh key on "Add". The editor appends
    /// `_1`, `_2`, … until a free slot is found, matching the old behavior.
    var addPlaceholder: String = "KEY"
    /// Helper text shown under the title when the editor is empty.
    var emptyHint: String = "None"
    /// Secondary helper text shown under the rows when at least one row
    /// exists. Defaults to the original "masked by default" warning.
    var secretsNote: String = "Secret values are masked by default. Be careful revealing them on shared screens."

    @State private var revealed: Set<String> = []

    private var keys: [String] { entries.keys.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    var i = 1
                    while entries["\(addPlaceholder)_\(i)"] != nil { i += 1 }
                    entries["\(addPlaceholder)_\(i)"] = ""
                } label: {
                    Label("Add", systemImage: "plus.circle").labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
            }

            if entries.isEmpty {
                Text(emptyHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            } else {
                ForEach(keys, id: \.self) { key in
                    row(key: key)
                }
                Text(secretsNote)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
    }

    private func row(key: String) -> some View {
        let isSecret = SecretDetection.isSecretKey(key)
        let isRevealed = revealed.contains(key)
        return HStack(spacing: 6) {
            TextField("KEY", text: Binding(
                get: { key },
                set: { newKey in
                    guard newKey != key, !newKey.isEmpty, entries[newKey] == nil else { return }
                    let value = entries[key] ?? ""
                    entries.removeValue(forKey: key)
                    entries[newKey] = value
                    if revealed.contains(key) {
                        revealed.remove(key)
                        revealed.insert(newKey)
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 180)

            if isSecret && !isRevealed {
                SecureField("value", text: Binding(
                    get: { entries[key] ?? "" },
                    set: { entries[key] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            } else {
                TextField("value", text: Binding(
                    get: { entries[key] ?? "" },
                    set: { entries[key] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }

            if isSecret {
                Button {
                    if isRevealed { revealed.remove(key) } else { revealed.insert(key) }
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Button {
                entries.removeValue(forKey: key)
                revealed.remove(key)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

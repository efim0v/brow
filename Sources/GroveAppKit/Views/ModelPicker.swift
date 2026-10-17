import SwiftUI
import GroveCore

/// The model a launch uses: "(default)", Claude Code's aliases, a pinned id, or any
/// other id typed in ("Other…"). A value the lists do not know — typed earlier, or
/// written by another build — is shown as it is rather than as a blank picker.
struct ModelPicker: View {
    @Binding var model: String?
    var size: ControlSize = .regular
    @State private var typing = false
    @State private var typed = ""

    private enum Choice: Hashable {
        case automatic
        case id(String)
        case other
    }

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: choice) {
                Text("(default)").tag(Choice.automatic)
                Section("Latest of each") {
                    ForEach(ModelCatalog.aliases, id: \.self) { Text($0).tag(Choice.id($0)) }
                }
                Section("A specific version") {
                    ForEach(ModelCatalog.knownModels, id: \.self) { Text($0).tag(Choice.id($0)) }
                }
                if let model, ModelCatalog.isCustom(model) {
                    Text(model).tag(Choice.id(model))
                }
                Divider()
                Text("Other…").tag(Choice.other)
            }
            .pickerStyle(.menu).labelsHidden().controlSize(size).fixedSize()
            if typing {
                TextField("model id", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .controlSize(size)
                    .frame(width: 150)
                    .onSubmit(commit)
                Button("Use", action: commit)
                    .controlSize(size)
                    .disabled(ModelCatalog.customID(typed) == nil)
            }
        }
    }

    private var choice: Binding<Choice> {
        Binding(
            get: { typing ? .other : (model.map(Choice.id) ?? .automatic) },
            set: { picked in
                switch picked {
                case .automatic: typing = false; model = nil
                case .id(let id): typing = false; model = id
                case .other: typed = model ?? ""; typing = true
                }
            })
    }

    private func commit() {
        guard let id = ModelCatalog.customID(typed) else { return }
        model = id
        typing = false
    }
}

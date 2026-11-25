import SwiftUI

struct ScriptEditor: View {
    let library: ScriptLibrary
    @State var draft: ScriptEntry
    let isNew: Bool
    let chooseScript: () -> URL?
    let finish: () -> Void

    @State private var error: String?
    @State private var confirmRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            PanelScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error { PanelMessage(text: error, isError: true) }
                    TextField("别名", text: $draft.alias)
                    HStack {
                        Text(draft.path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).help(draft.path)
                        Spacer()
                        Button("更换路径…") {
                            if let url = chooseScript() { draft.path = url.path }
                        }
                    }
                    Picker("分类", selection: $draft.categoryID) {
                        Text(ScriptLibrary.uncategorized).tag(nil as UUID?)
                        ForEach(library.contents.categories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                    Toggle("无参数启动时显示 Terminal", isOn: $draft.showsTerminal)
                    Toggle("允许在日志面板输入", isOn: $draft.acceptsInput)
                        .help("下次后台启动时生效。")
                    Toggle("多路输出", isOn: $draft.usesMultipleLogs)
                    if draft.usesMultipleLogs {
                        Text("脚本将各路日志写到 $BKQUICKRUN_LOG_DIR 下，文件名与下方配置一致。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach($draft.logSources) { $source in
                            let id = source.id
                            HStack {
                                TextField("标签（如前端）", text: $source.name)
                                TextField("文件名（如 frontend.log）", text: $source.fileName)
                                Button("移除日志来源", systemImage: "minus.circle") {
                                    draft.logSources.removeAll { $0.id == id }
                                }
                                .labelStyle(.iconOnly)
                            }
                        }
                        Button("添加日志来源", systemImage: "plus") {
                            draft.logSources.append(ScriptLogSource())
                        }
                        .controlSize(.small)
                    }
                    HStack {
                        Text("启动变体").font(.headline)
                        Spacer()
                        Button("添加变体", systemImage: "plus") {
                            draft.variants.append(LaunchVariant())
                        }
                    }
                    .padding(.top, 4)
                    Text("带参数的变体在后台运行，可在面板停止。每一行是一个参数，按顺序传入。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(draft.variants) { variant in
                        VariantEditor(variant: binding(for: variant)) {
                            draft.variants.removeAll { $0.id == variant.id }
                        }
                    }
                }
                .padding(12)
            }
            HStack {
                if !isNew {
                    if confirmRemoval {
                        Button("确认移除记录", role: .destructive) { apply { try library.removeScript(draft.id) } }
                    } else {
                        Button("移除脚本…", role: .destructive) { confirmRemoval = true }
                            .help("仅移除应用中的记录，保留脚本文件。")
                    }
                }
                Spacer()
                Button("取消") {
                    if confirmRemoval { confirmRemoval = false } else { finish() }
                }
                Button("保存") { apply { try library.saveScript(draft) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmRemoval)
            }
            .padding(10)
        }
    }

    private func binding(for variant: LaunchVariant) -> Binding<LaunchVariant> {
        Binding(
            get: { draft.variants.first { $0.id == variant.id } ?? variant },
            set: { updated in
                guard let index = draft.variants.firstIndex(where: { $0.id == variant.id }) else { return }
                draft.variants[index] = updated
            }
        )
    }

    private func apply(_ change: () throws -> Void) {
        do {
            try change()
            finish()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct VariantEditor: View {
    @Binding var variant: LaunchVariant
    let remove: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("变体名称", text: $variant.name)
                    Button("移除变体", systemImage: "trash", action: remove)
                        .labelStyle(.iconOnly)
                        .help("移除变体")
                }
                ForEach(variant.arguments.indices, id: \.self) { index in
                    HStack {
                        TextField("参数 \(index + 1)", text: argument(at: index))
                        Button("移除参数 \(index + 1)", systemImage: "minus.circle") {
                            variant.arguments.remove(at: index)
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                Button("添加参数", systemImage: "plus") { variant.arguments.append("") }
                    .controlSize(.small)
            }
            .padding(3)
        }
    }

    private func argument(at index: Int) -> Binding<String> {
        Binding(
            get: { variant.arguments.indices.contains(index) ? variant.arguments[index] : "" },
            set: { value in
                guard variant.arguments.indices.contains(index) else { return }
                variant.arguments[index] = value
            }
        )
    }
}

struct CategoryEditor: View {
    let library: ScriptLibrary
    @State var draft: ScriptCategory
    let isNew: Bool
    let finish: () -> Void

    @State private var error: String?
    @State private var confirmRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            PanelScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let error { PanelMessage(text: error, isError: true) }
                    TextField("分类名称", text: $draft.name)
                    if confirmRemoval {
                        Text("此分类中的脚本会移回「未分类」。")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }
            HStack {
                if !isNew {
                    if confirmRemoval {
                        Button("确认删除分类", role: .destructive) { apply { try library.removeCategory(draft.id) } }
                    } else {
                        Button("删除分类…", role: .destructive) { confirmRemoval = true }
                    }
                }
                Spacer()
                Button("取消") {
                    if confirmRemoval { confirmRemoval = false } else { finish() }
                }
                Button("保存") { apply { try library.saveCategory(draft) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmRemoval)
            }
            .padding(10)
        }
    }

    private func apply(_ change: () throws -> Void) {
        do {
            try change()
            finish()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

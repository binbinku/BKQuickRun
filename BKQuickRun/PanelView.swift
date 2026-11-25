import AppKit
import SwiftUI

@MainActor
final class PanelPresentation: ObservableObject {
    static let launcherWidth: CGFloat = 430
    static let paneSpacing: CGFloat = 4

    enum Route {
        case launcher, help, manage, script(ScriptEntry, isNew: Bool), category(ScriptCategory, isNew: Bool)
    }

    @Published var route: Route = .launcher
    @Published var selection: ScriptRunID?
    @Published var availableSize = NSSize(width: PanelPresentation.launcherWidth, height: 390)

    var preferredWidth: CGFloat {
        if case .help = route { return 610 }
        return selection == nil ? Self.launcherWidth : Self.launcherWidth + Self.paneSpacing + 627
    }
}

struct PanelView: View {
    @ObservedObject var library: ScriptLibrary
    @ObservedObject var scriptRuns: ScriptRuns
    @ObservedObject var presentation: PanelPresentation
    let chooseScript: () -> URL?
    let closePanel: () -> Void
    let resizePanel: (CGFloat?) -> Void

    @State private var notice: String?
    @State private var failure: String?
    @State private var collapsedGroups: Set<LauncherGroup> = []

    private enum LauncherGroup: Hashable {
        case category(UUID?)
        case variants(UUID)
    }

    var body: some View {
        PanelLayout(availableSize: presentation.availableSize) {
            VStack(spacing: 0) {
                header.zIndex(1)
                switch presentation.route {
                case .launcher:
                    feedback
                    launcherContent
                case .help:
                    helpContent
                case .manage:
                    feedback
                    management
                case let .script(entry, isNew):
                    ScriptEditor(library: library, draft: entry, isNew: isNew, chooseScript: chooseScript) {
                        navigate(to: .manage)
                    }
                    .id(entry.id)
                case let .category(category, isNew):
                    CategoryEditor(library: library, draft: category, isNew: isNew) {
                        navigate(to: .manage)
                    }
                    .id(category.id)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resizePanel($0) }
        .onChange(of: presentation.preferredWidth) { _, _ in resizePanel(nil) }
    }

    private var header: some View {
        HStack(spacing: 9) {
            if case .launcher = presentation.route {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.tint)
                    .font(.title2)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer()
            if case .launcher = presentation.route {
                HeaderIconButton(title: "帮助", symbol: "questionmark.circle") { navigate(to: .help) }
                HeaderIconButton(title: "同步配置", symbol: "arrow.clockwise", action: sync)
                HeaderIconButton(title: "复制配置路径", symbol: "doc.on.doc", action: copyPath)
                HeaderIconButton(title: "管理", symbol: "gearshape") { navigate(to: .manage) }
                HeaderIconButton(title: "退出", symbol: "rectangle.portrait.and.arrow.right") { NSApp.terminate(nil) }
            } else if case .manage = presentation.route {
                HeaderIconButton(title: "在访达中显示配置", symbol: "folder", action: revealConfiguration)
                HeaderIconButton(title: "返回", symbol: "arrow.left") { navigate(to: .launcher) }
            } else if case .help = presentation.route {
                HeaderIconButton(title: "返回", symbol: "arrow.left") { navigate(to: .launcher) }
            }
        }
        .padding(12)
    }

    private var title: String {
        switch presentation.route {
        case .launcher: "BKQuickRun"
        case .help: "使用说明"
        case .manage: "管理脚本和分类"
        case .script(_, true): "添加脚本"
        case .script: "编辑脚本"
        case .category(_, true): "添加分类"
        case .category: "编辑分类"
        }
    }

    private var helpContent: some View {
        PanelScrollView {
            VStack(alignment: .leading, spacing: 16) {
                helpTopic("添加脚本与变体", "在「管理」里选择 .sh 文件，再设置别名和分类。一个脚本可以添加多个启动变体，每行输入一个参数。启动列表左侧的箭头可以折叠分类和变体。")
                helpTopic("启动、停止与输出", "点绿色三角启动，点红色方块停止。行首的圆点或折叠箭头用灰色表示未运行，绿色表示运行中。点击运行中的脚本名称可查看输出。关闭并重新打开菜单栏面板会回到启动列表。")
                helpTopic("Terminal 与后台运行", "启用「无参数启动时显示 Terminal」后，无参数启动会打开 Terminal，可在里面输入。带参数的变体始终在后台运行。")
                helpTopic("在日志面板输入", "在脚本设置中开启「允许在日志面板输入」。下次后台运行时，按回车或点击「发送」即可向脚本输入一行。")
                helpTopic("多路输出", "在脚本设置中开启「多路输出」，为每路日志填写标签和文件名。脚本将日志写到 $BKQUICKRUN_LOG_DIR 下，输出面板会按标签显示。")
                helpTopic("用 AI 编辑配置", "点「复制配置路径」图标，把 JSON 路径交给 AI。修改完成后，点「同步配置」图标重新加载。")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func helpTopic(_ heading: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(heading).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var launcherContent: some View {
        if let selection = presentation.selection {
            let width = presentation.availableSize.width
            if width >= 580 {
                HStack(alignment: .top, spacing: PanelPresentation.paneSpacing) {
                    launcher(trailingPadding: 4).frame(width: min(PanelPresentation.launcherWidth, width * 0.5))
                    outputPane(selection)
                }
            } else {
                VStack(spacing: PanelPresentation.paneSpacing) {
                    launcher()
                    outputPane(selection)
                }
            }
        } else {
            launcher()
        }
    }

    private func outputPane(_ selection: ScriptRunID) -> some View {
        let run = scriptRuns.runs[selection]
        return ScriptOutputPane(run: run, sendInput: { line in
            guard let run else { throw AppError("这次运行已无法接收输入。") }
            try await scriptRuns.sendInput(line, to: selection, files: run.files)
        }) {
            presentation.selection = nil
        }
        .id(run?.files.directory)
    }

    private func launcher(trailingPadding: CGFloat = 12) -> some View {
        let unlistedRuns = scriptRuns.activeRuns.filter { run in
            !library.contents.scripts.contains { script in
                guard script.id == run.id.script else { return false }
                guard let variantID = run.id.variant else { return true }
                return script.variants.contains { $0.id == variantID }
            }
        }
        return PanelScrollView(showsScrollIndicators: false) {
            if library.contents.scripts.isEmpty && unlistedRuns.isEmpty {
                ContentUnavailableView("还没有脚本", systemImage: "terminal", description: Text("在「管理」中添加 .sh 文件。"))
                    .padding(.vertical, 28)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if !unlistedRuns.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("已从配置移除的运行项").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(unlistedRuns) { run in
                                scriptRow(run.name, id: run.id) { toggleRun(run.id) }
                            }
                        }
                    }
                    ForEach(library.contents.categories) { category in
                        scriptGroup(category.name, id: category.id)
                    }
                    scriptGroup(ScriptLibrary.uncategorized, id: nil)
                }
                .padding([.top, .leading, .bottom], 12)
                .padding(.trailing, trailingPadding)
            }
        }
    }

    @ViewBuilder
    private func scriptGroup(_ title: String, id: UUID?) -> some View {
        let scripts = library.contents.scripts.filter { $0.categoryID == id }
        let group = LauncherGroup.category(id)
        let expanded = !collapsedGroups.contains(group)
        if !scripts.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    toggleDisclosure(group)
                } label: {
                    HStack(spacing: 5) {
                        disclosureArrow(expanded: expanded)
                        Text(title).font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "折叠分类 \(title)" : "展开分类 \(title)")
                if expanded {
                    ForEach(scripts) { script in
                        scriptButton(script)
                        if !collapsedGroups.contains(.variants(script.id)) {
                            ForEach(script.variants) { variant in
                                scriptButton(script, variant: variant).padding(.leading, 20)
                            }
                        }
                    }
                }
            }
        }
    }

    private func scriptButton(_ script: ScriptEntry, variant: LaunchVariant? = nil) -> some View {
        let id = ScriptRunID(script: script.id, variant: variant?.id)
        let name = variant?.name ?? script.alias
        let fullName = variant.map { "\(script.alias) · \($0.name)" } ?? script.alias
        let group: LauncherGroup? = variant == nil && !script.variants.isEmpty ? .variants(script.id) : nil
        return scriptRow(name, id: id, help: script.path, group: group) {
            toggleRun(id) {
                try scriptRuns.start(id: id, name: fullName, path: script.path, arguments: variant?.arguments ?? [],
                                     inTerminal: script.usesTerminal(for: variant),
                                     logSources: script.usesMultipleLogs ? script.logSources : [],
                                     acceptsInput: script.acceptsInput)
            }
        }
    }

    private func scriptRow(
        _ name: String, id: ScriptRunID, help: String? = nil,
        group: LauncherGroup? = nil, action: @escaping () -> Void
    ) -> some View {
        let status = scriptRuns.runs[id]?.status
        let canShowOutput = status == .running
        let isStopAction = status == .running || status == .stopping
        let busy = status == .starting || status == .stopping
        let actionTitle = busy ? (status?.label ?? "启动中") : (isStopAction ? "停止" : "启动")
        return HStack(spacing: 6) {
            if let group {
                let expanded = !collapsedGroups.contains(group)
                Button {
                    toggleDisclosure(group)
                } label: {
                    statusIndicator(expanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill", status: status)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "折叠 \(name) 的变体" : "展开 \(name) 的变体")
                .accessibilityValue(status?.label ?? "未启动")
            } else {
                statusIndicator("circle.fill", status: status)
                    .accessibilityHidden(true)
            }
            Button {
                guard scriptRuns.runs[id]?.status == .running else { return }
                presentation.selection = id
            } label: {
                HStack(spacing: 7) {
                    Text(name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canShowOutput)
            .accessibilityLabel(name)
            .accessibilityValue(status?.label ?? "未启动")
            .accessibilityHint(canShowOutput ? "查看运行输出" : "")
            .help(help ?? (canShowOutput ? "查看运行输出" : ""))

            Button(action: action) {
                Image(systemName: isStopAction ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isStopAction ? Color.red : Color.green)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .opacity(busy ? 0.5 : 1)
            .help(actionTitle)
            .accessibilityLabel("\(actionTitle) \(name)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(presentation.selection == id ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 5))
    }

    private func disclosureArrow(expanded: Bool) -> some View {
        Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 12)
            .accessibilityHidden(true)
    }

    private func toggleDisclosure(_ group: LauncherGroup) {
        if collapsedGroups.remove(group) == nil { collapsedGroups.insert(group) }
    }

    private func statusColor(_ status: ScriptRunStatus?) -> Color {
        switch status {
        case .running: .green
        case .starting, .stopping: .orange
        case .failed: .red
        default: .gray
        }
    }

    private func statusIndicator(_ symbol: String, status: ScriptRunStatus?) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(statusColor(status))
            .frame(width: 18, height: 24)
    }

    private var management: some View {
        PanelScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("脚本").font(.headline)
                    Spacer()
                    Button("添加脚本", systemImage: "plus", action: addScript)
                }
                if library.contents.scripts.isEmpty {
                    Text("还没有脚本").foregroundStyle(.secondary)
                }
                ForEach(library.contents.scripts) { script in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(script.alias).fontWeight(.medium)
                            Text(script.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(script.path)
                        }
                        Spacer()
                        Button("编辑") { navigate(to: .script(script, isNew: false)) }
                            .accessibilityLabel("编辑脚本 \(script.alias)")
                    }
                }
                HStack {
                    Text("分类").font(.headline)
                    Spacer()
                    Button("添加分类", systemImage: "plus") { navigate(to: .category(ScriptCategory(), isNew: true)) }
                }
                .padding(.top, 4)
                if library.contents.categories.isEmpty {
                    Text("脚本默认归入「未分类」。").foregroundStyle(.secondary)
                }
                ForEach(library.contents.categories) { category in
                    HStack {
                        Text(category.name)
                        Spacer()
                        Button("编辑") { navigate(to: .category(category, isNew: false)) }
                            .accessibilityLabel("编辑分类 \(category.name)")
                    }
                }
            }
            .disabled(library.loadError != nil)
            .padding(12)
        }
    }

    @ViewBuilder private var feedback: some View {
        if let message = failure ?? library.loadError {
            PanelMessage(text: message, isError: true)
                .lineLimit(3)
                .help(message)
                .padding([.horizontal, .top], 10)
        } else if let notice {
            PanelMessage(text: notice, isError: false)
                .padding([.horizontal, .top], 10)
        }
    }

    private func navigate(to destination: PanelPresentation.Route) {
        failure = nil
        notice = nil
        presentation.selection = nil
        presentation.route = destination
    }

    private func addScript() {
        guard let url = chooseScript() else { return }
        navigate(to: .script(ScriptEntry(path: url.path, alias: url.deletingPathExtension().lastPathComponent), isNew: true))
    }

    private func toggleRun(_ id: ScriptRunID, start: () throws -> Void = {}) {
        failure = nil
        notice = nil
        do {
            switch scriptRuns.runs[id]?.status {
            case .running: try scriptRuns.stop(id)
            case .starting, .stopping: return
            default: try start()
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func sync() {
        failure = nil
        notice = library.reload() ? "已同步配置。" : nil
    }

    private func copyPath() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(library.url.path, forType: .string) else {
            failure = "无法复制配置路径。"
            return
        }
        do {
            try library.prepareConfigurationFile()
            failure = nil
            notice = "已复制配置路径。"
        } catch {
            failure = "已复制配置路径。\(error.localizedDescription)"
        }
    }

    private func revealConfiguration() {
        do {
            try library.prepareConfigurationFile()
            closePanel()
            NSWorkspace.shared.activateFileViewerSelecting([library.url])
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct PanelLayout: Layout {
    let availableSize: NSSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews[0].sizeThatFits(ProposedViewSize(width: availableSize.width, height: nil))
        return NSSize(width: availableSize.width, height: min(availableSize.height, max(1, ceil(ideal.height))))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

struct PanelScrollView<Content: View>: View {
    var showsScrollIndicators = true
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 180
    @State private var viewportHeight: CGFloat = 180

    var body: some View {
        ScrollView {
            content()
                .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { contentHeight = $0 }
        }
        .scrollIndicators(showsScrollIndicators && contentHeight > viewportHeight + 0.5 ? .automatic : .hidden,
                          axes: .vertical)
        .frame(idealHeight: contentHeight, maxHeight: contentHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
    }
}

private struct HeaderIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    @State private var isHovered = false
    @State private var showsHint = false

    var body: some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .onHover { hovering in
                isHovered = hovering
                if !hovering { showsHint = false }
            }
            .task(id: isHovered) {
                guard isHovered else { return }
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                if isHovered { showsHint = true }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsHint {
                    Text(title)
                        .font(.caption)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .shadow(radius: 3, y: 1)
                        .alignmentGuide(.bottom) { _ in -5 }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .zIndex(showsHint ? 1 : 0)
    }
}

private struct ScriptOutputPane: View {
    let run: ScriptRuns.Run?
    let sendInput: @MainActor (String) async throws -> Void
    let close: () -> Void

    @State private var output = ""
    @State private var selectedLogID: UUID?
    @State private var input = ""
    @State private var inputError: String?
    @State private var isSubmitting = false

    private var selectedLog: ScriptLogSource? {
        run?.logSources.first { $0.id == selectedLogID } ?? run?.logSources.first
    }

    private var isLive: Bool {
        switch run?.status {
        case .starting, .running, .stopping: true
        default: false
        }
    }

    private struct Refresh: Equatable {
        let files: ScriptRunFiles?
        let source: ScriptLogSource?
        let isLive: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let run, !run.logSources.isEmpty {
                    logTabs(run.logSources)
                } else {
                    Spacer()
                }
                if let run {
                    Text(run.status.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .layoutPriority(1)
                }
                Button("关闭输出", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            logContent
            if let run, run.status == .running, run.inputState != .unavailable {
                HStack(spacing: 8) {
                    TextField(run.inputState == .closed ? "脚本已关闭输入" : "输入一行…", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("脚本输入")
                        .disabled(run.inputState == .closed)
                        .onSubmit(submitInput)
                    Button(isSubmitting ? "发送中…" : "发送", action: submitInput)
                        .disabled(isSubmitting || run.inputState != .ready)
                }
            }
            if let inputError {
                PanelMessage(text: inputError, isError: true)
            }
        }
        .padding([.horizontal, .bottom], 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: Refresh(files: run?.files, source: selectedLog, isLive: isLive)) {
            guard let files = run?.files else { output = ""; return }
            let source = selectedLog
            if !isLive {
                output = files.readOutput(source: source)
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                output = files.readOutput(source: source)
                return
            }
            while !Task.isCancelled {
                let latest = files.readOutput(source: source)
                if latest != output { output = latest }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { break }
            }
        }
    }

    private func submitInput() {
        guard run?.status == .running, run?.inputState == .ready, !isSubmitting else { return }
        let line = input
        inputError = nil
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                try await sendInput(line)
                if input == line { input = "" }
            } catch {
                inputError = error.localizedDescription
            }
        }
    }

    private var logContent: some View {
        Group {
            if output.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(maxWidth: .infinity)
                    .padding(12)
            } else {
                ScrollViewReader { proxy in
                    PanelScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: output)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.92))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("output-end")
                        }
                        .padding(10)
                    }
                    .onAppear { proxy.scrollTo("output-end", anchor: .bottom) }
                    .onChange(of: output) { _, _ in proxy.scrollTo("output-end", anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.15, green: 0.16, blue: 0.17), in: RoundedRectangle(cornerRadius: 8))
        .environment(\.colorScheme, .dark)
    }

    private func logTabs(_ sources: [ScriptLogSource]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(sources) { source in
                    let isSelected = source.id == selectedLog?.id
                    let button = Button {
                        guard !isSelected else { return }
                        selectedLogID = source.id
                        output = ""
                    } label: {
                        Label(source.name, systemImage: "terminal")
                            .labelStyle(.titleAndIcon)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                    }
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    if isSelected {
                        button.buttonStyle(.borderedProminent)
                    } else {
                        button.buttonStyle(.bordered)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyMessage: String {
        switch run?.status {
        case nil: "启动后将在这里显示输出。"
        case .starting, .running, .stopping: "等待脚本输出…"
        case .failed(let reason): reason
        default: "本次运行没有输出。"
        }
    }
}

struct PanelMessage: View {
    let text: String
    let isError: Bool

    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(isError ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

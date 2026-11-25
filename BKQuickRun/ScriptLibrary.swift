import Foundation
import Combine

struct LaunchVariant: Codable, Identifiable {
    var id = UUID()
    var name = ""
    var arguments: [String] = []
}

struct ScriptLogSource: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var fileName = ""
}

struct ScriptEntry: Codable, Identifiable {
    var id = UUID()
    var path: String
    var alias: String
    var categoryID: UUID?
    var showsTerminal = true
    var acceptsInput = false
    var usesMultipleLogs = false
    var logSources: [ScriptLogSource] = []
    var variants: [LaunchVariant] = []

    init(path: String = "", alias: String = "", categoryID: UUID? = nil) {
        self.path = path
        self.alias = alias
        self.categoryID = categoryID
    }

    func usesTerminal(for variant: LaunchVariant?) -> Bool {
        showsTerminal && (variant?.arguments.isEmpty ?? true)
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, alias, categoryID, showsTerminal, acceptsInput, variants, usesMultipleLogs, logSources
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        path = try values.decode(String.self, forKey: .path)
        alias = try values.decode(String.self, forKey: .alias)
        categoryID = try values.decodeIfPresent(UUID.self, forKey: .categoryID)
        showsTerminal = try values.decodeIfPresent(Bool.self, forKey: .showsTerminal) ?? true
        acceptsInput = try values.decodeIfPresent(Bool.self, forKey: .acceptsInput) ?? false
        variants = try values.decodeIfPresent([LaunchVariant].self, forKey: .variants) ?? []
        usesMultipleLogs = try values.decodeIfPresent(Bool.self, forKey: .usesMultipleLogs) ?? false
        logSources = try values.decodeIfPresent([ScriptLogSource].self, forKey: .logSources) ?? []
    }
}

struct ScriptCategory: Codable, Identifiable {
    var id = UUID()
    var name = ""
}

struct LibraryContents: Codable {
    var scripts: [ScriptEntry] = []
    var categories: [ScriptCategory] = []
    private static let multiOutputHelp = [
        "在 scripts 中找到要修改的脚本，把 usesMultipleLogs 设为 true，并在该脚本的 logSources 数组中为每路输出添加一项。",
        "每项需要 id（独立的 UUID）、name（输出标签）和 fileName（文件名，如 frontend.log）。同一脚本内的标签和文件名应各自唯一，文件名只填写名称，不带目录。",
        "将下列示例的两个字段加入已有脚本条目。",
        #"{"usesMultipleLogs":true,"logSources":[{"id":"A5186382-199E-4C64-A6A6-A393CA63FE13","name":"前端","fileName":"frontend.log"},{"id":"80DA8D80-1832-4518-95C5-56861D6E3292","name":"后端","fileName":"backend.log"}]}"#,
        #"开启多路输出后，BKQuickRun 会为每次运行设置 BKQUICKRUN_LOG_DIR。请让脚本把各路输出写到该目录中，例如前端命令 > "$BKQUICKRUN_LOG_DIR/frontend.log" 2>&1。"#,
        "usesMultipleLogs 省略或设为 false 时，继续显示脚本的标准输出和标准错误。编辑配置文件后，在 BKQuickRun 中点「同步配置」。"
    ]

    private enum OutputKeys: String, CodingKey {
        case scripts, categories, multiOutputHelp
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: OutputKeys.self)
        try values.encode(scripts, forKey: .scripts)
        try values.encode(categories, forKey: .categories)
        try values.encode(Self.multiOutputHelp, forKey: .multiOutputHelp)
    }
}

struct AppError: LocalizedError {
    var errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

@MainActor
final class ScriptLibrary: ObservableObject {
    static let uncategorized = "未分类"
    static let configurationDirectory = URL.applicationSupportDirectory
        .appending(path: "BKQuickRun", directoryHint: .isDirectory)

    @Published private(set) var contents = LibraryContents()
    @Published private(set) var loadError: String?
    let url: URL
    private var loadedData: Data?

    init(url: URL = configurationDirectory.appending(path: "library.json", directoryHint: .notDirectory)) {
        self.url = url
        reload()
    }

    @discardableResult
    func reload() -> Bool {
        do {
            let data = try readData()
            if data == nil, loadedData != nil {
                throw AppError("找不到配置文件。")
            }
            let updated = try data.map { try JSONDecoder().decode(LibraryContents.self, from: $0) } ?? LibraryContents()
            try validate(updated)
            contents = updated
            loadedData = data
            loadError = nil
            return true
        } catch {
            loadError = "无法读取脚本配置（\(error.localizedDescription)）。请检查配置文件后重试。"
            return false
        }
    }

    func saveScript(_ script: ScriptEntry) throws {
        var draft = script
        draft.alias = draft.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.alias.isEmpty else { throw AppError("请输入脚本别名。") }
        for index in draft.variants.indices {
            draft.variants[index].name = draft.variants[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for index in draft.logSources.indices {
            draft.logSources[index].name = draft.logSources[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.logSources[index].fileName = draft.logSources[index].fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if contents.scripts.first(where: { $0.id == draft.id })?.path != draft.path {
            _ = try ScriptFile.validate(draft.path)
        }

        try update { updated in
            if let index = updated.scripts.firstIndex(where: { $0.id == draft.id }) {
                updated.scripts[index] = draft
            } else {
                updated.scripts.append(draft)
            }
        }
    }

    func removeScript(_ id: UUID) throws {
        try update { $0.scripts.removeAll { $0.id == id } }
    }

    func saveCategory(_ category: ScriptCategory) throws {
        var draft = category
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.name.isEmpty else { throw AppError("请输入分类名称。") }
        guard draft.name != Self.uncategorized,
              !contents.categories.contains(where: { $0.id != draft.id && $0.name == draft.name }) else {
            throw AppError("已存在同名分类。")
        }

        try update { updated in
            if let index = updated.categories.firstIndex(where: { $0.id == draft.id }) {
                updated.categories[index] = draft
            } else {
                updated.categories.append(draft)
            }
        }
    }

    func removeCategory(_ id: UUID) throws {
        try update { updated in
            updated.categories.removeAll { $0.id == id }
            for index in updated.scripts.indices where updated.scripts[index].categoryID == id {
                updated.scripts[index].categoryID = nil
            }
        }
    }

    func prepareConfigurationFile() throws {
        if try readData() == nil {
            try update { _ in }
        }
    }

    private func update(_ change: (inout LibraryContents) -> Void) throws {
        if let loadError { throw AppError(loadError) }
        var updated = contents
        change(&updated)
        try validate(updated)

        let data: Data
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(updated)
            guard try readData() == loadedData else {
                throw AppError("配置文件已在外部修改。请返回面板，点击「同步配置」后再编辑。")
            }
            try data.write(to: url, options: .atomic)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError("无法保存脚本配置（\(error.localizedDescription)）。")
        }
        loadedData = data
        contents = updated
    }

    private func readData() throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func validate(_ contents: LibraryContents) throws {
        let categoryIDs = Set(contents.categories.map(\.id))
        let categoryNames = contents.categories.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard categoryIDs.count == contents.categories.count,
              Set(categoryNames).count == categoryNames.count,
              !categoryNames.contains(""), !categoryNames.contains(Self.uncategorized) else {
            throw AppError("分类的 ID 和名称必须唯一，且不能使用空名称或「未分类」。")
        }
        guard Set(contents.scripts.map(\.id)).count == contents.scripts.count else {
            throw AppError("脚本的 ID 必须唯一。")
        }
        for script in contents.scripts {
            guard ScriptFile.isScriptPath(script.path),
                  !script.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError("脚本需要有效的 .sh 绝对路径和别名。")
            }
            if let id = script.categoryID, !categoryIDs.contains(id) {
                throw AppError("脚本「\(script.alias)」引用了不存在的分类。")
            }
            let names = script.variants.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard Set(script.variants.map(\.id)).count == script.variants.count,
                  Set(names).count == names.count, !names.contains("") else {
                throw AppError("脚本「\(script.alias)」的变体需要非空且不重复的名称和唯一 ID。")
            }
            guard !script.variants.contains(where: { $0.arguments.contains(where: { $0.utf8.contains(0) }) }) else {
                throw AppError("脚本「\(script.alias)」的变体参数不能包含空字符。")
            }
            if script.usesMultipleLogs { try validateLogSources(script.logSources) }
        }
    }

    private func validateLogSources(_ sources: [ScriptLogSource]) throws {
        guard !sources.isEmpty else { throw AppError("开启多路输出后，请至少添加一个日志来源。") }
        let names = sources.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        let files = sources.map(\.fileName)
        guard files.allSatisfy({ name in
            !name.isEmpty && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
                && name != "." && name != ".." && !name.contains("/")
                && name.rangeOfCharacter(from: .controlCharacters) == nil
        }) else {
            throw AppError("请输入日志文件名（如 frontend.log），每路日志使用一个文件。")
        }
        guard !names.contains(""), Set(names).count == sources.count,
              Set(files.map { $0.lowercased() }).count == sources.count,
              Set(sources.map(\.id)).count == sources.count else {
            throw AppError("日志标签和文件名必须非空且各自唯一。")
        }
    }
}

struct ScriptFile {
    let url: URL
    let isExecutable: Bool

    func invocation(arguments: [String]) throws -> [String] {
        guard !arguments.contains(where: { $0.utf8.contains(0) }) else {
            throw AppError("参数不能包含空字符。")
        }
        return (isExecutable ? [] : ["/bin/bash"]) + [url.path] + arguments
    }

    static func isScriptPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.utf8.contains(0) && URL(fileURLWithPath: path).pathExtension.lowercased() == "sh"
    }

    static func validate(_ path: String) throws -> ScriptFile {
        guard isScriptPath(path) else { throw AppError("请选择有效的 .sh 文件路径。") }
        let url = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        let resolved = url.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
            throw AppError("找不到脚本文件。请在「管理」中重新选择路径。")
        }
        guard fileManager.isReadableFile(atPath: path) else {
            throw AppError("无法读取脚本。请检查文件权限。")
        }
        return ScriptFile(url: url, isExecutable: fileManager.isExecutableFile(atPath: path))
    }
}

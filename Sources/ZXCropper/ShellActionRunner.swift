import Foundation

struct ShellActionResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let outputImageURL: URL?
}

enum ShellActionRunner {
    static func run(action: ShellImageAction, inputURL: URL) -> ShellActionResult {
        let startDate = Date()
        let command = buildCommand(
            commandName: action.commandName,
            arguments: [inputURL.path]
        )

        return runCommand(
            command,
            inputURL: inputURL,
            startedAt: startDate,
            action: action,
            expectsSingleImageOutput: action.expectsSingleImageOutput
        )
    }

    static func run(customCommandTemplate: String, inputURL: URL, expectsSingleImageOutput: Bool = true) -> ShellActionResult {
        let startDate = Date()
        let command = buildCustomCommand(from: customCommandTemplate, inputURL: inputURL)

        return runCommand(
            command,
            inputURL: inputURL,
            startedAt: startDate,
            action: nil,
            expectsSingleImageOutput: expectsSingleImageOutput
        )
    }

    private static func runCommand(
        _ command: String,
        inputURL: URL,
        startedAt: Date,
        action: ShellImageAction?,
        expectsSingleImageOutput: Bool
    ) -> ShellActionResult {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedCommand.isEmpty else {
            return ShellActionResult(
                exitCode: 1,
                stdout: "",
                stderr: "Command is empty.",
                outputImageURL: nil
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ic", trimmedCommand]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ShellActionResult(
                exitCode: 1,
                stdout: "",
                stderr: error.localizedDescription,
                outputImageURL: nil
            )
        }

        process.waitUntilExit()

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        let outputURL = resolveOutputImageURL(
            action: action,
            expectsSingleImageOutput: expectsSingleImageOutput,
            inputURL: inputURL,
            stdout: stdout,
            startedAt: startedAt
        )

        return ShellActionResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            outputImageURL: outputURL
        )
    }

    private static func resolveOutputImageURL(
        action: ShellImageAction?,
        expectsSingleImageOutput: Bool,
        inputURL: URL,
        stdout: String,
        startedAt: Date
    ) -> URL? {
        let directory = inputURL.deletingLastPathComponent()

        if action == .luma {
            let baseName = inputURL.deletingPathExtension().lastPathComponent
            let expected = directory.appendingPathComponent("\(baseName)_transparent.png")
            if FileManager.default.fileExists(atPath: expected.path) {
                return expected
            }
        }

        if let parsed = parseSavedPath(from: stdout),
           FileManager.default.fileExists(atPath: parsed.path) {
            return parsed
        }

        guard expectsSingleImageOutput else {
            return nil
        }

        let candidates = recentImageCandidates(in: directory, excluding: inputURL, startedAt: startedAt)

        if candidates.count == 1 {
            return candidates.first
        }

        if let preferred = candidates.first(where: { $0.lastPathComponent.localizedCaseInsensitiveContains("transparent") }) {
            return preferred
        }

        return candidates.first
    }

    private static func parseSavedPath(from stdout: String) -> URL? {
        let lines = stdout.split(separator: "\n").map(String.init)

        for line in lines.reversed() {
            if let range = line.range(of: "Saved:") {
                let rawPath = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if rawPath.hasPrefix("/") {
                    return URL(fileURLWithPath: rawPath)
                }
            }

            if line.hasPrefix("/") {
                return URL(fileURLWithPath: line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        return nil
    }

    private static func recentImageCandidates(in directory: URL, excluding inputURL: URL, startedAt: Date) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let cutoff = startedAt.addingTimeInterval(-1.0)

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: nil
        ) else {
            return []
        }

        var results: [(url: URL, modified: Date)] = []

        for case let url as URL in enumerator {
            if url.path == inputURL.path {
                continue
            }

            let ext = url.pathExtension.lowercased()
            if !["png", "jpg", "jpeg", "webp", "bmp", "tif", "tiff", "gif"].contains(ext) {
                continue
            }

            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff else {
                continue
            }

            results.append((url, modified))
        }

        return results
            .sorted(by: { $0.modified > $1.modified })
            .map(\.url)
    }

    static func buildCommand(commandName: String, arguments: [String]) -> String {
        ([commandName] + arguments.map(shellQuote)).joined(separator: " ")
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func buildCustomCommand(from template: String, inputURL: URL) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        var command = trimmed
        let quotedInput = shellQuote(inputURL.path)
        let quotedDir = shellQuote(inputURL.deletingLastPathComponent().path)
        let quotedStem = shellQuote(inputURL.deletingPathExtension().lastPathComponent)
        let quotedName = shellQuote(inputURL.lastPathComponent)

        command = command.replacingOccurrences(of: "{input}", with: quotedInput)
        command = command.replacingOccurrences(of: "{dir}", with: quotedDir)
        command = command.replacingOccurrences(of: "{stem}", with: quotedStem)
        command = command.replacingOccurrences(of: "{name}", with: quotedName)

        if !trimmed.contains("{input}") {
            command += " " + quotedInput
        }

        return command
    }
}

import Foundation
import SwitchShelfDomain

public struct ParsedPackage: Sendable, Equatable {
    public var fileURL: URL
    public var format: PackageFormat
    public var titleID: String?
    public var baseTitleID: String?
    public var kind: ContentKind
    public var rawVersion: UInt32?
    public var displayVersion: String?
    public var gameTitle: String
    public var originalTitle: String?
    public var gameFolder: String

    public init(
        fileURL: URL,
        format: PackageFormat,
        titleID: String? = nil,
        baseTitleID: String? = nil,
        kind: ContentKind = .unknown,
        rawVersion: UInt32? = nil,
        displayVersion: String? = nil,
        gameTitle: String,
        originalTitle: String? = nil,
        gameFolder: String = ""
    ) {
        self.fileURL = fileURL
        self.format = format
        self.titleID = titleID
        self.baseTitleID = baseTitleID
        self.kind = kind
        self.rawVersion = rawVersion
        self.displayVersion = displayVersion
        self.gameTitle = gameTitle
        self.originalTitle = originalTitle
        self.gameFolder = gameFolder
    }
}

public enum FilenameParser {
    private static let titleIDRegex = try! NSRegularExpression(pattern: #"(?i)(?:\[|\(|\b)(0100[0-9A-Fa-f]{12})(?:\]|\)|\b)"#)
    private static let rawVersionRegex = try! NSRegularExpression(pattern: #"(?i)\[v?([0-9]{1,10})\]|\(v?([0-9]{1,10})\)"#)
    private static let displayVersionRegex = try! NSRegularExpression(pattern: #"(?i)(?:\[|\b)(?:v|版本\s*)([0-9]+(?:\.[0-9]+)+)(?:\]|\b)"#)
    private static let metadataTagRegex = try! NSRegularExpression(pattern: #"(?i)\[(?:UPD|UPDATE|DLC|BASE|US|USA|JP|JPN|EU|EUR|ASIA|HK|TW|KOR|WORLD|[0-9A-Fa-f]{16}|v?[0-9]+(?:\.[0-9]+)*|版本\s*[0-9.]+|[0-9]{5,10}|[0-9]+G\+[0-9]+U[^\]]*)\]|\((?:UPD|UPDATE|DLC|BASE|US|USA|JP|JPN|EU|EUR|ASIA|HK|TW|KOR|WORLD|[0-9A-Fa-f]{16}|v?[0-9]+(?:\.[0-9]+)*|版本\s*[0-9.]+|[0-9]{5,10}|[0-9]+G\+[0-9]+U[^\)]*)\)"#)

    private static let genericFolderNames: Set<String> = [
        "nsp本体", "nsz本体", "xci本体", "xcz本体", "本体", "nsp主体",
        "dlc", "upd", "update", "updates"
    ]

    public static func parse(fileURL: URL, sourceRoot: URL) -> ParsedPackage? {
        let ext = fileURL.pathExtension.lowercased()
        guard let format = PackageFormat(rawValue: ext) else {
            return nil
        }

        let filename = fileURL.lastPathComponent
        if filename.hasPrefix(".") || filename.hasPrefix("._") {
            return nil
        }
        if isTemporaryFile(filename: filename) {
            return nil
        }

        let filenameWithoutExt = fileURL.deletingPathExtension().lastPathComponent

        // Extract TitleID
        let (titleID, baseTitleID) = extractTitleIDs(from: filenameWithoutExt)

        // Extract Versions
        let (rawVersion, displayVersion) = extractVersions(from: filenameWithoutExt, parentPath: fileURL.path)

        // Determine Kind
        let kind = determineContentKind(
            filename: filenameWithoutExt,
            filePath: fileURL.path,
            titleID: titleID
        )

        // Resolve top-level game folder and titles
        let (gameFolder, folderTitle) = resolveGameFolderAndTitle(fileURL: fileURL, sourceRoot: sourceRoot)
        let cleanedFilenameTitle = cleanTitle(from: filenameWithoutExt)

        let resolvedTitle: String
        let resolvedOriginalTitle: String?

        if !cleanedFilenameTitle.isEmpty {
            if !folderTitle.isEmpty && containsChinese(folderTitle) && !containsChinese(cleanedFilenameTitle) {
                let (primary, _) = splitMixedTitle(folderTitle)
                resolvedTitle = primary
                resolvedOriginalTitle = cleanedFilenameTitle
            } else {
                let (primary, secondary) = splitMixedTitle(cleanedFilenameTitle)
                resolvedTitle = primary
                resolvedOriginalTitle = secondary ?? ((folderTitle != cleanedFilenameTitle && !folderTitle.isEmpty) ? folderTitle : nil)
            }
        } else if !folderTitle.isEmpty {
            let (primary, secondary) = splitMixedTitle(folderTitle)
            resolvedTitle = primary
            resolvedOriginalTitle = secondary
        } else {
            resolvedTitle = filenameWithoutExt
            resolvedOriginalTitle = nil
        }

        return ParsedPackage(
            fileURL: fileURL,
            format: format,
            titleID: titleID,
            baseTitleID: baseTitleID,
            kind: kind,
            rawVersion: rawVersion,
            displayVersion: displayVersion,
            gameTitle: resolvedTitle,
            originalTitle: resolvedOriginalTitle,
            gameFolder: gameFolder
        )
    }

    private static func isTemporaryFile(filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasSuffix(".part") ||
               lower.hasSuffix(".tmp") ||
               lower.hasSuffix(".crdownload") ||
               lower.hasSuffix(".download") ||
               lower.contains(".part.") ||
               lower.contains(".tmp.")
    }

    private static func extractTitleIDs(from text: String) -> (titleID: String?, baseTitleID: String?) {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = titleIDRegex.matches(in: text, options: [], range: range)

        guard let firstMatch = matches.first,
              let idRange = Range(firstMatch.range(at: 1), in: text) else {
            return (nil, nil)
        }

        let rawID = String(text[idRange]).uppercased()
        var baseID: String? = nil

        if rawID.hasSuffix("800") {
            // Update title ID ends in 800; its base title ID ends in 000
            baseID = String(rawID.dropLast(3)) + "000"
        } else if rawID.hasSuffix("000") {
            baseID = rawID
        }

        return (rawID, baseID)
    }

    private static func extractVersions(from text: String, parentPath: String) -> (rawVersion: UInt32?, displayVersion: String?) {
        var rawVersion: UInt32? = nil
        var displayVersion: String? = nil

        // Search display version in text and full path (e.g. folder contains [版本1.0.1] or v1.4.0)
        let searchText = "\(parentPath) \(text)"
        let searchRange = NSRange(searchText.startIndex..<searchText.endIndex, in: searchText)
        if let match = displayVersionRegex.firstMatch(in: searchText, options: [], range: searchRange),
           let vRange = Range(match.range(at: 1), in: searchText) {
            displayVersion = "v" + String(searchText[vRange])
        }

        // Search raw version in filename text
        let textRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let rawMatches = rawVersionRegex.matches(in: text, options: [], range: textRange)
        for match in rawMatches {
            let captureRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            if let r = Range(captureRange, in: text), let val = UInt32(text[r]) {
                // If it's a version number like 0, 65536, 131072, etc.
                rawVersion = val
                break
            }
        }

        return (rawVersion, displayVersion)
    }

    private static func determineContentKind(filename: String, filePath: String, titleID: String?) -> ContentKind {
        let lowerText = "\(filePath)/\(filename)".lowercased()

        if lowerText.contains("[dlc]") || lowerText.contains("(dlc)") ||
           lowerText.contains("/dlc/") || lowerText.contains("/dlc-") ||
           lowerText.contains(" dlc") || lowerText.contains("_dlc") {
            return .dlc
        }

        if lowerText.contains("[upd]") || lowerText.contains("(upd)") ||
           lowerText.contains("[update]") || lowerText.contains("(update)") ||
           lowerText.contains("/upd-") || lowerText.contains("/update-") ||
           lowerText.contains("/upd/") || lowerText.contains("/update/") {
            return .update
        }

        if lowerText.contains("[base]") || lowerText.contains("(base)") ||
           lowerText.contains("nsp本体") || lowerText.contains("nsz本体") ||
           lowerText.contains("nsp主体") {
            return .base
        }

        if let titleID {
            if titleID.hasSuffix("800") {
                return .update
            } else if titleID.hasSuffix("000") {
                return .base
            }
        }

        return .unknown
    }

    public static func cleanTitle(from text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var cleaned = metadataTagRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")

        // Also remove freestanding v0, v1.0.0 if left
        cleaned = cleaned.replacingOccurrences(of: #"\bv[0-9]+(?:\.[0-9]+)*\b"#, with: "", options: .regularExpression)

        // Replace any remaining brackets/parentheses around titles with spaces
        cleaned = cleaned.replacingOccurrences(of: "[", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "]", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "(", with: " ")
        cleaned = cleaned.replacingOccurrences(of: ")", with: " ")

        // Clean surrounding delimiters like -, _, space
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " -_–—\t\r\n"))
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        return cleaned
    }

    private static func resolveGameFolderAndTitle(fileURL: URL, sourceRoot: URL) -> (gameFolder: String, folderTitle: String) {
        let sourcePath = sourceRoot.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path

        guard filePath.hasPrefix(sourcePath) else {
            return ("", "")
        }

        let relativePath = String(filePath.dropFirst(sourcePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = relativePath.split(separator: "/").map(String.init)

        guard components.count > 1 else {
            // File is at root of source
            return ("", "")
        }

        // The top-level folder directly under sourceRoot is usually the game directory
        let topFolder = components[0]
        let cleanedFolderTitle = cleanTitle(from: topFolder)

        // If top folder is something generic, check next component
        if genericFolderNames.contains(topFolder.lowercased()) && components.count > 2 {
            let nextFolder = components[1]
            return (nextFolder, cleanTitle(from: nextFolder))
        }

        return (topFolder, cleanedFolderTitle)
    }

    private static func splitMixedTitle(_ text: String) -> (primary: String, secondary: String?) {
        // Handle cases like "未命名鹅游戏 Untitled Goose Game" or "完蛋 我被美女包围了 Love is all around"
        // If there's a Chinese portion and an English portion
        let components = text.components(separatedBy: " ")
        var chineseWords: [String] = []
        var englishWords: [String] = []

        for comp in components {
            if containsChinese(comp) {
                chineseWords.append(comp)
            } else {
                englishWords.append(comp)
            }
        }

        if !chineseWords.isEmpty && !englishWords.isEmpty {
            let primary = chineseWords.joined(separator: " ")
            let secondary = englishWords.joined(separator: " ")
            if !secondary.isEmpty && !primary.isEmpty {
                return (primary, secondary)
            }
        }

        return (text, nil)
    }

    private static func containsChinese(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
    }
}

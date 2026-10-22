import Foundation
import Testing
import SwitchShelfDomain
@testable import SwitchShelfLibrary

@Suite("FilenameParser Tests")
struct FilenameParserTests {
    let mockRoot = URL(fileURLWithPath: "/test/library")

    @Test("Parse standard base game with TitleID and version")
    func parseStandardBaseGame() {
        let fileURL = mockRoot.appendingPathComponent("大家1-2-Switch [版本1.0.1]/[01006F900BF8E000].xci")
        let parsed = FilenameParser.parse(fileURL: fileURL, sourceRoot: mockRoot)

        #expect(parsed != nil)
        #expect(parsed?.format == .xci)
        #expect(parsed?.titleID == "01006F900BF8E000")
        #expect(parsed?.baseTitleID == "01006F900BF8E000")
        #expect(parsed?.kind == .base)
        #expect(parsed?.gameTitle == "大家1-2-Switch")
        #expect(parsed?.displayVersion == "v1.0.1")
    }

    @Test("Parse update with base TitleID directly in filename")
    func parseUpdateWithBaseTitleID() {
        let fileURL = mockRoot.appendingPathComponent("大家1-2-Switch [版本1.0.1]/[UPD][v1.0.1][01006F900BF8E000][v65536].nsp")
        let parsed = FilenameParser.parse(fileURL: fileURL, sourceRoot: mockRoot)

        #expect(parsed != nil)
        #expect(parsed?.format == .nsp)
        #expect(parsed?.titleID == "01006F900BF8E000")
        #expect(parsed?.kind == .update)
        #expect(parsed?.rawVersion == 65536)
        #expect(parsed?.displayVersion == "v1.0.1")
        #expect(parsed?.gameTitle == "大家1-2-Switch")
    }

    @Test("Parse update with 800 TitleID and compute base TitleID")
    func parseUpdateWith800TitleID() {
        let fileURL = mockRoot.appendingPathComponent("双点医院/upd-v1.0.14/[UPD][v1.0.14]Two Point Hospital [010031200E044800][v917504].nsp")
        let parsed = FilenameParser.parse(fileURL: fileURL, sourceRoot: mockRoot)

        #expect(parsed != nil)
        #expect(parsed?.format == .nsp)
        #expect(parsed?.titleID == "010031200E044800")
        #expect(parsed?.baseTitleID == "010031200E044000")
        #expect(parsed?.kind == .update)
        #expect(parsed?.rawVersion == 917504)
        #expect(parsed?.displayVersion == "v1.0.14")
    }

    @Test("Parse DLC with DLC tag and subfolder")
    func parseDLC() {
        let fileURL = mockRoot.appendingPathComponent("路易吉鬼屋3 [版本1.4.0]/dlc-2/[DLC][0100DCA0064A7001][US][v131072].nsz")
        let parsed = FilenameParser.parse(fileURL: fileURL, sourceRoot: mockRoot)

        #expect(parsed != nil)
        #expect(parsed?.format == .nsz)
        #expect(parsed?.titleID == "0100DCA0064A7001")
        #expect(parsed?.kind == .dlc)
        #expect(parsed?.rawVersion == 131072)
        #expect(parsed?.gameTitle == "路易吉鬼屋3")
    }

    @Test("Parse Chinese game with spaces and clean titles")
    func parseChineseWithSpaces() {
        let fileURL = mockRoot.appendingPathComponent("塞尔达传说 旷野之息/塞尔达传说 旷野之息 [01007EF00011E000][v0].xci")
        let parsed = FilenameParser.parse(fileURL: fileURL, sourceRoot: mockRoot)

        #expect(parsed != nil)
        #expect(parsed?.titleID == "01007EF00011E000")
        #expect(parsed?.gameTitle == "塞尔达传说 旷野之息")
        #expect(parsed?.kind == .base)
        #expect(parsed?.rawVersion == 0)
    }

    @Test("Parse mixed Chinese and English titles into primary and secondary")
    func parseMixedTitles() {
        let fileURL = mockRoot.appendingPathComponent("未命名鹅游戏 Untitled Goose Game/Untitled Goose Game [010082400BCC6000][v0].nsp")
        let parsed = FilenameParser.parse(fileURL: fileURL, sourceRoot: mockRoot)

        #expect(parsed != nil)
        #expect(parsed?.titleID == "010082400BCC6000")
        #expect(parsed?.gameTitle == "未命名鹅游戏")
        #expect(parsed?.originalTitle == "Untitled Goose Game")
    }

    @Test("Parse homebrew or unknown file preserving name without TitleID")
    func parseUnknownHomebrew() {
        let fileURL = mockRoot.appendingPathComponent("HomebrewApp.nsp")
        let parsed = FilenameParser.parse(fileURL: fileURL, sourceRoot: mockRoot)

        #expect(parsed != nil)
        #expect(parsed?.titleID == nil)
        #expect(parsed?.kind == .unknown)
        #expect(parsed?.gameTitle == "HomebrewApp")
        #expect(parsed?.format == .nsp)
    }

    @Test("Ignore AppleDouble and temporary files")
    func ignoreTemporaryAndAppleDouble() {
        let appleDouble = mockRoot.appendingPathComponent("game/._[01006F900BF8E000].xci")
        let partFile = mockRoot.appendingPathComponent("game/[01006F900BF8E000].xci.part")
        let tmpFile = mockRoot.appendingPathComponent("game/temp.tmp")
        let textFile = mockRoot.appendingPathComponent("game/readme.txt")

        #expect(FilenameParser.parse(fileURL: appleDouble, sourceRoot: mockRoot) == nil)
        #expect(FilenameParser.parse(fileURL: partFile, sourceRoot: mockRoot) == nil)
        #expect(FilenameParser.parse(fileURL: tmpFile, sourceRoot: mockRoot) == nil)
        #expect(FilenameParser.parse(fileURL: textFile, sourceRoot: mockRoot) == nil)
    }
}

import Foundation
import XCTest
@testable import Caddyman

final class LocalizationTests: XCTestCase {
    func testSimplifiedChineseOverviewAndSettingsTranslationsAreCompiled() throws {
        let appBundle = Bundle(for: CaddymanAppDelegate.self)
        let resourcesURL = try XCTUnwrap(appBundle.resourceURL)
        let chineseBundleURL = resourcesURL.appendingPathComponent("zh-Hans.lproj", isDirectory: true)
        let chineseBundle = try XCTUnwrap(Bundle(url: chineseBundleURL))

        XCTAssertEqual(
            chineseBundle.localizedString(forKey: "Overview", value: nil, table: "Localizable"),
            "概览"
        )
        XCTAssertEqual(
            chineseBundle.localizedString(forKey: "General", value: nil, table: "Localizable"),
            "通用"
        )
        XCTAssertEqual(
            chineseBundle.localizedString(forKey: "About", value: nil, table: "Localizable"),
            "关于"
        )
        XCTAssertEqual(
            chineseBundle.localizedString(forKey: "Import preview", value: nil, table: "Localizable"),
            "导入预览"
        )
        XCTAssertEqual(
            chineseBundle.localizedString(forKey: "Complete proposed diff", value: nil, table: "Localizable"),
            "完整候选差异"
        )
        XCTAssertEqual(
            chineseBundle.localizedString(forKey: "Caddy follows Caddyman", value: nil, table: "Localizable"),
            "Caddy 跟随 Caddyman"
        )
    }

    func testOverviewLabelUsesSystemPreferredLanguage() {
        let primaryLanguage = Locale.preferredLanguages.first?.lowercased() ?? "en"
        let isSimplifiedChinese = primaryLanguage.hasPrefix("zh-hans")
            || primaryLanguage.hasPrefix("zh-cn")
            || primaryLanguage.hasPrefix("zh-sg")

        XCTAssertEqual(L10n.text("Overview"), isSimplifiedChinese ? "概览" : "Overview")
    }

    func testSiteAndImportTranslationsAreCompiled() throws {
        let appBundle = Bundle(for: CaddymanAppDelegate.self)
        let resourcesURL = try XCTUnwrap(appBundle.resourceURL)
        let chineseBundle = try XCTUnwrap(Bundle(
            url: resourcesURL.appendingPathComponent("zh-Hans.lproj", isDirectory: true)
        ))
        let expected = [
            "Site overview": "站点概览",
            "Current Caddyfile": "当前 Caddyfile",
            "Imported Caddyfiles": "导入的 Caddyfile",
            "Add Import…": "添加导入…",
            "Choose File…": "选择文件…",
            "Read-only": "只读",
            "Sites including imports": "包含导入的站点",
        ]
        for (key, translation) in expected {
            XCTAssertEqual(chineseBundle.localizedString(forKey: key, value: nil, table: "Localizable"), translation)
        }
    }
}

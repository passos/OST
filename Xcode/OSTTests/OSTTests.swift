import OSTCore
import XCTest

final class OSTTests: XCTestCase {
    func testBundledCatalogIsValid() throws {
        let catalog = try ModelCatalog.bundled()
        XCTAssertEqual(catalog.models.count, 4)
        XCTAssertNoThrow(try catalog.validate())
    }

    func testMainPrivacyDefaults() {
        let snapshot = PreferencesSnapshot()
        XCTAssertTrue(snapshot.overlayLocked)
        XCTAssertEqual(snapshot.backgroundOpacity, 0.65)
        XCTAssertEqual(snapshot.sourceFontSize, 20)
        XCTAssertEqual(snapshot.translationFontSize, 28)
        XCTAssertEqual(snapshot.appDisplayLanguage, .english)
        XCTAssertFalse(snapshot.sessionLoggingEnabled)
        XCTAssertNil(snapshot.sessionLogDirectoryBookmark)
    }
}

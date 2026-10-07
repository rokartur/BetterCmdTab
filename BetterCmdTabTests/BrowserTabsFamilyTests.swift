import Testing
@testable import BetterCmdTab

@Suite("BrowserTabs family")
struct BrowserTabsFamilyTests {
    @Test("Arc and Dia get their own dialects: Chrome's `active tab index` does not compile against them (#201)")
    func browserCompanyBrowsersAreNotChromium() {
        #expect(BrowserTabs.Family.from(bundleID: "company.thebrowser.browser") == .arc)
        #expect(BrowserTabs.Family.from(bundleID: "company.thebrowser.dia") == .dia)
    }
}

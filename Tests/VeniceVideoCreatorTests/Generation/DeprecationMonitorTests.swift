import Foundation
import Testing
@testable import VeniceVideoCreator

/// Model-deprecation header surfacing (harness rule 34): parse Venice's own header
/// names and notify once per (model, sunset date).
@Suite("DeprecationMonitor")
struct DeprecationMonitorTests {

    @Test func parsesVeniceHeaderNamesCaseInsensitively() {
        let headers: [AnyHashable: Any] = [
            "X-Venice-Model-Deprecation-Warning": "wan-2.5 is deprecated, migrate to wan-2.7",
            "x-venice-model-sunset-date": "2026-09-01",
            "Content-Type": "application/json",
        ]
        let parsed = DeprecationMonitor.parse(headers: headers)
        #expect(parsed.warning?.contains("deprecated") == true)
        #expect(parsed.sunset == "2026-09-01")
    }

    @Test func noHeadersParseToNil() {
        let parsed = DeprecationMonitor.parse(headers: ["Content-Type": "application/json"])
        #expect(parsed.warning == nil)
        #expect(parsed.sunset == nil)
    }

    @Test func notifiesOncePerModelAndDate() {
        let monitor = DeprecationMonitor()
        #expect(monitor.shouldNotify(model: "wan-2.5", sunset: "2026-09-01"))
        // Same pair again → suppressed.
        #expect(!monitor.shouldNotify(model: "wan-2.5", sunset: "2026-09-01"))
        // A new sunset date for the same model → notify again.
        #expect(monitor.shouldNotify(model: "wan-2.5", sunset: "2026-10-01"))
        // A different model → notify.
        #expect(monitor.shouldNotify(model: "kling-o3", sunset: "2026-09-01"))
    }

    @Test func messageFoldsInSunsetWhenNotAlreadyPresent() {
        let withSunset = DeprecationMonitor.message(model: "wan-2.5", warning: "wan-2.5 is deprecated", sunset: "2026-09-01")
        #expect(withSunset.contains("2026-09-01"))
        // If the warning already names the date, don't duplicate it.
        let already = DeprecationMonitor.message(model: "wan-2.5", warning: "deprecated, sunset 2026-09-01", sunset: "2026-09-01")
        #expect(already == "deprecated, sunset 2026-09-01")
        // No warning falls back to a model-named line.
        let fallback = DeprecationMonitor.message(model: "wan-2.5", warning: nil, sunset: nil)
        #expect(fallback.contains("wan-2.5"))
    }

    @Test func inspectWithNoDeprecationHeadersDoesNothing() {
        let monitor = DeprecationMonitor()
        // A clean response never marks anything seen, so a later real warning still notifies.
        monitor.inspect(model: "wan-2.7", headers: ["Content-Type": "application/json"])
        #expect(monitor.shouldNotify(model: "wan-2.7", sunset: nil))
    }
}

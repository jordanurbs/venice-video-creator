import AppKit

Log.bootstrap()
Telemetry.start()
BundledFonts.register()
AccountService.shared.configure()
// Manifest before catalog: the catalog mapper reads capability lookups.
CapabilityManifestStore.shared.configure()
ModelCatalog.shared.configure()
ModelTraitsCatalog.shared.configure()

// Shorten the default tooltip delay from 2s to 0.01s.
UserDefaults.standard.set(10, forKey: "NSInitialToolTipDelay")

let app = NSApplication.shared
// One global appearance; per-window call sites can't cover panels and alerts.
app.appearance = NSAppearance(named: .darkAqua)
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = MainMenuBuilder.buildMenu()
app.run()

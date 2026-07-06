import AppKit
import Foundation
import Observation

/// Venice BYO-key "account" state.
///
/// There is no cloud sign-in and no metered billing: access is gated purely on
/// whether the user has stored a Venice API key. Live balance/usage is read
/// directly from Venice for the current key.
@Observable
@MainActor
final class AccountService {
    static let shared = AccountService()

    private(set) var isLoading: Bool = false
    /// Always configured: the only requirement is a Venice key, set in Settings.
    let isMisconfigured: Bool = false
    private(set) var lastError: String? = nil

    /// Reflects Venice key presence; observable so UI updates on key changes.
    private(set) var hasVeniceKey: Bool = VeniceKeychain.hasKey

    // MARK: - Live Venice balance / usage (BYO key)

    struct VeniceUsageInfo: Sendable, Equatable {
        var accessPermitted: Bool
        var tier: String?
        var usdBalance: Double?
        var diemBalance: Double?
        var nextEpochBegins: String?
        var spendUSD: Double?
        var spendDiem: Double?
        var spendLookbackDays: Int?
    }

    private(set) var veniceUsage: VeniceUsageInfo?
    private(set) var isLoadingUsage: Bool = false
    private(set) var usageError: String?

    @ObservationIgnored private var keyObserver: NSObjectProtocol?

    private init() {
        keyObserver = NotificationCenter.default.addObserver(
            forName: .veniceAPIKeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hasVeniceKey = VeniceKeychain.hasKey
                self?.veniceUsage = nil
                self?.usageError = nil
            }
        }
    }

    isolated deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    var isSignedIn: Bool { hasVeniceKey }
    var aiAllowed: Bool { hasVeniceKey }
    /// With a key present the user can generate; Venice meters usage on its side.
    var hasCredits: Bool { hasVeniceKey }

    func configure() {
        hasVeniceKey = VeniceKeychain.hasKey
    }

    /// Pulls live balances (`/api_keys/rate_limits`) and trailing spend
    /// (`/billing/usage-analytics`) for the current Venice key. Both are
    /// best-effort — partial results still update the UI.
    func refreshUsage(lookbackDays: Int = 7) async {
        guard let api = VeniceAPI.fromKeychain() else {
            veniceUsage = nil
            return
        }
        isLoadingUsage = true
        defer { isLoadingUsage = false }

        async let limitsResult: Result<VeniceRateLimitInfo, Error> = {
            do { return .success(try await api.rateLimitInfo()) }
            catch { return .failure(error) }
        }()
        async let usageResult = try? await api.usageAnalytics(lookbackDays: lookbackDays)

        let limits: VeniceRateLimitInfo?
        switch await limitsResult {
        case .success(let info):
            limits = info
        case .failure(VeniceAPI.VeniceError.http(let status, _)) where status == 401 || status == 403:
            usageError = "Venice rejected this key. Check it in Settings."
            veniceUsage = nil
            return
        case .failure:
            limits = nil
        }
        let usage = await usageResult

        if limits == nil && usage == nil {
            usageError = "Couldn't reach Venice to load the balance. Check your connection."
            return
        }
        usageError = nil
        veniceUsage = VeniceUsageInfo(
            accessPermitted: limits?.accessPermitted ?? true,
            tier: limits?.tier,
            usdBalance: limits?.usd,
            diemBalance: limits?.diem,
            nextEpochBegins: limits?.nextEpochBegins,
            spendUSD: usage?.usd,
            spendDiem: usage?.diem,
            spendLookbackDays: usage?.lookbackDays
        )
    }

}

// MARK: - Display helpers

extension AccountService {
    var displayPrimaryText: String {
        isSignedIn ? "Venice API key set" : "No Venice key"
    }

    var displaySecondaryText: String? { nil }

    var displayInitial: String { "V" }
}

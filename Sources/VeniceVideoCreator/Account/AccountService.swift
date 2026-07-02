import AppKit
import Foundation
import Observation

enum AccountTier: String, Decodable, Sendable {
    case none, pro, max

    var isPaid: Bool { self != .none }

    var planLabel: String {
        switch self {
        case .none: return "Free"
        case .pro: return "Pro plan"
        case .max: return "Max plan"
        }
    }

    var upgradeLabel: String {
        switch self {
        case .none: return ""
        case .pro: return "Pro"
        case .max: return "Max"
        }
    }
}

struct AccountUser: Decodable, Sendable {
    let email: String?
    let name: String?
    let image: String?
    let tier: AccountTier
    let currentPeriodEnd: Double?
    let cancelAtPeriodEnd: Bool?
    let spentCreditsThisPeriod: Int?
    let purchasedCredits: Int?

    var displayName: String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespaces),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var firstName: String? {
        displayName?.split(separator: " ").first.map(String.init)
    }
}

struct AccountPlan: Decodable, Sendable {
    let tier: AccountTier
    let monthlyPriceUsd: Int
    let monthlyBudgetCredits: Int?
}

struct AvailablePlan: Decodable, Sendable, Identifiable {
    let tier: AccountTier
    let monthlyPriceUsd: Int
    let discountedMonthlyPriceUsd: Int?
    let monthlyBudgetCredits: Int?

    var id: String { tier.rawValue }
    var effectiveMonthlyPriceUsd: Int {
        hasDiscount ? discountedMonthlyPriceUsd! : monthlyPriceUsd
    }
    var hasDiscount: Bool {
        guard let discounted = discountedMonthlyPriceUsd else { return false }
        return discounted < monthlyPriceUsd
    }
}

struct AccountResponse: Decodable, Sendable {
    let user: AccountUser
    let plan: AccountPlan?
}

enum TopOffLimits {
    static let minDollars = 5
    static let maxDollars = 1000
}

/// Venice BYO-key "account" state.
///
/// The original cloud account/billing layer (Clerk auth + Convex + Stripe
/// credits) has been removed. There is no sign-in and no metered billing:
/// access is gated purely on whether the user has stored a Venice API key.
/// The public surface is preserved so the rest of the UI compiles unchanged —
/// `isSignedIn` now means "has a Venice key", `budgetCredits` is `nil` so the
/// credit counters stay hidden, and the billing actions are no-ops.
@Observable
@MainActor
final class AccountService {
    static let shared = AccountService()

    private(set) var isLoading: Bool = false
    /// Always configured: the only requirement is a Venice key, set in Settings.
    let isMisconfigured: Bool = false
    private(set) var account: AccountResponse? = nil
    private(set) var availablePlans: [AvailablePlan] = []
    private(set) var lastError: String? = nil
    private(set) var isBuyingCredits: Bool = false

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
    var tier: AccountTier { .none }
    var isPaid: Bool { false }

    var spentCredits: Int { 0 }
    /// `nil` budget => the UI treats usage as unmetered (BYO key) and hides counters.
    var budgetCredits: Int? { nil }
    var remainingCredits: Int { 0 }
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

        async let rateLimits = try? api.rateLimitInfo()
        async let totals = try? api.usageAnalytics(lookbackDays: lookbackDays)
        let (limits, usage) = await (rateLimits, totals)

        if limits == nil && usage == nil {
            usageError = "Could not load balance for this key."
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

    // MARK: - Removed cloud actions (kept as no-ops for API compatibility)

    func signInWithGoogle() async {}
    func signOut() async {}
    func subscribe(tier: AccountTier) async {}
    func buyCredits(dollars: Int) {}
    func manageSubscription() async {}

    func sendFeedback(
        message: String,
        email: String?,
        mayContact: Bool,
        screenshotPngBase64: String?,
        appVersion: String,
        osVersion: String
    ) async throws {
        throw NSError(
            domain: "Venice.Feedback", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "In-app feedback submission is disabled in this open-source build. Please open a GitHub issue."]
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

    func availablePlan(for tier: AccountTier) -> AvailablePlan? {
        availablePlans.first { $0.tier == tier }
    }
}

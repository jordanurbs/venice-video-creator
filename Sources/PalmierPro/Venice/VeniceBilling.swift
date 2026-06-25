import Foundation

/// Balances + tier for the current key (`/api_keys/rate_limits`). Works on
/// INFERENCE keys, unlike `/billing/balance` which needs an ADMIN key.
struct VeniceRateLimitInfo: Sendable {
    let accessPermitted: Bool
    let tier: String?
    let usd: Double?
    let diem: Double?
    let nextEpochBegins: String?
}

/// Trailing usage totals from `/billing/usage-analytics` (any key).
struct VeniceUsageTotals: Sendable {
    let usd: Double
    let diem: Double
    let lookbackDays: Int
}

extension VeniceAPI {
    func rateLimitInfo() async throws -> VeniceRateLimitInfo {
        let obj = try await getJSON(path: "api_keys/rate_limits")
        let data = (obj["data"] as? [String: Any]) ?? obj
        let balances = (data["balances"] as? [String: Any]) ?? [:]
        let tier = (data["apiTier"] as? [String: Any])?["id"] as? String
        return VeniceRateLimitInfo(
            accessPermitted: data["accessPermitted"] as? Bool ?? true,
            tier: tier,
            usd: Self.num(balances["USD"]),
            diem: Self.num(balances["DIEM"]),
            nextEpochBegins: data["nextEpochBegins"] as? String
        )
    }

    func usageAnalytics(lookbackDays: Int = 7) async throws -> VeniceUsageTotals {
        let obj = try await getJSON(path: "billing/usage-analytics?lookback=\(lookbackDays)d")
        let byDate = (obj["byDate"] as? [[String: Any]]) ?? []
        var usd = 0.0, diem = 0.0
        for entry in byDate {
            usd += Self.num(entry["USD"]) ?? 0
            diem += Self.num(entry["DIEM"]) ?? 0
        }
        return VeniceUsageTotals(usd: usd, diem: diem, lookbackDays: lookbackDays)
    }

    static func num(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
}

import Foundation

struct AgentPaymentFilter: Equatable {
    var rail: AgentPaymentRail?
    var unit: String?
    var maxPricePerRequest: UInt64?
    var settlementMode: AgentSettlementMode?

    static let any = AgentPaymentFilter(rail: nil, unit: nil, maxPricePerRequest: nil, settlementMode: nil)

    var isAny: Bool {
        rail == nil && (unit?.isEmpty != false) && maxPricePerRequest == nil && settlementMode == nil
    }

    func matches(_ info: AgentInfo) -> Bool {
        guard !isAny else { return true }
        guard let terms = info.paymentTerms?.sanitized() else { return false }
        if let rail, terms.paymentRail != rail { return false }
        if let unit, !unit.isEmpty, terms.unit.lowercased() != unit.lowercased() { return false }
        if let maxPricePerRequest {
            if terms.usesPerTokenPricing {
                let outputCost = (terms.pricePerOutputToken ?? 0) * UInt64(terms.effectiveGranularityTokens)
                let projected = max(outputCost, terms.effectiveMinimumDeposit)
                if projected > maxPricePerRequest { return false }
            } else if terms.pricePerRequest > maxPricePerRequest {
                return false
            }
        }
        if let settlementMode, terms.settlementMode != settlementMode { return false }
        return true
    }

    var description: String {
        if isAny { return "any" }
        let railString = rail?.rawValue ?? "any"
        let unitString = unit?.isEmpty == false ? unit! : "any"
        let maxString = maxPricePerRequest.map(String.init) ?? "any"
        let modeString = settlementMode?.rawValue ?? "any"
        return "rail=\(railString) unit=\(unitString) maxPrice=\(maxString) mode=\(modeString)"
    }
}

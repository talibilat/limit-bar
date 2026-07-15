import Testing
@testable import LimitBarCore

@Suite("API provider quota path")
struct APIProviderQuotaPathTests {
    @Test("all modeled API products fail closed with the documented unmet criterion")
    func modeledProductsAreUnavailable() {
        #expect(ProviderProduct.anthropicAPI.apiQuotaPathAvailability == .unavailable(.noDocumentedSafeAcquisition))
        #expect(ProviderProduct.openAIAPI.apiQuotaPathAvailability == .unavailable(.noAbsoluteProviderReportedResetBoundary))
        #expect(ProviderProduct.azureOpenAI.apiQuotaPathAvailability == .unavailable(.noDocumentedConsumptionWindowBoundary))
    }

    @Test("subscription products are outside the API-provider decision")
    func subscriptionProductsAreNotApplicable() {
        #expect(ProviderProduct.claudeCode.apiQuotaPathAvailability == nil)
        #expect(ProviderProduct.codex.apiQuotaPathAvailability == nil)
    }

    @Test("product copy does not imply adapter support")
    func unavailableCopy() {
        #expect(APIProviderQuotaPathAvailability.fixedUnavailableSummary ==
            "API-provider quota evidence is unavailable: no documented source currently provides both safely acquirable quota consumption and an exact provider-reported reset boundary.")
    }
}

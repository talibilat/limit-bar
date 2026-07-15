import Testing
@testable import LimitBarCore

@Suite("API provider quota path")
struct APIProviderQuotaPathTests {
    @Test("all modeled API products fail closed with every documented unmet criterion")
    func modeledProductsAreUnavailable() {
        let workloadAndReadSourceGaps: Set<APIProviderQuotaUnavailableReason> = [
            .noDocumentedSafeAcquisitionForWorkloadEvidence,
            .noDocumentedReadSourceForQuotaConsumption,
            .noDocumentedProviderQuotaWindowBoundary,
        ]
        #expect(ProviderProduct.anthropicAPI.apiQuotaPathAvailability == .unavailable(workloadAndReadSourceGaps))
        #expect(ProviderProduct.openAIAPI.apiQuotaPathAvailability == .unavailable(workloadAndReadSourceGaps))
        #expect(ProviderProduct.azureOpenAI.apiQuotaPathAvailability == .unavailable(workloadAndReadSourceGaps))
    }

    @Test("subscription products are outside the API-provider decision")
    func subscriptionProductsAreNotApplicable() {
        #expect(ProviderProduct.claudeCode.apiQuotaPathAvailability == nil)
        #expect(ProviderProduct.codex.apiQuotaPathAvailability == nil)
    }

    @Test("product copy does not imply adapter support")
    func unavailableCopy() {
        #expect(APIProviderQuotaPathAvailability.fixedUnavailableSummary ==
            "API-provider quota evidence is unavailable: no documented source currently provides safely acquirable quota consumption in an exact provider-defined Quota window with a reported boundary.")
    }
}

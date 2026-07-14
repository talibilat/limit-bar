import Foundation
import LimitBarCore
import XCTest
@testable import LimitBar

@MainActor
final class DiagnosticExportPresentationTests: XCTestCase {
    func testAppBuilderProjectsOnlySafeLiveState() throws {
        let privatePath = "/Users/PRIVATE_USER/SECRET_PROJECT"
        let privateOrganization = "SECRET_ORGANIZATION"
        let settings = ProviderSettings(
            provider: .openAI,
            authMethod: .openAIOAuth,
            azureEndpoint: privatePath,
            openAIOrganizationID: privateOrganization,
            state: .failed,
            failureReason: .networkUnavailable,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_123)
        )
        let window = try ExactUsageWindow(
            timeWindow: .today,
            start: Date(timeIntervalSince1970: 1_699_920_000),
            end: Date(timeIntervalSince1970: 1_700_006_400),
            basis: .localCalendar,
            aggregationVersion: 99
        )
        let history = try ProviderRefreshHistoryEntry(
            product: .openAIAPI,
            outcome: .networkFailure,
            startedAt: Date(timeIntervalSince1970: 1_700_000_123),
            duration: 2,
            affectedWindows: [window]
        )

        let input = try DiagnosticExportInputBuilder.make(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_123),
            applicationVersion: "1.2.3",
            applicationBuild: "42",
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 5, patchVersion: 0),
            providerSettings: ProviderSettings.defaultSettings.map { $0.provider == .openAI ? settings : $0 },
            customSourceCount: 1,
            databaseIsAvailable: false,
            acceptedImportCount: 7,
            rejectedImportCount: 2,
            customImportFailures: 0,
            customRejectedLines: 3,
            refreshHistory: [.openAIAPI: ProviderRefreshHistorySummary(latest: history, lastFullSuccess: nil)]
        )
        let artifact = try DiagnosticExport.make(from: input)
        let preview = try artifact.preview

        XCTAssertTrue(preview.contains(#""state" : "networkUnavailable""#))
        XCTAssertEqual(input.providerStatuses.filter { $0.provider == .custom }, [
            DiagnosticProviderStatus(provider: .custom, state: .connected),
        ])
        XCTAssertTrue(preview.contains(#""rejected" : 5"#))
        XCTAssertFalse(preview.contains(privatePath))
        XCTAssertFalse(preview.contains(privateOrganization))
        XCTAssertFalse(preview.contains("updatedAt"))
        XCTAssertFalse(preview.contains("authMethod"))
        XCTAssertFalse(preview.contains("aggregationVersion"))
        XCTAssertFalse(preview.contains("localCalendar"))
        XCTAssertTrue(preview.contains(#""affectedWindowKinds""#))
    }

    func testPreviewArtifactIsSavedWithoutRegeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("chosen.json")
        var generation = 0
        let model = DiagnosticExportModel(
            makeArtifact: {
                generation += 1
                return try self.artifact(build: generation)
            },
            chooseDestination: { destination }
        )

        await model.prepare()
        let preview = model.preview
        model.save()

        XCTAssertEqual(generation, 1)
        XCTAssertEqual(try Data(contentsOf: destination), Data(preview.utf8))
        XCTAssertEqual(model.message, "Diagnostic export saved.")
    }

    func testFailuresExposeOnlyFixedGenericMessages() async {
        let preparation = DiagnosticExportModel(
            makeArtifact: { throw NSError(domain: "/private/path", code: 1, userInfo: [NSLocalizedDescriptionKey: "TOKEN_SECRET"]) }
        )
        await preparation.prepare()
        XCTAssertEqual(preparation.message, DiagnosticExportModel.preparationError)

        let save = DiagnosticExportModel(
            makeArtifact: { try self.artifact() },
            chooseDestination: { URL(fileURLWithPath: "/directory-that-does-not-exist/private.json") }
        )
        await save.prepare()
        save.save()
        XCTAssertEqual(save.message, DiagnosticExportModel.saveError)
    }

    private func artifact(build: Int = 1) throws -> DiagnosticExportArtifact {
        try DiagnosticExport.make(from: DiagnosticExportInput(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: DiagnosticVersion(major: 1, minor: 0, patch: 0),
            appBuild: build,
            operatingSystemVersion: DiagnosticVersion(major: 15, minor: 0, patch: 0),
            providerStatuses: [],
            databaseState: .available,
            importCounts: DiagnosticImportCounts(accepted: 0, rejected: 0),
            resourceLimitReasons: []
        ))
    }
}

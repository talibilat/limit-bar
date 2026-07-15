import Foundation
import LimitBarCore

do {
    let fixtures = try QuotaForecastFrozenCorpus.validatedFixtures()
    let report = try QuotaForecastReplayEvaluator.evaluate(fixtures)
    FileHandle.standardOutput.write(Data(QuotaForecastReplayMarkdown.render(report).utf8))
} catch {
    FileHandle.standardError.write(Data("Quota forecast evaluation failed.\n".utf8))
    exit(EXIT_FAILURE)
}

# LimitBar Issue 6 Azure JSONL Ingestion Design

## Context

Issue #6 adds the local Azure OpenAI integration.
Tools append confirmed response usage events to `~/Library/Application Support/LimitBar/usage-events.jsonl`, and LimitBar converts those events into the normalized metrics already rendered by the app.
The integration must be idempotent, tolerate malformed lines, and avoid Azure management APIs or invented quota data.

## Approved Approach

Treat the JSONL file as the source of truth and rebuild Azure metric snapshots from the complete file on each app refresh.
This avoids cursor state, duplicate imports, and recovery ambiguity when the file is edited, truncated, or replaced.
The importer replaces only Azure OpenAI rows and preserves metrics belonging to other providers.

## Event Contract

Each non-empty line is one JSON object with these fields:

- `provider`: must be `azureOpenAI`.
- `timestamp`: an ISO-8601 date and time.
- `model`: a non-empty string.
- `inputTokens`: a nonnegative integer.
- `outputTokens`: a nonnegative integer.
- `deployment`: an optional non-empty string.

Unknown fields are ignored so producers can add unrelated metadata without breaking ingestion.
Malformed JSON, incorrect provider values, missing required fields, invalid timestamps, empty required strings, and negative token counts are rejected independently without stopping later lines from being parsed.

## Core Components

`AzureUsageEventParser` parses JSONL data and returns valid typed events plus line-numbered diagnostics.
Diagnostics contain only a line number and safe validation reason; they never include raw event contents.

`AzureUsageEventImporter` filters valid events into Today and Current Week using an injected calendar and current date.
It aggregates token counts by time window, model, and optional deployment, creates fresh Azure OpenAI `UsageMetric` values, and sets every limit to `.unsupportedByProviderAPI`.
The latest included event timestamp becomes the aggregate refresh timestamp.

`AzureUsageEventImporter` resolves the Application Support path and reads the file.
It streams the file in bounded chunks and aggregates events as they are parsed rather than retaining the complete file or event list in memory.
Lines larger than 1 MiB are rejected and discarded through their next newline.
A missing file is a healthy empty integration result.
Other file read failures become safe diagnostics and leave existing stored metrics unchanged.

## Persistence And Idempotency

`SQLiteUsageMetricStore` gains a transactional operation that deletes existing Azure OpenAI rows and inserts the newly aggregated rows.
The transaction rolls back if replacement fails, preserving the last complete Azure snapshot.
Anthropic and OpenAI rows are never removed by Azure ingestion.
Re-importing unchanged JSONL produces the same stored rows and token totals.

The existing SQLite rows remain normalized display snapshots rather than raw event storage.
No prompt, response, request body, terminal output, source code, or raw JSON is persisted.

## App Integration

Application loading opens the existing Application Support SQLite store, applies retention and existing empty-store seeding, resolves the Azure JSONL path, replaces Azure rows from available events, and then loads the metrics shown in the popover.
The app performs file ingestion and SQLite work away from the main actor before publishing the resulting snapshot to SwiftUI.
Popover and settings refreshes share a serialized loader, and SQLite waits briefly for external writers instead of failing immediately with a busy error.
The replacement removes Azure demo rows even when the integration file is missing or empty, while other demo behavior remains unchanged until later provider issues remove it.
Calculated Azure cost continues to use the existing `CostCalculator` and configured provider/model pricing.

Settings adds an Integration section that displays the full JSONL path, provides a Reveal in Finder action, and shows accepted and rejected line counts plus safe rejection summaries.
The reveal action creates the containing directory when needed and reveals the file when it exists, otherwise it opens the containing directory.

## Error Handling

One malformed line cannot crash ingestion or prevent valid lines from being imported.
Line diagnostics are bounded to avoid an unbounded settings UI while the total rejected count remains accurate.
Missing files report zero accepted and rejected events.
Unreadable files and database replacement failures report safe errors and preserve the last confirmed metrics.

## Testing

Core parser tests cover valid required fields, optional deployment, malformed JSON, wrong provider, missing fields, invalid timestamp, empty model, negative tokens, unknown fields, and continued parsing after rejection.
Importer tests cover Today and Current Week boundaries, grouping by model and deployment, token totals, latest timestamps, unsupported limits, and deterministic repeated imports.
SQLite tests cover transactional Azure replacement and preservation of non-Azure rows.
File tests use temporary directories to verify path resolution and missing-file behavior.
Native build verification covers the settings integration and popover compilation.

## Out Of Scope

Azure management API integration, quota tracking, rate-limit tracking, arbitrary log scraping, local proxy capture, raw event persistence, incremental byte-offset tracking, and automatic file watching are out of scope.

## Acceptance Mapping

The path resolver, settings Integration section, and Finder action cover integration discoverability.
The parser and importer cover valid event mapping, malformed-line diagnostics, model grouping, optional deployment metadata, and SQLite persistence.
Existing pricing and popover paths provide calculated cost and Azure card display.
Every imported Azure row explicitly uses `Unsupported by provider API` for limit status.

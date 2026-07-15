# Quota Doctor Signed-App Acceptance Record

Status: **unavailable** until every required field below is completed from an actual run.

## Artifact

- Product version:
- Commit:
- ZIP filename and SHA-256:
- Developer ID identity and team:
- Notarization and stapling result:
- macOS version and hardware class:
- Adapter, client/API, schema, forecast, anomaly, explanation, export, alert, and planning method versions:

## Source Boundary

- Provider product:
- User-confirmed source version:
- Configured read/authentication boundary:
- Availability: available / unavailable
- Reason when unavailable:
- Confirmation that no credential, prompt, code, response, terminal output, request body, private path, account label, or raw payload was captured:

## Protocol

1. Verify the downloaded ZIP checksum, Developer ID signature, hardened runtime, notarization ticket, Gatekeeper result, bundle identifier, and absence of App Sandbox.
2. Launch the quarantined application through Finder.
3. Exercise passive authorization and confirm it cannot present authentication UI.
4. If authorization is required, use Connect and record the human-observed interactive authorization result without recording credential values or screenshots containing private content.
5. With the real supported source, verify observation ingestion, exact boundaries, deduplication, duplicate refresh, reset transition, counter decrease handling, and restart behavior.
6. Verify qualified and unavailable forecasts, attribution and unattributed states, anomaly and no-finding states, forensic traces, independent observation and finding deletion, export preview/save identity, alert qualification/deduplication, and planning availability boundaries where source evidence supports them.
7. Run `scripts/scan-prohibited-content.sh --sentinels <local-sentinel-file> <acceptance-artifact-directory>` before retaining any privacy-safe evidence.
8. Record unavailable steps as unavailable, never passed.

## Results

| Check | passed / failed / unavailable | Privacy-safe evidence reference | Limitation or blocker |
| --- | --- | --- | --- |
| Distribution identity | unavailable | | |
| Passive authorization | unavailable | | |
| Interactive authorization | unavailable | | |
| Real-source ingestion | unavailable | | |
| Deduplication and reset | unavailable | | |
| Forecast and anomaly | unavailable | | |
| Attribution states | unavailable | | |
| Forensic investigation | unavailable | | |
| Independent deletion | unavailable | | |
| Export and no upload | unavailable | | |
| Alert integration | unavailable | | |
| Planning boundary | unavailable | | |
| Prohibited-content scan | unavailable | | |

Reviewer and decision:

# Real-Account Keychain Authorization QA

## Status

Specified and prioritized; execution is blocked on ticket 01 external release acceptance and two stable signed artifacts.

## Dependency

Ticket 01 must provide the stable application identity used throughout testing.
The test inputs must be exact notarized artifacts produced by the release workflow, not local rebuilds.
For the first public release, two release-candidate artifacts with different versions but the same stable identity are sufficient for the update case.

## Problem

Fixture tests cannot prove how real Keychain authorization behaves across prompts, updates, identity changes, or recreated items.

## User Outcome

Users receive predictable Claude authorization behavior from a consistently signed app.

## Proposed Scope

Test passive checks, Connect, Check Again, Always Allow, signed app updates, changed identity, and a recreated Claude Keychain item against designated test accounts.
Document expected prompts, recoverable failures, and identity-related exceptions.

Run the blocking matrix on the oldest and newest macOS versions claimed as supported by the release candidate.
Use a standard macOS login Keychain and a credential item created by a currently supported Claude Code login.
Use a controlled alternate build only for changed-identity cases.

## Explicit Non-Goals

This ticket does not discover credentials automatically or export Keychain data.

## Privacy And Security

Use designated test accounts.
Do not commit credentials, Keychain exports, private paths, or provider responses.

Record only the macOS version, artifact version and checksum, declared signing identity, item state, action, prompt category, visible LimitBar state, and pass or fail result.
Transcribe only non-sensitive prompt wording when wording materially differs by macOS version.
Do not attach screenshots that expose account names, usernames, paths, tokens, provider data, or other private values.
Terminate LimitBar between cases that require a fresh process so its in-memory credential cache cannot hide a Keychain read.

## Data Model Impact

No product data-model change is required.

## Consolidated Grill Questions And Answers

1. **What evidence is this ticket intended to produce?**
   It produces manual, real-account evidence of macOS Keychain prompt policy and recovery behavior that fixture tests cannot provide.
   It does not replace the existing automated tests for query construction, status mapping, model state, or credential caching.
2. **What is a supported account configuration?**
   A designated test account is either signed out of Claude Code or signed in through a currently supported Claude Code release with a usable OAuth credential.
   Plan type is not a matrix dimension because LimitBar's authorization behavior is independent of Claude subscription type.
3. **What is a supported Keychain configuration?**
   The supported configuration is zero or one generic-password item with service `Claude Code-credentials` in the test user's standard login Keychain, created and managed by Claude Code.
   An item recreated by Claude Code remains supported and is treated as a new item for authorization purposes.
4. **Which configurations are diagnostic rather than supported?**
   Duplicate matching items, manually edited credential payloads, custom access-control lists, nonstandard keychains, migrated Keychain exports, and manually copied credentials are diagnostic only.
   They may be used to verify safe failure but must not define release acceptance.
5. **Which app artifacts are authoritative?**
   Use exact notarized and stapled release artifacts from the ticket 01 workflow, identified by version and SHA-256 checksum.
   Local Xcode, ad hoc, unsigned, and source-rebuilt apps are not evidence for stable-update acceptance.
6. **Which operating systems are blocking?**
   The latest patch release of the oldest supported major macOS version and the newest major macOS version claimed by the release candidate are blocking.
   Additional versions may be sampled but do not replace either boundary.
7. **What must passive actions do?**
   Opening the Claude view, pressing **Check Again**, and pressing **Refresh** must never cause authentication UI.
   With an inaccessible existing item they must show **Authorization Required** and a **Connect** action.
   With no item they must show the not-connected state.
8. **What must Connect do?**
   **Connect** is the only action in this flow permitted to request interactive Keychain authorization.
   If access is granted and the credential is usable, LimitBar must continue to the Claude rate-limit request.
9. **How should cancellation and denial behave?**
   Cancelling the prompt must leave the prior LimitBar state intact and permit a later retry.
   Denial or failed authentication may show the existing recoverable authorization-failed state, but must not expose secret or provider response content.
10. **What does Always Allow guarantee?**
    **Always Allow** should permit a relaunch of the same signed artifact to read the same Keychain item passively without another prompt.
    It is not treated as a permanent grant across a changed code identity or a recreated item.
11. **What should happen after a stable signed update?**
    An update that preserves the ticket 01 Apple team, bundle identifier `com.talibilat.LimitBar`, Developer ID signing class, and designated code requirement must passively read the previously authorized item without another prompt.
    Any prompt in this case is a release blocker until its identity cause is understood.
12. **Which identity changes require renewed authorization testing?**
    A different Apple team, a different bundle identifier, a different signing class or untrusted/ad hoc signature, and any changed designated code requirement are identity migrations and must be expected to require or deny access until the user authorizes the changed identity.
    Certificate renewal under the same Apple team is acceptable only if the resulting designated requirement remains compatible; this must be verified rather than inferred from the certificate name.
13. **What should happen when Claude Code recreates its item?**
    The recreated item has independent access control.
    Passive actions must not prompt, and **Connect** may require authorization again even when the prior item had **Always Allow**.
14. **How are malformed or expired credentials handled?**
    A malformed item must produce the safe existing message that the Claude Code login was not understood.
    A provider-rejected expired login must invalidate the process cache; recovery is to sign in again through Claude Code and retry passively or use **Connect** if authorization is required for the new item.
15. **How are unavailable or locked Keychain conditions handled?**
    LimitBar must show a recoverable safe failure and must not loop prompts.
    Unlocking the login Keychain or restoring normal Keychain availability followed by **Check Again** is the recovery path.
16. **How is process caching prevented from invalidating a result?**
    Fully terminate LimitBar before relaunch, update, identity-change, item-recreation, and post-authorization checks.
    A test that only closes and reopens the popover is insufficient because a future-expiry credential can remain cached in the running process.
17. **How should prompt differences across macOS versions be judged?**
    Exact wording and button labels are recorded as observations, not hard-coded requirements.
    Release acceptance depends on whether passive actions suppress UI, interactive authorization is user-initiated, the requesting app is identifiable, and the selected decision has the expected effect.
18. **What is the safe recovery guidance for users?**
    First retry with **Check Again** for a passive read.
    If LimitBar reports **Authorization Required**, use **Connect** and approve the identifiable signed LimitBar app.
    If the login is absent, malformed, or expired, repair it by signing in again through Claude Code rather than copying, editing, exporting, or committing Keychain data.
19. **What constitutes a blocker versus a documented exception?**
    A prompt from a passive action, failure of **Connect** for a standard supported item, loss of access after a stable signed update, misleading recovery UI, or exposure of sensitive data is a blocker.
    Renewed authorization after a deliberate identity migration or item recreation is an expected exception when passive actions remain non-interactive and **Connect** recovers access.
20. **Where is execution evidence recorded?**
    Record one privacy-reviewed Markdown result under `docs/qa/keychain-authorization/` for each release candidate.
    Keep expected results in this ticket and observed results in the dated execution record so an unrun expectation cannot be mistaken for evidence.

## Authorization Matrix

| Case | Initial state | Action | Expected result | Classification |
| --- | --- | --- | --- | --- |
| No item | Claude Code signed out and item absent | Open Claude view | No prompt; not-connected state with **Check Again** and **Connect** | Blocking |
| Existing unauthorized item | Valid Claude Code item with no LimitBar authorization | Open Claude view | No prompt; **Authorization Required** with **Connect** | Blocking |
| Passive retry | Existing unauthorized item | **Check Again** | No prompt; remains **Authorization Required** | Blocking |
| Passive refresh | Existing unauthorized item | **Refresh** | No prompt; remains **Authorization Required** | Blocking |
| Interactive cancellation | Existing unauthorized item | **Connect**, then cancel | Prompt appears only after **Connect**; prior state remains; retry is available | Blocking |
| Interactive denial | Existing unauthorized item | **Connect**, then deny or fail authentication | Safe recoverable failure; no sensitive content; later **Connect** can retry | Blocking |
| Interactive one-time grant | Existing unauthorized item, when the OS offers a one-time choice | **Connect**, then grant once | Current request succeeds; a later process may request authorization again | Observational |
| Persistent grant | Existing unauthorized item | **Connect**, then **Always Allow** | Current request succeeds | Blocking |
| Same-build relaunch | Existing item granted **Always Allow** | Terminate and relaunch the same artifact | Passive read succeeds without a prompt | Blocking |
| Stable signed update | Existing item granted **Always Allow** to artifact A | Replace A with higher-version artifact B carrying the same stable identity | Passive read succeeds without a prompt | Blocking |
| Changed identity | Existing item granted **Always Allow** to the stable identity | Launch a controlled build with one identity dimension changed | Passive read does not prompt; authorization is required or access is safely denied; **Connect** may prompt | Expected exception |
| Recreated item | Prior item granted **Always Allow**, then recreated by Claude Code | Terminate LimitBar and open the Claude view | Passive read does not prompt; **Connect** may require authorization again | Expected exception |
| Malformed item | Diagnostic test item with invalid payload | Perform passive check | No prompt; safe malformed-login failure | Diagnostic |
| Expired login | Provider rejects the credential as expired | Refresh, repair login in Claude Code, then retry | Cache is invalidated; safe failure precedes successful recovery | Blocking |
| Keychain unavailable | Login Keychain is unavailable or locked where reproducible | Perform passive check, restore availability, then **Check Again** | No prompt loop; safe failure followed by recovery | Diagnostic |

## Execution Protocol

1. Run `scripts/verify-keychain-qa-artifacts.sh OLD_ZIP OLD_SHA256 NEW_ZIP NEW_SHA256` to verify both artifacts before testing.
2. Create or reset only the designated macOS user and Claude test account state needed by the next matrix case.
3. Fully terminate LimitBar before every case whose initial state depends on a new process.
4. Run every blocking case on both supported macOS boundary versions.
5. Change only one identity dimension at a time in changed-identity diagnostics.
6. Record the prompt category and visible app state without recording credentials, provider responses, private paths, or account identifiers.
7. Restore the test account through Claude Code and remove controlled alternate builds after execution.
8. Classify deviations as blockers, expected identity exceptions, OS-version observations, or unsupported diagnostic behavior.

## Exit Criteria

- Every blocking matrix case passes on the oldest and newest supported macOS versions against the stable signed identity from ticket 01.
- A higher-version artifact with the same stable identity preserves passive access to an item previously granted **Always Allow**.
- Passive actions produce no authentication UI in every tested item state.
- Changed-identity and recreated-item behavior is recorded as observed evidence with the documented recovery guidance.
- The execution record identifies artifacts by checksum and contains no credentials, provider responses, private paths, or account identifiers.
- Any OS-specific prompt wording or identity exception is documented without weakening the passive-no-prompt or explicit-Connect requirements.

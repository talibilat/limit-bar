# Recovery Inbox

The Recovery Inbox is a local review-and-resume workflow for Claude Code and Codex tasks that stop at a provider-reported quota boundary.
It is not a scheduler and it never resumes provider work automatically.

## Safety Boundary

LimitBar stores no prompt, summary, code, response, command, terminal output, path, repository name, raw error, provider payload, credential, account identifier, project identifier, model identifier, or permission response.
LimitBar never sends `continue`, restores a queue, wakes a provider session, grants a permission, or executes deferred work without a fresh user confirmation.

A checkpoint contains exactly these version 2 fields:

- `schema_version`
- `product`
- `session_reference`
- `workspace_fingerprint`
- `client_version`
- `failure_class`
- `window_kind`
- `reset_boundary`
- `created_at`

Unknown fields and missing fields are rejected before anything is persisted.
The maximum import size is 8 KiB.
The accepted products are `claude-code` and `codex`.
The accepted failure classes are `quota_exhausted` and `rate_limited`.
The accepted privacy-safe quota window kinds are `session` and `weekly`.

## CLI Contract

Generate a content-free fingerprint from the current Git workspace:

```sh
limitbar recovery fingerprint --workspace "$PWD"
```

The command authenticates Git's commit identity, staged binary diff, unstaged binary diff, and untracked file bytes with the per-install key.
It authenticates that metadata with a random 256-bit per-install key and emits only `hmac-sha256-v1:` followed by 64 lowercase hexadecimal characters.
The key and digest prevent paths, repository names, and Git metadata from being reconstructed from the persisted fingerprint.
Content and path bytes exist only as transient HMAC input and are never emitted or retained by LimitBar.
This detects a dirty workspace changing to different dirty content even when Git reports the same coarse status.

Submit one strict checkpoint JSON object on standard input:

```sh
limitbar recovery import < checkpoint.json
```

The response is one coarse JSON object.
`accepted` means a new item was stored, `duplicate` means an identical retry already exists, and `conflict` means the same provider session and exact boundary were reused with different checkpoint values.
Conflicts and rejected payloads exit 65 and are not persisted.
Storage failures exit 74.
Responses never contain a session reference, fingerprint, path, or checkpoint identifier.

For isolated validation, `LIMITBAR_RECOVERY_INBOX_FILE` overrides the inbox file.
`LIMITBAR_RECOVERY_FINGERPRINT_KEY_FILE` similarly overrides the fingerprint key file for isolated fixtures.
Production data is stored atomically with mode `0600` in `~/Library/Application Support/LimitBar/recovery-inbox-v1.json`.
At most 100 checkpoints younger than 30 days are retained.
Users may dismiss or delete each item independently.

## Hook Examples

The examples are in `examples/recovery/`.
They require `jq` and the installed `limitbar` command.

The Claude Code adapter requires these structured environment values:

- `LIMITBAR_SESSION_REFERENCE`, set to the opaque local Claude Code session reference.
- `LIMITBAR_RESET_BOUNDARY`, set to the exact ISO 8601 boundary reported by Claude Code.
- `CLAUDE_CODE_VERSION`, set to the client version.
- `LIMITBAR_QUOTA_WINDOW_KIND`, set to the exhausted `session` or `weekly` quota window kind.

The Codex adapter requires these structured environment values:

- `LIMITBAR_SESSION_REFERENCE`, set to the opaque local Codex session reference.
- `LIMITBAR_RESET_BOUNDARY`, set to the exact ISO 8601 boundary reported by Codex.
- `CODEX_VERSION`, set to the client version.
- `LIMITBAR_QUOTA_WINDOW_KIND`, set to the exhausted `session` or `weekly` quota window kind.

`LIMITBAR_WORKSPACE` may select the workspace and defaults to the hook's current directory.
`LIMITBAR_CLI` may select the signed executable and defaults to `limitbar` on `PATH`.

Only install an adapter at a provider lifecycle point that supplies an exact structured reset boundary.
If a client or hook exposes only prose, an elapsed timer, a raw error, or no exact boundary, do not derive or guess a boundary and do not create a checkpoint.
The supplied scripts deliberately fail closed when a required structured value is absent.
They do not forward provider hook JSON or notify payloads to LimitBar.

`examples/recovery/claude-settings.json.example` shows the explicit Claude Code command-hook shape.
`examples/recovery/codex-config.toml.example` shows the explicit Codex notify-command shape.
Replace the placeholder with an absolute adapter path and configure the required values in your own provider-owned hook adapter.
LimitBar never edits provider configuration.
Remove the hook entry to uninstall it.

## Readiness

Crossing the checkpoint's local-clock time does not make an item ready.
LimitBar requires a fresh Capacity Gate observation for the same Provider product and privacy-safe quota window kind that was measured at or after the checkpoint's exact reset boundary.
The observation must have an active later exact boundary, unexpired freshness, measured use below the Capacity Gate pause threshold, and no active provider incident overlap.

Missing evidence, stale evidence, a timer crossing, a changed pre-reset boundary, an expired boundary, exhausted measured capacity, or an active incident cannot establish readiness.
LimitBar reevaluates after Capacity Gate publication, app restart, Local Refresh, and machine wake.
If the machine sleeps through a boundary, only a fresh post-wake observation can establish readiness.

## Workspace Review

LimitBar does not persist a workspace path.
Select the relevant workspace during review.
LimitBar regenerates its keyed content-free fingerprint in memory and reports one of these states:

- Workspace unchanged.
- Workspace changed.
- Workspace deleted or unavailable.
- Workspace not reviewed.

A changed workspace remains visibly changed and requires the same fresh resume confirmation.
A deleted or unavailable workspace withholds resume.
Because no path is retained, use the explicit `Workspace Deleted` action when the former location no longer exists.
During review, LimitBar keeps the canonical workspace URL, filesystem device and inode, and keyed fingerprint only in memory.
The pending confirmation is bound to that exact reviewed workspace identity.
Immediately before launch, LimitBar verifies that the canonical directory still exists, has the same device and inode, and produces the same fingerprint.
A changed, deleted, replaced, or newly redirected workspace withholds launch and requires a new review.

The review also distinguishes stale Capacity Gate evidence, a changed reset boundary, session revalidation required, an expired session, an unsupported client version, and an unavailable resume command.
No documented read-only provider command currently proves that either provider-owned session still exists without attempting resume.
The user must therefore explicitly revalidate session existence immediately before each launch, and that confirmation expires after 60 seconds.
The `Session Expired` action remains explicit because provider session stores and expiry rules remain provider-owned.
LimitBar does not inspect or reconstruct provider session content.

## Resume Commands

LimitBar supports only the documented provider-owned forms:

The Claude Code form is documented in the [Claude Code CLI reference](https://docs.anthropic.com/en/docs/claude-code/cli-reference).
The Codex form is documented in the [Codex developer command reference](https://developers.openai.com/codex/developer-commands?surface=cli#cli-codex-resume).

```sh
claude --resume SESSION_REFERENCE
codex resume SESSION_REFERENCE
```

The review resolves only fixed absolute candidate paths and validates the selected executable as a non-symbolic executable regular file.
The review displays that exact absolute executable and arguments before action is available.
Selecting `Validate & Resume...` revalidates the session and opens a second confirmation that repeats the exact action.
Only `Confirm Session and Launch` launches that exact executable directly with a structured argument array.
LimitBar performs no shell interpolation and rechecks the executable's device, inode, size, and SHA-256 immediately before launch.
The provider process receives the exact reviewed canonical workspace as its current directory.
Cancellation launches nothing.
LimitBar records only that the explicit launch was accepted and does not monitor, retry, queue, or interpret provider execution.

If the provider command is absent, the client version is unsupported, the session expired, or the workspace is unavailable, LimitBar withholds launch rather than guessing.

## Notifications And Diagnostics

The notification title is `Recovery item ready`.
The notification body is `Fresh capacity is available. Review local state before resuming.`
No Provider product, account, project, repository, path, model, session, task, fingerprint, or boundary appears in notification text or notification identifiers.
Each ready item uses its random local inbox UUID so multiple ready items receive distinct privacy-safe notification identifiers.
One notification is accepted per ready checkpoint revision.

Recovery checkpoints are outside the diagnostic export positive allow-list.
Opaque session references, fingerprints, checkpoint identifiers, workspace state, and resume commands are not included in diagnostics, logs, analytics, or notification content.
Deleting diagnostic or quota history does not expose or alter Recovery Inbox checkpoints.

## State Machine

The persisted states are waiting, ready for review, changed workspace, unavailable, expired, dismissed, and resumed.
Unavailable states carry only a typed coarse reason.
Dismissed, expired, and resumed states cannot return to actionable states.
An identical hook retry is a duplicate rather than a new state transition.
A conflicting retry is rejected.

Checkpoints become non-actionable and visibly expired after 14 days.
Items older than 30 days and items beyond the newest 100 are removed during bounded maintenance.
Deleting an item removes it immediately and independently of dismissal.

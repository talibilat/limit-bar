# LimitBar

LimitBar presents local and provider-supplied usage information without creating a LimitBar account or copying private interaction content into its metrics.

## Language

**Authorization Check**:
An attempt to access the existing Claude Code credential.

**Passive Authorization Check**:
An Authorization Check that does not permit macOS to present authentication UI.
_Avoid_: Background authorization, silent login

**Interactive Authorization Request**:
An explicit Authorization Check that permits macOS to present authentication UI.
_Avoid_: Forced prompt

**Connect Action**:
The user action that starts an Interactive Authorization Request.
_Avoid_: Connect affordance

**Authorization Required**:
The state in which a Passive Authorization Check cannot access the Claude Code credential without user-authorized interaction.

**Custom Usage Source**:
A named, user-configured local JSONL file that supplies normalized usage events.
_Avoid_: Local source, custom log

**Local Usage Events**:
Normalized built-in usage events imported from LimitBar's standard local JSONL file.
_Avoid_: Custom Usage Source events

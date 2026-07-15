# Forensic Investigation

The forensic investigation is a subordinate detail surface for normalized Claude Code and Codex quota evidence.
It is not another quota gauge and does not acquire provider evidence itself.

## Publication

An investigation publication is produced only after local evidence and the Claude Code and Codex analyses for one Local Refresh Cycle have settled.
The publication carries the Local Refresh Cycle sequence as its generation.
While another generation is loading, LimitBar retains the prior coherent publication and labels it as retained.
If the newer generation fails, LimitBar retains the prior products and reports the failed generation without combining its partial results.

## Product Attribution

Collector schema v2 identifies a Provider but does not identify a provider product.
An Anthropic Provider event therefore cannot be assumed to be Claude Code activity.
An OpenAI Provider event therefore cannot be assumed to be Codex activity.
Generic API attribution breakdowns are excluded from Claude Code and Codex subscription investigations.
Project, agent, session, operation, and tool dimensions remain unavailable until product-explicit normalized evidence supplies them.

## Provenance

Claude Code percentage observations supplied by the provider are Reported.
Codex percentage observations read from supported local reports are Measured.
Movement between compatible percentage observations is Calculated.
Observed Local Breakdowns remain separate from quota movement and never become an authoritative total.
Inferred allocation is shown only when an existing analysis explicitly supplies it.

## Time And Traceability

Selected ranges are half-open and use exact ISO timestamps on a Gregorian UTC basis.
Evidence intersects a selected range only when its end is after the selected start and its start is before the selected end.
Provider-reported resets are shown exactly, while absent reset evidence remains unavailable.
Trace details expose only bounded observation digest prefixes or hashes of privacy-safe normalized evidence identities.
Raw prompts, code, responses, terminal output, paths, credentials, account labels, cookies, and provider payloads are never investigation inputs.

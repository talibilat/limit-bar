# Preserve provider quota-window identity

LimitBar represents provider quota windows by their provider-product scope and reported reset boundary instead of coercing them into local day or week usage windows.
Claude Code and Codex do not always report an exact start, and inventing one from a nominal duration would make deduplication look more certain than the source data permits.
Quota observations without a valid future reset boundary remain visible where appropriate but are ineligible for alerts.

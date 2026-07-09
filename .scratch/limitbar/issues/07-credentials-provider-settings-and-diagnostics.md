# Add Credential Storage, Provider Settings, And Diagnostics

Status: ready-for-agent
Labels: ready-for-agent

## Parent

`.scratch/limitbar/PRD.md`

## What to build

Add the secure provider configuration layer required before live provider integrations.
The settings window should support provider auth configuration, connection health, and diagnostics for Anthropic, Azure OpenAI, and OpenAI.
Credentials must be stored only through macOS Keychain and never exposed through local files, SQLite, diagnostics, or exports.

This issue should introduce the provider auth model and safe diagnostics plumbing, but it does not need to complete live Anthropic or OpenAI usage refresh.
It should make missing, connected, failed, expired, unsupported, and admin-required states representable in the UI.

## Acceptance criteria

- [ ] Provider settings exist for Anthropic, Azure OpenAI, and OpenAI.
- [ ] Anthropic supports an Admin API key auth path and an OAuth-compatible auth model for future extension.
- [ ] Azure OpenAI supports API key metadata storage.
- [ ] OpenAI supports an OAuth feasibility state model.
- [ ] Secrets are saved only to macOS Keychain.
- [ ] Settings never display raw API keys, access tokens, or refresh tokens after save.
- [ ] Diagnostics can show missing, connected, failed, expired, unsupported, and admin-required states.
- [ ] Diagnostics can show provider refresh errors without exposing secrets.
- [ ] Exports or diagnostics exclude API keys, OAuth access tokens, OAuth refresh tokens, prompts, responses, terminal output, source code, and raw provider responses.
- [ ] Tests use a fake credential store rather than the real user Keychain where possible.

## Blocked by

- https://github.com/talibilat/limit-bar/issues/1
- https://github.com/talibilat/limit-bar/issues/2

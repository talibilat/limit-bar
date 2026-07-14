# 08 - Add Forensic Investigation View

## Parent

Source plan: `futures/01-quota-doctor.md`.

## What to build

Add a forensic investigation surface within LimitBar that explains quota evidence for a user-selected provider product and time range.
The view must combine quota movement, attribution, forecasts, anomalies, provider-reported resets, relevant client versions when available, and evidence gaps into one traceable investigation workflow.
The surface must explain what LimitBar knows, how it knows it, what is calculated or inferred, and what cannot be concluded safely.
It must deepen the existing product rather than create another menu-bar quota gauge.

## Confirmed starting point

The parent specification describes concise existing rate-limit rows that may continue to show measured usage and qualified forecast summaries.
The existing Quota Insights foundation described by the parent includes measured percentage observations, exact quota-window identities, provider-reported reset boundaries, qualified forecast ranges, unavailable forecast states, and measured and calculated labels.
The parent specification requires a deeper forensic surface for explanations, attribution, anomalies, and evidence gaps.
The parent specification requires the first product surface to integrate with LimitBar.
The parent specification does not prescribe a final navigation model, visual hierarchy, chart type, or default time range.
Ticket 03 is expected to provide the Claude Code explanation path when a trustworthy explicitly identified source exists.
Ticket 04 is expected to provide one documented API-provider quota path or a factual unavailable decision when no candidate satisfies the evidence contract.
Ticket 05 is expected to provide measured project and agent attribution through a versioned producer contract.
Ticket 06 is expected to provide versioned and evaluated forecast findings.
Ticket 07 is expected to provide versioned anomaly findings and explicit unavailable outcomes.
The view must consume those capabilities rather than reimplementing their analytical rules.

## Scope

- Add an investigation entry point that is discoverable from the existing LimitBar experience and remains visually subordinate to concise status rows.
- Provide an explicit provider-product selector based only on provider products for which normalized quota evidence exists.
- Provide an explicit time-range selector with exact displayed start and end boundaries.
- Make the timezone or calendar basis visible wherever it changes interpretation of the selected range.
- Preserve the user's provider and time-range selection while the investigation remains open when doing so does not expose private values outside the view.
- Show a coherent chronological account of quota movement within the selected range.
- Distinguish provider-supplied quota values from changes deterministically calculated between observations.
- Mark provider-reported reset boundaries and avoid drawing a continuous consumption trend across a reset.
- Show unknown reset evidence as unavailable rather than placing an inferred exact reset marker.
- Present attribution for project, session, model, agent, operation, and tool type only when those dimensions are available through privacy-safe supported evidence.
- Distinguish an authoritative provider total from an Observed Local Breakdown.
- Show unattributed quota movement when the provider total exceeds or cannot safely be associated with local evidence.
- Show inferred allocation separately from measured local activity and explain the allocation method and limitations.
- Avoid adding an Observed Local Breakdown to an authoritative provider total as if it were additional consumption.
- Present qualified burn-rate and exhaustion forecasts with their range, evidence age, observation count, observation span, method version, reset interaction, and qualification state.
- State that exhaustion is not projected before reset when the qualified forecast reaches that conclusion.
- Present forecast analysis as unavailable, with the relevant reason, when input evidence does not qualify.
- Present anomaly findings with their current comparison period, trailing baseline period, measured inputs, method version, direction, magnitude or score, qualification, and limitations.
- Present anomaly analysis as unavailable or as no finding without conflating those outcomes.
- Show relevant adapter or client-version changes when version data is available and intersects the selected evidence.
- Explain that version information is unavailable when it was not captured rather than implying that no version change occurred.
- Highlight evidence gaps, stale evidence, partial coverage, incompatible evidence, counter decreases, out-of-order evidence, and source interpretation changes when they affect the investigation.
- Distinguish a Gap from an Observed Zero throughout summaries, timelines, charts, tables, accessibility descriptions, and empty states.
- Distinguish a genuinely empty selected range from a range containing evidence that cannot be compared safely.
- Provide details that trace a displayed finding to its bounded source observations, comparison periods, method metadata, and limitations without exposing prohibited raw content.
- Keep exact timestamps and exact provider-reported boundaries available even when the primary presentation uses a more compact label.
- Use ranges and qualified language where evidence does not support point precision.
- Avoid visual interpolation through missing intervals that would make a Gap resemble an Observed Zero or continuous measurement.
- Make refresh age and last available observation time visible when freshness affects interpretation.
- Handle an active refresh without mixing partially refreshed local and provider evidence into a published investigation state.
- Preserve the last coherent published investigation while a new result is loading, or clearly show that no coherent result is yet available.
- Provide useful empty, loading, unavailable, error, and partial-evidence states.
- Ensure an error in one analysis section does not cause unrelated qualified evidence to be presented as missing or zero.
- Support keyboard navigation, assistive technology labels, text scaling, reduced motion, and color-independent status communication.
- Ensure the investigation is readable at the smallest supported window and display size without clipping critical provenance or qualification text.
- Keep Reported, Measured, Calculated, and Inferred language explicit wherever values and conclusions appear.
- Label provider-supplied values as Reported.
- Label values directly observed from supported sources as Measured.
- Label deterministic derived movement, baselines, rates, ranges, and scores as Calculated.
- Label estimates or allocations based on incomplete evidence as Inferred.
- Never present an Inferred value as Reported or Measured merely because it appears beside authoritative evidence.

## Acceptance criteria

- [ ] A user can open the forensic investigation from within LimitBar without launching a separate gauge application.
- [ ] A user can select one supported provider product and an exact time range.
- [ ] The selected range displays exact boundaries and the relevant timezone or calendar basis.
- [ ] The view shows quota movement in chronological order and separates movement across provider-reported resets.
- [ ] The view does not infer or display an exact reset boundary when the provider did not report one.
- [ ] The view shows an authoritative provider total separately from every Observed Local Breakdown.
- [ ] The view shows unattributed movement instead of forcing all provider movement onto known local activity.
- [ ] Inferred allocation is visibly distinct from measured local attribution and includes its method and limitations.
- [ ] Attribution dimensions appear only when supported privacy-safe evidence supplies them.
- [ ] Qualified forecasts show a range, evidence age, observation count, observation span, method version, qualification, and reset interaction.
- [ ] Forecasts that do not qualify display unavailable and the applicable reason without displaying a point estimate.
- [ ] Qualified anomalies show their current period, baseline period, measured inputs, method version, result, qualification, and limitations.
- [ ] No anomaly finding and unavailable anomaly analysis are visibly distinct states.
- [ ] Relevant client or adapter versions appear when available and are associated with the correct evidence interval.
- [ ] Missing version data appears as unavailable and is not represented as proof that versions were unchanged.
- [ ] Gaps are visible and are never rendered as zero consumption or as an uninterrupted line.
- [ ] Observed Zero values remain visible as trustworthy zero-valued evidence and are not styled as Gaps.
- [ ] Stale, partial, incompatible, reset-affected, and otherwise unsafe evidence states explain why a conclusion is unavailable.
- [ ] Every displayed derived finding can reveal its method version, evidence range, and known limitations.
- [ ] Reported, Measured, Calculated, and Inferred labels remain visible or directly accessible at the point where a user interprets each value.
- [ ] Inferred values never use presentation language or styling that implies provider reporting.
- [ ] The view uses ranges and qualifications instead of unsupported precision.
- [ ] Refresh behavior never presents a mixture of partially published evidence as one coherent investigation result.
- [ ] Failure of one section preserves other independently qualified sections and communicates the local failure.
- [ ] Empty, loading, unavailable, error, and partial-evidence states are distinct and actionable where an action exists.
- [ ] The workflow is fully usable by keyboard and exposes meaningful assistive-technology names, values, and state descriptions.
- [ ] Provenance and status are understandable without relying on color alone.
- [ ] Text scaling and reduced-motion settings preserve access to all critical evidence and controls.
- [ ] The smallest supported presentation does not clip provider selection, time-range selection, finding qualification, or evidence-gap explanations.
- [ ] The view exposes no prohibited raw content through visible text, accessibility values, tooltips, errors, or diagnostics.

## Privacy and safety constraints

- The forensic view must read only normalized, allow-listed local evidence and derived findings.
- The view must not display or request raw prompts, code, model responses, terminal output, request bodies, credentials, browser cookies, private paths, account labels, or raw provider payloads.
- Private source identifiers must be represented only by configured names or privacy-safe stable identifiers approved for product display.
- Error messages and evidence details must not reveal prohibited source content or private storage locations.
- The view must not create a new network upload path.
- The view must not imply causal attribution where the evidence supports only temporal correlation or inferred allocation.
- The view must not imply knowledge of undisclosed provider capacity, weighting, or billing behavior.
- Unsafe denominator or baseline comparisons must appear as unavailable with no finding.
- Deletion of quota observations or derived findings must be reflected without leaking stale details from a previous investigation result.

## Explicit non-goals

- Creating a second menu-bar quota gauge.
- Implementing provider adapters, evidence normalization, attribution algorithms, forecast algorithms, or anomaly algorithms inside the presentation layer.
- Adding workload planning controls or completion assessments.
- Adding alert-rule configuration or notification delivery.
- Exporting the investigation or adding automatic report upload.
- Displaying raw source payloads for debugging.
- Claiming every provider quota change has a known local cause.
- Inferring an exact reset boundary that the provider did not report.
- Adding browser automation or scraping private provider pages.
- Replacing official provider billing or quota interfaces.

## Verification

- Exercise the complete user workflow from opening LimitBar through selecting a provider product, selecting a time range, reviewing evidence, and changing the selection.
- Verify the workflow with representative evidence containing quota movement, attribution, forecasts, anomalies, resets, version changes, unattributed movement, and Gaps.
- Verify separate fixtures for all-available, partial-evidence, no-evidence, stale-evidence, incompatible-version, and analytical-error states.
- Verify an Observed Zero beside a Gap and confirm that visual, textual, and accessibility representations remain distinct.
- Verify a provider-reported reset and confirm the view does not connect pre-reset and post-reset movement as one trend.
- Verify absent reset data and confirm the view does not invent a boundary.
- Verify concurrent local activities under one account-level quota and confirm that the view does not assert unsupported causation.
- Verify inferred allocation and unattributed movement remain separate from Measured attribution and Reported provider values.
- Verify forecasts and anomalies preserve method versions, exact evidence periods, qualification, and limitations from their source results.
- Verify an unsafe forecast, denominator, or anomaly baseline produces unavailable with no numerical finding.
- Verify refresh publication atomically from the user's perspective, including a refresh that fails after an earlier coherent result exists.
- Verify keyboard-only operation, focus order, screen-reader descriptions, text scaling, increased contrast, reduced motion, and color-independent communication.
- Verify desktop and smallest supported presentation sizes with no clipped controls, provenance, limitations, or gap indicators.
- Verify prohibited-content sentinels do not appear in visible content, accessibility content, errors, tooltips, copied descriptions, or logs generated by the view.
- Run native application acceptance with supported local sources and document that synthetic fixtures alone do not establish real-account behavior.

## Blocked by

- 03 - [#26](https://github.com/talibilat/limit-bar/issues/26) - Explain Claude Code Quota Movement.
- 04 - [#27](https://github.com/talibilat/limit-bar/issues/27) - Add API Provider Quota Path.
- 05 - [#28](https://github.com/talibilat/limit-bar/issues/28) - Attribute Project And Agent Work.
- 07 - [#29](https://github.com/talibilat/limit-bar/issues/29) - Detect Quota Consumption Anomalies.

## Status

ready-for-agent

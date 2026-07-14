# LimitBar

LimitBar presents locally observed AI usage, provider quotas, and costs without treating estimates as provider records.
This glossary distinguishes the observations LimitBar receives from the policies users configure around them.

## Language

**Usage**:
Measured token, request, credit, or monetary consumption.

**Quota**:
A provider-controlled allowance or capacity constraint.
_Avoid_: Budget, usage limit

**Quota window**:
A provider-defined period over which a quota applies and whose reset boundary is reported rather than inferred.
_Avoid_: Usage window, budget period

**Rate-limit usage**:
Consumption within a quota window, commonly represented as a percentage.
_Avoid_: Budget usage

**Provider product**:
The monitored provider surface, such as Claude Code, Codex, Anthropic API, OpenAI API, or Azure OpenAI.
_Avoid_: Provider, when the company and product could differ

**Cost budget**:
A user-configured monetary cap for an exact period and one cost provenance.
_Avoid_: Provider quota, spend threshold

**Spend threshold**:
An absolute accumulated monetary amount that triggers an alert without implying a budget cap.
_Avoid_: Budget

**Alert rule**:
A user preference defining an alert subject, scope, thresholds, and whether it is enabled.

**Alert candidate**:
A qualifying observation that has not yet passed delivery-ledger checks.
_Avoid_: Delivered alert

**Delivery ledger**:
Durable local state recording which rule thresholds have been accepted for delivery in an exact subject window.
_Avoid_: Notification history

**Reported**:
Supplied directly by a provider.
_Avoid_: Confirmed, when describing calculated values

**Measured**:
Directly observed from a supported local or provider source.

**Calculated**:
Deterministically derived from measured data and explicit pricing.
_Avoid_: Reported, invoiced

**Inferred**:
Estimated from incomplete evidence and never presented as an official quota.
_Avoid_: Confirmed

**Fresh**:
A source-specific, age-qualified observation whose exact boundary remains active and which is safe for notification.

**Exact boundary**:
A provider-reported or calendar-resolved reset boundary that LimitBar did not guess.
_Avoid_: Estimated reset

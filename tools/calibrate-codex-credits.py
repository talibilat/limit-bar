#!/usr/bin/env python3
"""Calibrate a Codex credits-per-token estimate from a monthly org export.

Codex's per-user rate-limit payload does not expose a credits balance for
seat-based org plans (see README > Claude Rate Limits / Codex analytics
notes) - the credit ledger lives entirely in the workspace admin export.
When that export is dropped in codex/ (see .gitignore - never commit it,
it contains coworker names, emails, and productivity data), this script
derives one person's personal blended credits-per-1M-tokens rate from
leaderboard-users-*.csv (that row's Credits / Tokens for the export
window) and writes it into LimitBar's own Pricing store as a
currencyCode: "credits" PricingEntry, so the existing Cost / Calculated
estimate rendering in the Usage tab picks it up with no app changes.

The rate is a personal blended average (input + output + cached input
combined) because the export's per-model/per-metered-item credit
breakdown is workspace-wide, not per-user, so a personal per-model split
is not recoverable from this data. It is applied to every model label
already tracked locally for the openAI provider (see
tools/export-local-usage.py), so it covers whatever Codex model you
actually used, not just the model active when you last calibrated.

Re-running with a newer export simply replaces the prior credits
PricingEntry set for provider openAI - it does not touch other
currencies (e.g. a manually entered USD OpenAI price) and does not
touch Anthropic or Azure OpenAI pricing.
"""

import argparse
import csv
import datetime
import json
import subprocess
import sys
from pathlib import Path

DEFAULT_BUNDLE_ID = "com.talibilat.LimitBar"
DEFAULT_STORAGE_KEY = "LimitBar.pricingEntriesJSON"
MAC_EPOCH = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)


def find_leaderboard_csv(codex_dir):
    matches = sorted(codex_dir.glob("leaderboard-users_*.csv"))
    if not matches:
        raise SystemExit(f"No leaderboard-users_*.csv found under {codex_dir}")
    return matches[-1]


def parse_window_start(csv_path):
    # Filenames look like leaderboard-users_workspace-<slug>_2026-06-12-to-2026-07-11.csv
    stem = csv_path.stem
    date_part = stem.rsplit("_", 1)[-1]
    start_text = date_part.split("-to-")[0]
    return datetime.datetime.strptime(start_text, "%Y-%m-%d").date()


def find_user_row(csv_path, email):
    with open(csv_path, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            if row.get("Email", "").strip().lower() == email.strip().lower():
                return row
    raise SystemExit(f"No row for {email} in {csv_path.name}")


def local_openai_model_labels(usage_events_path):
    labels = set()
    if not usage_events_path.exists():
        return labels
    with open(usage_events_path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("provider") == "openAI" and event.get("model"):
                labels.add(event["model"])
    return labels


def mac_epoch_seconds(day):
    local_tz = datetime.datetime.now().astimezone().tzinfo
    local_midnight = datetime.datetime(day.year, day.month, day.day, tzinfo=local_tz)
    return (local_midnight - MAC_EPOCH).total_seconds()


def read_current_entries(bundle_id, storage_key):
    result = subprocess.run(
        ["defaults", "read", bundle_id, storage_key],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return []
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return []


def write_entries(bundle_id, storage_key, entries):
    payload = json.dumps(entries, sort_keys=True, separators=(",", ":"))
    subprocess.run(
        ["defaults", "write", bundle_id, storage_key, "-string", payload],
        check=True,
    )
    return payload


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--codex-dir", type=Path, default=Path(__file__).resolve().parent.parent / "codex")
    parser.add_argument("--email", required=True, help="Your email as it appears in leaderboard-users_*.csv")
    parser.add_argument("--usage-events", type=Path,
                         default=Path.home() / "Library/Application Support/LimitBar/usage-events.jsonl")
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--storage-key", default=DEFAULT_STORAGE_KEY)
    parser.add_argument("--dry-run", action="store_true", help="Print the computed entries without writing them")
    args = parser.parse_args()

    csv_path = find_leaderboard_csv(args.codex_dir)
    row = find_user_row(csv_path, args.email)
    credits = float(row["Credits"])
    tokens = float(row["Tokens"])
    if tokens <= 0:
        raise SystemExit(f"{args.email} has zero tokens in {csv_path.name}; nothing to calibrate")
    rate_per_million = credits / tokens * 1_000_000

    window_start = parse_window_start(csv_path)
    effective_at = mac_epoch_seconds(window_start)

    model_labels = local_openai_model_labels(args.usage_events)
    if not model_labels:
        print(f"No local Codex/openAI usage found in {args.usage_events}; nothing to calibrate against.", file=sys.stderr)
        return 1

    new_entries = [
        {
            "currencyCode": "credits",
            "effectiveAt": effective_at,
            "inputPricePerMillionTokens": round(rate_per_million, 10),
            "outputPricePerMillionTokens": round(rate_per_million, 10),
            "modelLabel": model,
            "provider": "openAI",
        }
        for model in sorted(model_labels)
    ]

    existing = read_current_entries(args.bundle_id, args.storage_key)
    kept = [e for e in existing if not (e.get("provider") == "openAI" and e.get("currencyCode") == "credits")]
    combined = kept + new_entries

    print(f"Calibrated from {csv_path.name}: {row['Name']} <{args.email}>")
    print(f"  {credits:,.4f} credits / {tokens:,.0f} tokens = {rate_per_million:.6f} credits per 1M tokens")
    print(f"  Applying to model(s): {', '.join(sorted(model_labels))}")
    print(f"  Effective from: {window_start.isoformat()}")

    if args.dry_run:
        print(json.dumps(combined, indent=2, sort_keys=True))
        return 0

    write_entries(args.bundle_id, args.storage_key, combined)
    print(f"Wrote {len(new_entries)} credits pricing entr{'y' if len(new_entries) == 1 else 'ies'} to {args.bundle_id}.")
    print("Restart LimitBar (or reopen the popover) to see the updated estimate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

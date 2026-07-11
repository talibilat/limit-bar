#!/usr/bin/env python3
"""Export confirmed local agent token usage into LimitBar's JSONL file.

Reads three local sources and rewrites LimitBar's usage-events.jsonl
atomically from them as the source of truth:

- Opencode (~/.local/share/opencode/opencode.db): assistant messages from
  the azure provider become azureOpenAI events. Opencode stores cached
  prompt tokens and reasoning tokens separately, so confirmed input is
  input + cache.read + cache.write and confirmed output is
  output + reasoning (verified against Opencode's own stored totals).
- Claude Code (~/.claude/projects/**/*.jsonl): assistant messages become
  anthropic events. Confirmed input is input_tokens plus cache creation and
  cache read tokens. Retries and per-content-block lines repeat the same
  message, so entries are deduplicated by message and request identity,
  keeping the last occurrence.
- Codex (~/.codex/sessions/**/*.jsonl): token_count events become openAI
  events. Per-turn usage is derived from the cumulative session totals so
  repeated snapshots never double-count; when totals reset (compaction),
  the event's own last_token_usage is used. Codex input_tokens already
  include cached tokens and output_tokens already include reasoning.

Re-running is always safe: the file is fully regenerated, never appended.
This exporter owns usage-events.jsonl. If other tools also need to write
events into it, merge them here instead of appending externally.
"""

import argparse
import json
import os
import sqlite3
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

DEFAULT_OPENCODE_DB = Path.home() / ".local/share/opencode/opencode.db"
DEFAULT_CLAUDE_PROJECTS = Path.home() / ".claude/projects"
DEFAULT_CODEX_SESSIONS = Path.home() / ".codex/sessions"
DEFAULT_OUTPUT = Path.home() / "Library/Application Support/LimitBar/usage-events.jsonl"
# LimitBar imports Today and Current Week windows only; nine days always covers both.
DEFAULT_DAYS = 9


def format_timestamp(moment):
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def event(provider, timestamp, model, input_tokens, output_tokens):
    return {
        "provider": provider,
        "timestamp": format_timestamp(timestamp),
        "model": model,
        "inputTokens": input_tokens,
        "outputTokens": output_tokens,
    }


def opencode_events(db_path, since):
    if not db_path.exists():
        return
    connection = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        rows = connection.execute(
            "SELECT time_created, data FROM message WHERE time_created >= ? ORDER BY time_created",
            (int(since.timestamp() * 1000),),
        )
        for time_created, data in rows:
            try:
                message = json.loads(data)
            except json.JSONDecodeError:
                continue
            if message.get("role") != "assistant" or message.get("providerID") != "azure":
                continue
            tokens = message.get("tokens") or {}
            cache = tokens.get("cache") or {}
            input_tokens = int(tokens.get("input") or 0) + int(cache.get("read") or 0) + int(cache.get("write") or 0)
            output_tokens = int(tokens.get("output") or 0) + int(tokens.get("reasoning") or 0)
            if input_tokens <= 0 and output_tokens <= 0:
                continue
            model = str(message.get("modelID") or "").strip()
            if not model:
                continue
            completed_ms = (message.get("time") or {}).get("completed") or time_created
            yield event(
                "azureOpenAI",
                datetime.fromtimestamp(completed_ms / 1000, tz=timezone.utc),
                model,
                input_tokens,
                output_tokens,
            )
    finally:
        connection.close()


def recent_jsonl_files(root, since):
    if not root.exists():
        return
    for path in root.rglob("*.jsonl"):
        try:
            if path.stat().st_mtime >= since.timestamp():
                yield path
        except OSError:
            continue


def parse_iso_timestamp(text):
    try:
        moment = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except (TypeError, ValueError, AttributeError):
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment


def claude_code_events(projects_root, since):
    latest_by_key = {}
    for path in recent_jsonl_files(projects_root, since):
        try:
            with open(path, encoding="utf-8") as handle:
                for line in handle:
                    try:
                        entry = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if entry.get("type") != "assistant":
                        continue
                    message = entry.get("message") or {}
                    usage = message.get("usage") or {}
                    model = str(message.get("model") or "").strip()
                    if not usage or not model or model == "<synthetic>":
                        continue
                    timestamp = parse_iso_timestamp(entry.get("timestamp"))
                    if timestamp is None or timestamp < since:
                        continue
                    input_tokens = (
                        int(usage.get("input_tokens") or 0)
                        + int(usage.get("cache_creation_input_tokens") or 0)
                        + int(usage.get("cache_read_input_tokens") or 0)
                    )
                    output_tokens = int(usage.get("output_tokens") or 0)
                    if input_tokens <= 0 and output_tokens <= 0:
                        continue
                    key = (message.get("id"), entry.get("requestId")) if message.get("id") else (entry.get("uuid"), None)
                    latest_by_key[key] = event("anthropic", timestamp, model, input_tokens, output_tokens)
        except OSError:
            continue
    yield from latest_by_key.values()


def codex_events(sessions_root, since):
    for path in recent_jsonl_files(sessions_root, since):
        current_model = None
        previous_totals = None
        try:
            with open(path, encoding="utf-8") as handle:
                for line in handle:
                    try:
                        entry = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    payload = entry.get("payload") or {}
                    if isinstance(payload.get("model"), str) and payload["model"].strip():
                        current_model = payload["model"].strip()
                    if payload.get("type") != "token_count":
                        continue
                    info = payload.get("info") or {}
                    totals = info.get("total_token_usage")
                    last = info.get("last_token_usage")
                    if not totals:
                        continue
                    if previous_totals and all(
                        int(totals.get(key) or 0) >= int(previous_totals.get(key) or 0)
                        for key in ("input_tokens", "output_tokens")
                    ):
                        input_tokens = int(totals.get("input_tokens") or 0) - int(previous_totals.get("input_tokens") or 0)
                        output_tokens = int(totals.get("output_tokens") or 0) - int(previous_totals.get("output_tokens") or 0)
                    else:
                        input_tokens = int((last or totals).get("input_tokens") or 0)
                        output_tokens = int((last or totals).get("output_tokens") or 0)
                    previous_totals = totals
                    if input_tokens <= 0 and output_tokens <= 0:
                        continue
                    timestamp = parse_iso_timestamp(entry.get("timestamp"))
                    if timestamp is None or timestamp < since:
                        continue
                    yield event("openAI", timestamp, current_model or "unknown", input_tokens, output_tokens)
        except OSError:
            continue


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--opencode-db", type=Path, default=DEFAULT_OPENCODE_DB, help="Path to opencode.db")
    parser.add_argument("--claude-projects", type=Path, default=DEFAULT_CLAUDE_PROJECTS, help="Path to Claude Code projects directory")
    parser.add_argument("--codex-sessions", type=Path, default=DEFAULT_CODEX_SESSIONS, help="Path to Codex sessions directory")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="Path to LimitBar usage-events.jsonl")
    parser.add_argument("--days", type=int, default=DEFAULT_DAYS, help="How many days back to export")
    args = parser.parse_args()

    since = datetime.now(tz=timezone.utc) - timedelta(days=args.days)
    args.output.parent.mkdir(parents=True, exist_ok=True)

    counts = {"azureOpenAI": 0, "anthropic": 0, "openAI": 0}
    descriptor, temp_path = tempfile.mkstemp(dir=args.output.parent, prefix=".usage-events-", suffix=".jsonl")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            sources = (
                opencode_events(args.opencode_db, since),
                claude_code_events(args.claude_projects, since),
                codex_events(args.codex_sessions, since),
            )
            for source in sources:
                for item in source:
                    handle.write(json.dumps(item, separators=(",", ":")) + "\n")
                    counts[item["provider"]] += 1
        os.replace(temp_path, args.output)
    except BaseException:
        os.unlink(temp_path)
        raise

    summary = ", ".join(f"{provider}: {count}" for provider, count in counts.items())
    print(f"Exported usage events since {since:%Y-%m-%d} to {args.output} ({summary})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

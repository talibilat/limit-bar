CREATE TABLE codex_explanation_findings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    recorded_at REAL NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('available', 'partial', 'observed_zero', 'unavailable')),
    reason TEXT,
    adapter_version TEXT NOT NULL,
    interval_start REAL,
    interval_end REAL,
    quota_reset_boundary REAL,
    coverage_start REAL,
    coverage_end REAL,
    quota_movement_percent REAL,
    input_tokens INTEGER NOT NULL CHECK (input_tokens >= 0),
    cached_input_tokens INTEGER NOT NULL CHECK (cached_input_tokens >= 0),
    output_tokens INTEGER NOT NULL CHECK (output_tokens >= 0),
    reasoning_output_tokens INTEGER NOT NULL CHECK (reasoning_output_tokens >= 0),
    session_count INTEGER NOT NULL CHECK (session_count >= 0),
    evidence_count INTEGER NOT NULL CHECK (evidence_count >= 0),
    observation_count INTEGER NOT NULL CHECK (observation_count >= 0),
    barrier_categories TEXT NOT NULL,
    CHECK (cached_input_tokens <= input_tokens),
    CHECK (reason IS NULL OR status = 'unavailable'),
    CHECK (quota_reset_boundary IS NULL OR status IN ('available', 'partial', 'observed_zero'))
);
CREATE INDEX codex_explanation_findings_recorded ON codex_explanation_findings (recorded_at);
INSERT INTO codex_explanation_findings (
    id, recorded_at, status, reason, adapter_version, interval_start, interval_end,
    quota_reset_boundary, coverage_start, coverage_end, quota_movement_percent, input_tokens, cached_input_tokens,
    output_tokens, reasoning_output_tokens, session_count, evidence_count, observation_count,
    barrier_categories
) VALUES (
    1, 1800000000, 'partial', NULL, 'codex-rollout-observed-0.144.4', 1799999900, 1799999960,
    1800003600, 1799999890, 1799999970, 2.5, 8, 3,
    4, 1, 2, 3, 2,
    'malformed_record'
);
PRAGMA user_version = 1;

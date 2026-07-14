PRAGMA user_version = 1;

CREATE TABLE quota_observations (
    product TEXT NOT NULL CHECK (product IN ('claudeCode', 'codex')),
    window_identifier TEXT NOT NULL CHECK (length(window_identifier) BETWEEN 1 AND 128),
    reset_boundary REAL NOT NULL,
    observed_at REAL NOT NULL,
    percentage_used REAL NOT NULL CHECK (percentage_used BETWEEN 0 AND 100),
    observation_source TEXT NOT NULL CHECK (observation_source IN ('claude_provider_report', 'codex_local_report')),
    PRIMARY KEY (product, window_identifier, reset_boundary, observed_at, percentage_used, observation_source)
);

CREATE INDEX quota_observations_retention ON quota_observations(observed_at);

INSERT INTO quota_observations VALUES
('claudeCode', 'seven-day', 1784505600.0, 1784064600.0, 12.0, 'claude_provider_report'),
('codex', 'secondary', 1784073600.0, 1784066400.0, 68.5, 'codex_local_report'),
('codex', 'secondary', 1784073600.0, 1784068200.0, 71.0, 'codex_local_report');

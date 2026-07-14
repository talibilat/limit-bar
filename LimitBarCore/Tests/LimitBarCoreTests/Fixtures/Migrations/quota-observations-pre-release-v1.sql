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
('claudeCode', 'five-hour', 1784077200.0, 1784059200.0, 24.5, 'claude_provider_report'),
('claudeCode', 'five-hour', 1784077200.0, 1784061000.0, 31.25, 'claude_provider_report'),
('codex', 'primary', 1784160000.0, 1784062800.0, 47.75, 'codex_local_report');

PRAGMA user_version = 0;

CREATE TABLE usage_metrics (
    id TEXT PRIMARY KEY,
    provider TEXT NOT NULL,
    account_label TEXT,
    project_label TEXT,
    model_label TEXT NOT NULL,
    deployment_label TEXT,
    time_window TEXT NOT NULL,
    input_tokens INTEGER NOT NULL,
    output_tokens INTEGER NOT NULL,
    cost_amount TEXT,
    cost_currency_code TEXT,
    cost_source TEXT,
    limit_status TEXT NOT NULL,
    limit_used REAL,
    limit_value REAL,
    refreshed_at REAL,
    freshness_status TEXT NOT NULL,
    missed_refreshes INTEGER NOT NULL
);

INSERT INTO usage_metrics VALUES
('legacy-anthropic', 'anthropic', 'Synthetic account', 'Project α', 'claude-synthetic', NULL, 'today', 10, 5, NULL, NULL, NULL, 'unsupportedByProviderAPI', NULL, NULL, 1783728000, 'fresh', 0),
('legacy-azure', 'azureOpenAI', NULL, 'Synthetic | separators', 'gpt-synthetic', 'deployment-a', 'currentWeek', 20, 7, '1.25', 'USD', 'calculatedEstimate', 'confirmed', 30.5, 100.0, 1783728100, 'stale', 2),
('legacy-openai', 'openAI', 'Team', NULL, 'codex-synthetic', NULL, 'today', 0, 0, '2.50', 'EUR', 'providerReported', 'disconnected', NULL, NULL, NULL, 'fresh', 0),
('legacy-custom', 'custom', 'Synthetic custom', 'Unicode β', 'local-synthetic', NULL, 'currentWeek', 922337, 1, NULL, NULL, NULL, 'unavailable', NULL, NULL, 1783728200, 'stale', 4);

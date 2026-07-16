PRAGMA user_version = 1;
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
INSERT INTO usage_metrics VALUES (
    'synthetic-v1-row', 'anthropic', 'Synthetic account', NULL, 'synthetic-model', NULL,
    'today', 120, 30, NULL, NULL, NULL, 'unsupportedByProviderAPI', NULL, NULL,
    1783890000, 'fresh', 0
);

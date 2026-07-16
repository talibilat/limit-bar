PRAGMA user_version = 2;
CREATE TABLE usage_metrics (
    id TEXT PRIMARY KEY,
    provider TEXT NOT NULL,
    account_label TEXT,
    project_label TEXT,
    model_label TEXT NOT NULL,
    deployment_label TEXT,
    time_window TEXT NOT NULL,
    source_kind TEXT NOT NULL CHECK (source_kind IN ('legacy', 'providerAPI', 'builtInLocalLog', 'custom')),
    source_identifier TEXT,
    window_start INTEGER,
    window_end INTEGER,
    window_basis TEXT CHECK (window_basis IS NULL OR window_basis IN ('localCalendar', 'utcBilling')),
    aggregation_version INTEGER CHECK (aggregation_version IS NULL OR (typeof(aggregation_version) = 'integer' AND aggregation_version > 0)),
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
CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE INDEX usage_metrics_current_windows ON usage_metrics (time_window, window_start, window_end, window_basis);
CREATE INDEX usage_metrics_replacement_scope ON usage_metrics (provider, time_window, source_kind, source_identifier);
INSERT INTO usage_metrics VALUES (
    'synthetic-v2-row', 'openAI', 'Synthetic local log', NULL, 'synthetic-model', NULL,
    'today', 'builtInLocalLog', NULL, 1783814400, 1783900800, 'localCalendar', 1,
    120, 30, NULL, NULL, NULL, 'unsupportedByProviderAPI', NULL, NULL,
    1783890000, 'fresh', 0
);

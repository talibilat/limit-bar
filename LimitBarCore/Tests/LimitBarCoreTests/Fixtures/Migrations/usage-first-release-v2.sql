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
    missed_refreshes INTEGER NOT NULL,
    CHECK (
        (source_kind = 'legacy' AND source_identifier IS NULL AND window_start IS NULL AND window_end IS NULL AND window_basis IS NULL AND aggregation_version IS NULL)
        OR
        (source_kind IN ('providerAPI', 'builtInLocalLog', 'custom') AND window_start IS NOT NULL AND window_end IS NOT NULL AND typeof(window_start) = 'integer' AND typeof(window_end) = 'integer' AND window_end > window_start AND window_basis IS NOT NULL AND aggregation_version IS NOT NULL AND typeof(aggregation_version) = 'integer')
    ),
    CHECK (
        (source_kind = 'custom' AND source_identifier IS NOT NULL)
        OR
        (source_kind != 'custom' AND source_identifier IS NULL)
    )
);

CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE INDEX usage_metrics_current_windows ON usage_metrics (time_window, window_start, window_end, window_basis);
CREATE INDEX usage_metrics_replacement_scope ON usage_metrics (provider, time_window, source_kind, source_identifier);
INSERT INTO app_metadata VALUES ('metrics_initialized', 'true');

INSERT INTO usage_metrics VALUES
('bounded-api', 'anthropic', 'Synthetic account', NULL, 'claude-synthetic', NULL, 'today', 'providerAPI', NULL, 1783728000, 1783814400, 'localCalendar', 1, 11, 6, NULL, NULL, NULL, 'confirmed', 40.0, 100.0, 1783728300, 'fresh', 0),
('bounded-local', 'openAI', NULL, 'Synthetic project', 'codex-synthetic', NULL, 'currentWeek', 'builtInLocalLog', NULL, 1783296000, 1783900800, 'localCalendar', 1, 21, 8, '3.75', 'USD', 'calculatedEstimate', 'unsupportedByProviderAPI', NULL, NULL, 1783728400, 'stale', 2),
('bounded-custom', 'custom', 'Synthetic custom', 'Unicode γ', 'local-synthetic', NULL, 'today', 'custom', '4A613A87-9D4D-4208-80D5-7F6D94A6DBE7', 1783728000, 1783814400, 'localCalendar', 1, 31, 9, NULL, NULL, NULL, 'unavailable', NULL, NULL, NULL, 'fresh', 0),
('bounded-billing', 'azureOpenAI', 'Billing', 'Synthetic | separators', 'gpt-synthetic', 'deployment-b', 'currentWeek', 'providerAPI', NULL, 1783296000, 1783900800, 'utcBilling', 2, 41, 10, '4.50', 'EUR', 'providerReported', 'disconnected', NULL, NULL, 1783728500, 'stale', 3);

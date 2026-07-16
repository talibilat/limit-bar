PRAGMA user_version = 1;

CREATE TABLE provider_refresh_history (
    id INTEGER PRIMARY KEY,
    schema_version INTEGER NOT NULL CHECK (schema_version = 1),
    product TEXT NOT NULL CHECK (product IN ('anthropic_api', 'openai_api')),
    operation TEXT NOT NULL CHECK (operation = 'usage_and_cost'),
    outcome TEXT NOT NULL CHECK (outcome IN ('success', 'partial_failure', 'cancelled', 'authentication_failure', 'network_failure', 'failed')),
    started_at REAL NOT NULL,
    duration_bucket TEXT NOT NULL CHECK (duration_bucket IN ('under_1_second', '1_to_5_seconds', '5_to_30_seconds', 'over_30_seconds'))
);

CREATE TABLE provider_refresh_windows (
    entry_id INTEGER NOT NULL REFERENCES provider_refresh_history(id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0 AND ordinal < 3),
    window_kind TEXT NOT NULL CHECK (window_kind IN ('today', 'currentWeek')),
    window_start REAL NOT NULL,
    window_end REAL NOT NULL CHECK (window_end > window_start),
    calendar_basis TEXT NOT NULL CHECK (calendar_basis IN ('localCalendar', 'utcBilling')),
    aggregation_version INTEGER NOT NULL CHECK (aggregation_version > 0),
    PRIMARY KEY (entry_id, ordinal)
);

CREATE INDEX provider_refresh_history_product_started ON provider_refresh_history(product, started_at DESC);

INSERT INTO provider_refresh_history VALUES
(7, 1, 'anthropic_api', 'usage_and_cost', 'authentication_failure', 1784066400.0, 'under_1_second'),
(9, 1, 'openai_api', 'usage_and_cost', 'success', 1784070000.0, 'over_30_seconds');

INSERT INTO provider_refresh_windows VALUES
(9, 0, 'today', 1783987200.0, 1784073600.0, 'localCalendar', 3),
(9, 1, 'currentWeek', 1783900800.0, 1784505600.0, 'localCalendar', 3),
(9, 2, 'currentWeek', 1783900800.0, 1784505600.0, 'utcBilling', 3);

-- ============================================================
-- ERGO MM Performance Optimization Script
-- Run this to fix slow dashboard queries
-- ============================================================

USE ergo_mm;

-- ============================================================
-- ADD MISSING INDEXES
-- ============================================================

-- Index for user_balances view query
ALTER TABLE user_balances ADD INDEX IF NOT EXISTS idx_exchange_timestamp (exchange, timestamp);

-- Index for user_orderbook_depth view query
ALTER TABLE user_orderbook_depth ADD INDEX IF NOT EXISTS idx_exchange_depth_timestamp (exchange, depth_level, timestamp);

-- Index for market_metrics view query
ALTER TABLE market_metrics ADD INDEX IF NOT EXISTS idx_exchange_calculated (exchange, calculated_at);

-- Better index for alerts
ALTER TABLE alerts_log ADD INDEX IF NOT EXISTS idx_created_at (created_at);

-- Better index for user_open_orders
ALTER TABLE user_open_orders ADD INDEX IF NOT EXISTS idx_recorded (recorded_at);

-- ============================================================
-- CREATE OPTIMIZED VIEWS
-- These use subqueries with LIMIT instead of full table scans
-- ============================================================

-- Drop old views first
DROP VIEW IF EXISTS v_latest_prices;
DROP VIEW IF EXISTS v_latest_depth;
DROP VIEW IF EXISTS v_latest_metrics;
DROP VIEW IF EXISTS v_latest_user_balances;
DROP VIEW IF EXISTS v_latest_user_depth;

-- Optimized: Latest price data per exchange (uses index better)
CREATE VIEW v_latest_prices AS
SELECT p.*
FROM price_data p
WHERE p.timestamp = (
    SELECT MAX(p2.timestamp)
    FROM price_data p2
    WHERE p2.exchange = p.exchange
);

-- Optimized: Latest orderbook depth per exchange and level
CREATE VIEW v_latest_depth AS
SELECT o.*
FROM orderbook_depth o
WHERE o.timestamp = (
    SELECT MAX(o2.timestamp)
    FROM orderbook_depth o2
    WHERE o2.exchange = o.exchange AND o2.depth_level = o.depth_level
);

-- Optimized: Latest metrics per exchange
CREATE VIEW v_latest_metrics AS
SELECT m.*
FROM market_metrics m
WHERE m.calculated_at = (
    SELECT MAX(m2.calculated_at)
    FROM market_metrics m2
    WHERE m2.exchange = m.exchange
);

-- Optimized: Latest user balances per exchange
CREATE VIEW v_latest_user_balances AS
SELECT b.*
FROM user_balances b
WHERE b.timestamp = (
    SELECT MAX(b2.timestamp)
    FROM user_balances b2
    WHERE b2.exchange = b.exchange
);

-- Optimized: Latest user orderbook depth per exchange and level
CREATE VIEW v_latest_user_depth AS
SELECT u.*
FROM user_orderbook_depth u
WHERE u.timestamp = (
    SELECT MAX(u2.timestamp)
    FROM user_orderbook_depth u2
    WHERE u2.exchange = u.exchange AND u2.depth_level = u.depth_level
);

-- ============================================================
-- CHECK TABLE SIZES (for diagnostics)
-- ============================================================
SELECT
    table_name,
    table_rows as estimated_rows,
    ROUND(data_length / 1024 / 1024, 2) as data_mb,
    ROUND(index_length / 1024 / 1024, 2) as index_mb
FROM information_schema.tables
WHERE table_schema = 'ergo_mm'
ORDER BY table_rows DESC;

-- ============================================================
-- ANALYZE TABLES (helps optimizer)
-- ============================================================
ANALYZE TABLE price_data;
ANALYZE TABLE orderbook_depth;
ANALYZE TABLE trades;
ANALYZE TABLE user_balances;
ANALYZE TABLE user_orderbook_depth;
ANALYZE TABLE market_metrics;
ANALYZE TABLE alerts_log;

SELECT 'Optimization complete!' as status;

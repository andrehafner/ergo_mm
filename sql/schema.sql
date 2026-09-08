-- ============================================================
-- ERGO Market Maker Monitoring System - MySQL Schema
-- Database: ergo_mm
-- ============================================================

-- Create the database
CREATE DATABASE IF NOT EXISTS ergo_mm CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE ergo_mm;

-- ============================================================
-- CONFIGURATION TABLE
-- Stores system settings including Discord webhook, thresholds
-- ============================================================
CREATE TABLE IF NOT EXISTS config (
    config_key VARCHAR(100) PRIMARY KEY,
    config_value TEXT,
    description VARCHAR(255),
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- Insert default configuration values
INSERT INTO config (config_key, config_value, description) VALUES
('discord_webhook', 'https://discord.com/api/webhooks/1464750010267598931/44YOlHSIo2nTTtmSRhRKp6SYdNSebd6jldnXQ8OTXraBCGGLqpOnN82i7ahJhJRaknJI', 'Discord webhook URL for alerts'),
('spread_warning_threshold', '1.5', 'Spread percentage to trigger warning'),
('spread_critical_threshold', '3.0', 'Spread percentage to trigger critical alert'),
('depth_warning_threshold', '5000', 'Minimum depth in USD before warning'),
('depth_critical_threshold', '2000', 'Minimum depth in USD before critical alert'),
('price_change_warning', '5.0', 'Price change % in 1hr to trigger warning'),
('price_change_critical', '10.0', 'Price change % in 1hr to trigger critical alert'),
('volume_spike_threshold', '3.0', 'Volume multiplier vs 24h avg to flag spike'),
('liquidity_pull_threshold', '15.0', 'Price volatility % to recommend pulling liquidity'),
('alert_cooldown_minutes', '30', 'Minutes between repeat alerts of same type'),
('monitoring_enabled', '1', 'Enable/disable monitoring (1/0)'),
('kucoin_enabled', '1', 'Monitor KuCoin (1/0)'),
('mexc_enabled', '1', 'Monitor MEXC (1/0)'),
('flow_tracking_enabled', '1', 'Track on-chain ERG flows in/out of exchange wallets (1/0)'),
('kucoin_erg_addresses', '9gNYeyfRFUipiWZ3JR1ayDMoeh28E6J7aDQosb7yrzsuGSDqzCC', 'Comma-separated Ergo addresses of KuCoin wallets (more are suggested in Settings from your own withdrawals)'),
('mexc_erg_addresses', '', 'Comma-separated Ergo addresses of MEXC wallets (sender address of one of your MEXC withdrawals)'),
('ergo_explorer_url', 'https://api.ergoplatform.com', 'Ergo explorer API base URL used for on-chain flow tracking'),
('ergo_explorer_timeout', '20', 'Seconds to wait for each explorer request'),
('flow_alert_threshold_erg', '5000', 'Single on-chain transfer (ERG) that triggers a LARGE_INFLOW/LARGE_OUTFLOW alert; 2x this as net 1h inflow triggers NET_INFLOW_HIGH')
ON DUPLICATE KEY UPDATE config_key=config_key;

-- ============================================================
-- PRICE DATA TABLE
-- Stores current and historical price/market data
-- ============================================================
CREATE TABLE IF NOT EXISTS price_data (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    exchange VARCHAR(20) NOT NULL,
    symbol VARCHAR(20) NOT NULL DEFAULT 'ERG/USDT',
    price DECIMAL(20, 8) NOT NULL,
    bid_price DECIMAL(20, 8),
    ask_price DECIMAL(20, 8),
    spread DECIMAL(10, 4),
    spread_percent DECIMAL(10, 4),
    volume_24h DECIMAL(20, 8),
    volume_24h_usd DECIMAL(20, 2),
    high_24h DECIMAL(20, 8),
    low_24h DECIMAL(20, 8),
    price_change_24h DECIMAL(10, 4),
    price_change_percent_24h DECIMAL(10, 4),
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_exchange_time (exchange, timestamp),
    INDEX idx_timestamp (timestamp)
);

-- ============================================================
-- ORDERBOOK DEPTH TABLE
-- Stores orderbook depth snapshots at various levels
-- ============================================================
CREATE TABLE IF NOT EXISTS orderbook_depth (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    exchange VARCHAR(20) NOT NULL,
    symbol VARCHAR(20) NOT NULL DEFAULT 'ERG/USDT',
    depth_level VARCHAR(10) NOT NULL,  -- '2%', '5%', '10%'
    bid_depth_erg DECIMAL(20, 8),
    bid_depth_usd DECIMAL(20, 2),
    ask_depth_erg DECIMAL(20, 8),
    ask_depth_usd DECIMAL(20, 2),
    lqs_share_percent DECIMAL(10, 2),
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_exchange_level_time (exchange, depth_level, timestamp),
    INDEX idx_timestamp (timestamp)
);

-- ============================================================
-- TRADES TABLE
-- Stores recent trades for analysis
-- ============================================================
CREATE TABLE IF NOT EXISTS trades (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    exchange VARCHAR(20) NOT NULL,
    symbol VARCHAR(20) NOT NULL DEFAULT 'ERG/USDT',
    trade_id VARCHAR(100),
    price DECIMAL(20, 8) NOT NULL,
    amount DECIMAL(20, 8) NOT NULL,
    amount_usd DECIMAL(20, 2),
    side VARCHAR(10),  -- 'buy' or 'sell'
    trade_time TIMESTAMP,
    recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE INDEX idx_exchange_trade (exchange, trade_id),
    INDEX idx_exchange_time (exchange, trade_time),
    INDEX idx_recorded (recorded_at)
);

-- ============================================================
-- BALANCE SNAPSHOTS TABLE
-- For tracking liquidity provider balances over time
-- ============================================================
CREATE TABLE IF NOT EXISTS balance_snapshots (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    exchange VARCHAR(20) NOT NULL,
    token VARCHAR(20) NOT NULL,
    amount DECIMAL(20, 8) NOT NULL,
    usd_value DECIMAL(20, 2),
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_exchange_token_time (exchange, token, timestamp),
    INDEX idx_timestamp (timestamp)
);

-- ============================================================
-- ALERTS LOG TABLE
-- Logs all alerts sent for audit and cooldown tracking
-- ============================================================
CREATE TABLE IF NOT EXISTS alerts_log (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    alert_type VARCHAR(50) NOT NULL,
    severity VARCHAR(20) NOT NULL,  -- 'info', 'warning', 'critical'
    exchange VARCHAR(20),
    message TEXT NOT NULL,
    details JSON,
    discord_sent TINYINT(1) DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_type_time (alert_type, created_at),
    INDEX idx_severity (severity),
    INDEX idx_created (created_at)
);

-- ============================================================
-- MARKET METRICS TABLE
-- Aggregated metrics for dashboard display
-- ============================================================
CREATE TABLE IF NOT EXISTS market_metrics (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    exchange VARCHAR(20) NOT NULL,
    symbol VARCHAR(20) NOT NULL DEFAULT 'ERG/USDT',
    avg_spread_1h DECIMAL(10, 4),
    avg_spread_24h DECIMAL(10, 4),
    total_volume_1h DECIMAL(20, 2),
    total_volume_24h DECIMAL(20, 2),
    trade_count_1h INT,
    trade_count_24h INT,
    price_range_24h DECIMAL(10, 4),
    volatility_1h DECIMAL(10, 4),
    strategy_uptime DECIMAL(5, 2) DEFAULT 100.00,
    calculated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_exchange_time (exchange, calculated_at)
);

-- ============================================================
-- RECOMMENDATIONS TABLE
-- Stores trading recommendations for display
-- ============================================================
CREATE TABLE IF NOT EXISTS recommendations (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    exchange VARCHAR(20),
    recommendation_type VARCHAR(50) NOT NULL,
    action VARCHAR(50) NOT NULL,  -- 'PULL_LIQUIDITY', 'ADD_LIQUIDITY', 'REBALANCE', 'HOLD'
    reason TEXT NOT NULL,
    priority INT DEFAULT 5,  -- 1-10, 10 being most urgent
    is_active TINYINT(1) DEFAULT 1,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP,
    INDEX idx_active_priority (is_active, priority DESC),
    INDEX idx_exchange (exchange)
);

-- ============================================================
-- SESSION TRACKING TABLE
-- For dashboard login sessions
-- ============================================================
CREATE TABLE IF NOT EXISTS sessions (
    session_id VARCHAR(64) PRIMARY KEY,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_activity TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    ip_address VARCHAR(45),
    INDEX idx_last_activity (last_activity)
);

-- ============================================================
-- USER BALANCES TABLE
-- Tracks user's exchange balances over time
-- ============================================================
CREATE TABLE IF NOT EXISTS user_balances (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    exchange VARCHAR(20) NOT NULL,
    erg_free DECIMAL(20, 8) DEFAULT 0,
    erg_locked DECIMAL(20, 8) DEFAULT 0,
    erg_total DECIMAL(20, 8) DEFAULT 0,
    usdt_free DECIMAL(20, 8) DEFAULT 0,
    usdt_locked DECIMAL(20, 8) DEFAULT 0,
    usdt_total DECIMAL(20, 8) DEFAULT 0,
    total_value_usd DECIMAL(20, 2) DEFAULT 0,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_exchange_time (exchange, timestamp),
    INDEX idx_timestamp (timestamp)
);

-- ============================================================
-- USER OPEN ORDERS TABLE
-- Tracks user's current open orders
-- ============================================================
CREATE TABLE IF NOT EXISTS user_open_orders (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    exchange VARCHAR(20) NOT NULL,
    order_id VARCHAR(100) NOT NULL,
    side VARCHAR(10) NOT NULL,  -- 'buy' or 'sell'
    price DECIMAL(20, 8) NOT NULL,
    amount DECIMAL(20, 8) NOT NULL,
    amount_filled DECIMAL(20, 8) DEFAULT 0,
    order_type VARCHAR(20),
    created_at TIMESTAMP,
    recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_exchange (exchange),
    INDEX idx_side (side),
    UNIQUE INDEX idx_exchange_order (exchange, order_id)
);

-- ============================================================
-- USER ORDERBOOK DEPTH TABLE
-- Tracks user's liquidity share at various depth levels
-- ============================================================
CREATE TABLE IF NOT EXISTS user_orderbook_depth (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    exchange VARCHAR(20) NOT NULL,
    depth_level VARCHAR(10) NOT NULL,  -- '2%', '5%', '10%'
    bid_depth_erg DECIMAL(20, 8) DEFAULT 0,
    bid_depth_usd DECIMAL(20, 2) DEFAULT 0,
    ask_depth_erg DECIMAL(20, 8) DEFAULT 0,
    ask_depth_usd DECIMAL(20, 2) DEFAULT 0,
    market_bid_usd DECIMAL(20, 2) DEFAULT 0,
    market_ask_usd DECIMAL(20, 2) DEFAULT 0,
    bid_share_pct DECIMAL(10, 2) DEFAULT 0,
    ask_share_pct DECIMAL(10, 2) DEFAULT 0,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_exchange_level_time (exchange, depth_level, timestamp),
    INDEX idx_timestamp (timestamp)
);

-- ============================================================
-- EXCHANGE FLOWS TABLE
-- One row per on-chain transaction that moved ERG into ('in')
-- or out of ('out') an exchange's tracked wallet addresses.
-- ============================================================
CREATE TABLE IF NOT EXISTS exchange_flows (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    exchange VARCHAR(20) NOT NULL,
    tx_id VARCHAR(64) NOT NULL,
    direction VARCHAR(10) NOT NULL,          -- 'in' = deposit to exchange, 'out' = withdrawal from exchange
    amount_erg DECIMAL(20, 9) NOT NULL,      -- net ERG moved for the exchange's whole address set
    amount_usd DECIMAL(20, 2),               -- valued at the exchange price when recorded
    price_usd DECIMAL(20, 8),
    counterparty VARCHAR(128),               -- largest non-exchange address on the other side
    block_height INT,
    tx_time TIMESTAMP NULL,
    recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE INDEX idx_exchange_tx (exchange, tx_id),
    INDEX idx_exchange_time (exchange, tx_time),
    INDEX idx_tx_time (tx_time)
);

-- ============================================================
-- EXCHANGE RESERVES TABLE
-- Confirmed ERG balance of each tracked exchange address,
-- snapshotted on every monitor run.
-- ============================================================
CREATE TABLE IF NOT EXISTS exchange_reserves (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    exchange VARCHAR(20) NOT NULL,
    address VARCHAR(128) NOT NULL,
    balance_erg DECIMAL(20, 9) NOT NULL,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_exchange_addr_time (exchange, address, timestamp),
    INDEX idx_exchange_time (exchange, timestamp),
    INDEX idx_timestamp (timestamp)
);

-- ============================================================
-- USER TRANSFERS TABLE
-- The market-maker account's own ERG and USDT deposits and
-- withdrawals as reported by the exchange account APIs
-- (requires api_keys.conf).
-- ============================================================
CREATE TABLE IF NOT EXISTS user_transfers (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    exchange VARCHAR(20) NOT NULL,
    currency VARCHAR(10) NOT NULL DEFAULT 'ERG',   -- 'ERG' or 'USDT'
    direction VARCHAR(12) NOT NULL,                -- 'deposit' or 'withdrawal'
    transfer_id VARCHAR(128) NOT NULL,
    amount DECIMAL(20, 9) NOT NULL,
    fee DECIMAL(20, 9) DEFAULT 0,
    status VARCHAR(30),
    network VARCHAR(30),                           -- chain used (mainly for USDT: TRC20, ERC20, ...)
    address VARCHAR(128),
    tx_id VARCHAR(128),
    tx_time TIMESTAMP NULL,
    recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE INDEX idx_exchange_cur_dir_transfer (exchange, currency, direction, transfer_id),
    INDEX idx_exchange_cur_time (exchange, currency, tx_time),
    INDEX idx_tx_time (tx_time)
);

-- ============================================================
-- EXCHANGE WALLET HINTS TABLE
-- Hot-wallet discovery: the address that sent one of your own
-- ERG withdrawals is the exchange's hot wallet. The monitor looks
-- up each withdrawal tx on the explorer once and records the
-- sending address(es) here; Settings offers them for tracking.
-- ============================================================
CREATE TABLE IF NOT EXISTS exchange_wallet_hints (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    exchange VARCHAR(20) NOT NULL,
    tx_id VARCHAR(128) NOT NULL,             -- one of your withdrawals, as reported by the exchange
    address VARCHAR(128) NULL,               -- input address of that tx; NULL = looked up, nothing usable
    checked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE INDEX idx_exchange_tx_addr (exchange, tx_id, address),
    INDEX idx_exchange_addr (exchange, address)
);

-- ============================================================
-- VIEWS FOR DASHBOARD
-- ============================================================

-- Latest price data per exchange
CREATE OR REPLACE VIEW v_latest_prices AS
SELECT p1.*
FROM price_data p1
INNER JOIN (
    SELECT exchange, MAX(timestamp) as max_time
    FROM price_data
    GROUP BY exchange
) p2 ON p1.exchange = p2.exchange AND p1.timestamp = p2.max_time;

-- Latest orderbook depth per exchange and level
CREATE OR REPLACE VIEW v_latest_depth AS
SELECT o1.*
FROM orderbook_depth o1
INNER JOIN (
    SELECT exchange, depth_level, MAX(timestamp) as max_time
    FROM orderbook_depth
    GROUP BY exchange, depth_level
) o2 ON o1.exchange = o2.exchange
    AND o1.depth_level = o2.depth_level
    AND o1.timestamp = o2.max_time;

-- Latest metrics per exchange
CREATE OR REPLACE VIEW v_latest_metrics AS
SELECT m1.*
FROM market_metrics m1
INNER JOIN (
    SELECT exchange, MAX(calculated_at) as max_time
    FROM market_metrics
    GROUP BY exchange
) m2 ON m1.exchange = m2.exchange AND m1.calculated_at = m2.max_time;

-- Active recommendations ordered by priority
CREATE OR REPLACE VIEW v_active_recommendations AS
SELECT *
FROM recommendations
WHERE is_active = 1
  AND (expires_at IS NULL OR expires_at > NOW())
ORDER BY priority DESC, created_at DESC;

-- Recent alerts (last 24 hours)
CREATE OR REPLACE VIEW v_recent_alerts AS
SELECT *
FROM alerts_log
WHERE created_at > DATE_SUB(NOW(), INTERVAL 24 HOUR)
ORDER BY created_at DESC;

-- Latest user balances per exchange
CREATE OR REPLACE VIEW v_latest_user_balances AS
SELECT b1.*
FROM user_balances b1
INNER JOIN (
    SELECT exchange, MAX(timestamp) as max_time
    FROM user_balances
    GROUP BY exchange
) b2 ON b1.exchange = b2.exchange AND b1.timestamp = b2.max_time;

-- Latest user orderbook depth per exchange and level
CREATE OR REPLACE VIEW v_latest_user_depth AS
SELECT u1.*
FROM user_orderbook_depth u1
INNER JOIN (
    SELECT exchange, depth_level, MAX(timestamp) as max_time
    FROM user_orderbook_depth
    GROUP BY exchange, depth_level
) u2 ON u1.exchange = u2.exchange
    AND u1.depth_level = u2.depth_level
    AND u1.timestamp = u2.max_time;

-- On-chain flow totals per exchange over the last 24h (1h/6h/24h windows)
CREATE OR REPLACE VIEW v_exchange_flow_summary AS
SELECT
    exchange,
    SUM(CASE WHEN direction = 'in'  AND tx_time > DATE_SUB(NOW(), INTERVAL 1 HOUR)  THEN amount_erg ELSE 0 END) AS in_1h,
    SUM(CASE WHEN direction = 'out' AND tx_time > DATE_SUB(NOW(), INTERVAL 1 HOUR)  THEN amount_erg ELSE 0 END) AS out_1h,
    SUM(CASE WHEN direction = 'in'  AND tx_time > DATE_SUB(NOW(), INTERVAL 6 HOUR)  THEN amount_erg ELSE 0 END) AS in_6h,
    SUM(CASE WHEN direction = 'out' AND tx_time > DATE_SUB(NOW(), INTERVAL 6 HOUR)  THEN amount_erg ELSE 0 END) AS out_6h,
    SUM(CASE WHEN direction = 'in'  THEN amount_erg ELSE 0 END) AS in_24h,
    SUM(CASE WHEN direction = 'out' THEN amount_erg ELSE 0 END) AS out_24h,
    COUNT(*) AS tx_24h,
    MAX(tx_time) AS last_tx
FROM exchange_flows
WHERE tx_time > DATE_SUB(NOW(), INTERVAL 24 HOUR)
GROUP BY exchange;

-- Latest confirmed balance of each tracked exchange address
CREATE OR REPLACE VIEW v_latest_exchange_reserves AS
SELECT r.exchange, r.address, r.balance_erg, r.timestamp
FROM exchange_reserves r
INNER JOIN (
    SELECT exchange, address, MAX(timestamp) AS max_time
    FROM exchange_reserves
    WHERE timestamp > DATE_SUB(NOW(), INTERVAL 1 DAY)
    GROUP BY exchange, address
) x ON r.exchange = x.exchange AND r.address = x.address AND r.timestamp = x.max_time;

-- ============================================================
-- CLEANUP PROCEDURE
-- Removes old data to prevent database bloat
-- ============================================================
DELIMITER //
CREATE PROCEDURE IF NOT EXISTS cleanup_old_data()
BEGIN
    -- Keep 30 days of price data
    DELETE FROM price_data WHERE timestamp < DATE_SUB(NOW(), INTERVAL 30 DAY);

    -- Keep 30 days of orderbook depth
    DELETE FROM orderbook_depth WHERE timestamp < DATE_SUB(NOW(), INTERVAL 30 DAY);

    -- Keep 12 hours of trades (table grows very fast)
    DELETE FROM trades WHERE recorded_at < DATE_SUB(NOW(), INTERVAL 12 HOUR);

    -- Keep 90 days of alerts
    DELETE FROM alerts_log WHERE created_at < DATE_SUB(NOW(), INTERVAL 90 DAY);

    -- Keep 90 days of metrics
    DELETE FROM market_metrics WHERE calculated_at < DATE_SUB(NOW(), INTERVAL 90 DAY);

    -- Keep 1 year of balance snapshots
    DELETE FROM balance_snapshots WHERE timestamp < DATE_SUB(NOW(), INTERVAL 1 YEAR);

    -- Keep 30 days of user balances
    DELETE FROM user_balances WHERE timestamp < DATE_SUB(NOW(), INTERVAL 30 DAY);

    -- Keep 30 days of user orderbook depth
    DELETE FROM user_orderbook_depth WHERE timestamp < DATE_SUB(NOW(), INTERVAL 30 DAY);

    -- Keep 90 days of on-chain exchange flows (small: one row per real transfer)
    DELETE FROM exchange_flows WHERE tx_time < DATE_SUB(NOW(), INTERVAL 90 DAY);

    -- Keep 14 days of reserve snapshots (one row per address per run)
    DELETE FROM exchange_reserves WHERE timestamp < DATE_SUB(NOW(), INTERVAL 14 DAY);

    -- Keep 1 year of the MM account's own deposit/withdrawal history
    DELETE FROM user_transfers WHERE recorded_at < DATE_SUB(NOW(), INTERVAL 1 YEAR);

    -- Expire old recommendations
    UPDATE recommendations SET is_active = 0
    WHERE expires_at IS NOT NULL AND expires_at < NOW();

    -- Clean old sessions (inactive for 24 hours)
    DELETE FROM sessions WHERE last_activity < DATE_SUB(NOW(), INTERVAL 24 HOUR);
END //
DELIMITER ;

-- ============================================================
-- EVENT SCHEDULER FOR AUTOMATIC CLEANUP
-- Run cleanup daily at 3 AM
-- ============================================================
-- Note: Requires event_scheduler to be enabled in MySQL
-- SET GLOBAL event_scheduler = ON;
CREATE EVENT IF NOT EXISTS daily_cleanup
ON SCHEDULE EVERY 1 DAY
STARTS CONCAT(CURDATE() + INTERVAL 1 DAY, ' 03:00:00')
DO CALL cleanup_old_data();

-- ============================================================
-- GRANT PERMISSIONS (adjust user as needed)
-- ============================================================
-- GRANT ALL PRIVILEGES ON ergo_mm.* TO 'root'@'localhost';
-- FLUSH PRIVILEGES;

SELECT 'ERGO MM Database schema created successfully!' AS status;

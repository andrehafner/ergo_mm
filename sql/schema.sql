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
('discord_webhook', '', 'Discord webhook URL for alerts'),
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
('mexc_enabled', '1', 'Monitor MEXC (1/0)')
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
    trade_id VARCHAR(50),
    price DECIMAL(20, 8) NOT NULL,
    amount DECIMAL(20, 8) NOT NULL,
    amount_usd DECIMAL(20, 2),
    side VARCHAR(10),  -- 'buy' or 'sell'
    trade_time TIMESTAMP,
    recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
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

    -- Keep 7 days of trades
    DELETE FROM trades WHERE recorded_at < DATE_SUB(NOW(), INTERVAL 7 DAY);

    -- Keep 90 days of alerts
    DELETE FROM alerts_log WHERE created_at < DATE_SUB(NOW(), INTERVAL 90 DAY);

    -- Keep 90 days of metrics
    DELETE FROM market_metrics WHERE calculated_at < DATE_SUB(NOW(), INTERVAL 90 DAY);

    -- Keep 1 year of balance snapshots
    DELETE FROM balance_snapshots WHERE timestamp < DATE_SUB(NOW(), INTERVAL 1 YEAR);

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

-- ============================================================
-- Migration: On-chain exchange flow tracking + account transfers
-- + trades de-duplication
--
-- Run against an existing database:
--   mysql -u root -p ergo_mm < sql/add_flow_tables.sql
--
-- Safe to re-run (all statements are idempotent).
-- ============================================================

USE ergo_mm;

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

-- Upgrade a user_transfers table created by the earlier ERG-only revision of
-- this migration (amount_erg/fee_erg, no currency/network). No-ops otherwise.
SET @has_amount_erg := (
    SELECT COUNT(*) FROM information_schema.columns
    WHERE table_schema = DATABASE() AND table_name = 'user_transfers' AND column_name = 'amount_erg'
);
SET @sql := IF(@has_amount_erg > 0,
    'ALTER TABLE user_transfers CHANGE COLUMN amount_erg amount DECIMAL(20, 9) NOT NULL, CHANGE COLUMN fee_erg fee DECIMAL(20, 9) DEFAULT 0',
    'SELECT ''user_transfers already uses amount/fee'' AS note');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @has_currency := (
    SELECT COUNT(*) FROM information_schema.columns
    WHERE table_schema = DATABASE() AND table_name = 'user_transfers' AND column_name = 'currency'
);
SET @sql := IF(@has_currency = 0,
    'ALTER TABLE user_transfers ADD COLUMN currency VARCHAR(10) NOT NULL DEFAULT ''ERG'' AFTER exchange, ADD COLUMN network VARCHAR(30) NULL AFTER status',
    'SELECT ''user_transfers already has currency/network'' AS note');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @has_old_idx := (
    SELECT COUNT(*) FROM information_schema.statistics
    WHERE table_schema = DATABASE() AND table_name = 'user_transfers' AND index_name = 'idx_exchange_dir_transfer'
);
SET @sql := IF(@has_old_idx > 0,
    'ALTER TABLE user_transfers DROP INDEX idx_exchange_dir_transfer, DROP INDEX idx_exchange_time, ADD UNIQUE INDEX idx_exchange_cur_dir_transfer (exchange, currency, direction, transfer_id), ADD INDEX idx_exchange_cur_time (exchange, currency, tx_time)',
    'SELECT ''user_transfers indexes already current'' AS note');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;


-- ============================================================
-- NEW CONFIG KEYS
-- The KuCoin list is seeded with the community-tracked KuCoin
-- wallets (same set ergo.watch reports). Verify them in
-- Settings; the Flows tab shows the live balance of each
-- address so a wrong one is easy to spot and remove.
-- MEXC's wallet is not publicly catalogued: look up one of your
-- own MEXC withdrawals on the explorer - the sending address is
-- MEXC's hot wallet - and paste it into Settings.
-- ============================================================
INSERT INTO config (config_key, config_value, description) VALUES
('flow_tracking_enabled', '1', 'Track on-chain ERG flows in/out of exchange wallets (1/0)'),
('kucoin_erg_addresses', '9gNYeyfRFUipiWZ3JR1ayDMoeh28E6J7aDQosb7yrzsuGSDqzCC,9guZaxPTe4z6dYPcnKC3eiVexdHjwHz2WfgDxkTABzyHz7q9eU5,9i8Mci4ufn3Ai5pGjmMEQpPLJyuaEAXiN7f8Nc2y4tYqpzznk69,9iNt6wfxSc3DSaBVp22E7g993dwKUCvbGdHoEjxF8SRqj35oXAv', 'Comma-separated Ergo addresses of KuCoin wallets (seeded from community tracklist - verify)'),
('mexc_erg_addresses', '', 'Comma-separated Ergo addresses of MEXC wallets (sender address of one of your MEXC withdrawals)'),
('ergo_explorer_url', 'https://api.ergoplatform.com', 'Ergo explorer API base URL used for on-chain flow tracking'),
('ergo_explorer_timeout', '20', 'Seconds to wait for each explorer request'),
('flow_alert_threshold_erg', '5000', 'Single on-chain transfer (ERG) that triggers a LARGE_INFLOW/LARGE_OUTFLOW alert; 2x this as net 1h inflow triggers NET_INFLOW_HIGH')
ON DUPLICATE KEY UPDATE config_key = config_key;

-- ============================================================
-- TRADES DE-DUPLICATION
-- store_trades() relied on ON DUPLICATE KEY, but trades had no
-- unique key, so every run re-inserted the same ~100 recent
-- trades and volume/trade-count stats were inflated. Remove the
-- duplicates, then add the unique key so it works as intended.
-- ============================================================
DELETE t1 FROM trades t1
INNER JOIN trades t2
    ON t1.exchange = t2.exchange
   AND t1.trade_id = t2.trade_id
   AND t1.id > t2.id;

SET @idx_exists := (
    SELECT COUNT(*) FROM information_schema.statistics
    WHERE table_schema = DATABASE() AND table_name = 'trades' AND index_name = 'idx_exchange_trade'
);
SET @sql := IF(@idx_exists = 0,
    'ALTER TABLE trades ADD UNIQUE INDEX idx_exchange_trade (exchange, trade_id)',
    'SELECT ''idx_exchange_trade already exists'' AS note');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- ============================================================
-- VIEWS
-- ============================================================
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
-- CLEANUP PROCEDURE (re-created to include the new tables)
-- ============================================================
DROP PROCEDURE IF EXISTS cleanup_old_data;
DELIMITER //
CREATE PROCEDURE cleanup_old_data()
BEGIN
    -- Keep 30 days of price data
    DELETE FROM price_data WHERE timestamp < DATE_SUB(NOW(), INTERVAL 30 DAY);

    -- Keep 30 days of orderbook depth
    DELETE FROM orderbook_depth WHERE timestamp < DATE_SUB(NOW(), INTERVAL 30 DAY);

    -- Keep 1 day of trades (de-duplicated now, so this is ~real trade count)
    DELETE FROM trades WHERE recorded_at < DATE_SUB(NOW(), INTERVAL 1 DAY);

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

SELECT 'Exchange flow tables, config keys and trades unique index installed.' AS status;

-- ============================================================
-- Migration: Add User Balance and Order Tracking Tables
-- Run this script to add API key tracking support to existing DB
-- ============================================================

USE ergo_mm;

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
-- VIEWS FOR USER DATA
-- ============================================================

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

SELECT 'User tracking tables and views created successfully!' AS status;

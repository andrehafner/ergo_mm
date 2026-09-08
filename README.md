# ERGO Market Maker Monitoring System

A comprehensive monitoring system for protecting ERGO community liquidity on KuCoin and MEXC exchanges. This system provides real-time monitoring, alerting, and recommendations for market making operations.

## Features

- **Real-time Market Monitoring**
  - Price tracking for ERG/USDT on KuCoin and MEXC
  - Orderbook depth analysis at 2%, 5%, and 10% levels
  - Spread monitoring and alerts
  - Volume tracking and spike detection

- **ERG Exchange Flow Tracking (on-chain)**
  - Polls the Ergo explorer every minute for the exchanges' known ERG wallets
  - Table of ERG **in** (deposits) and **out** (withdrawals) per exchange over 1h / 6h / 24h, with net
  - Live reserve (ERG held in the tracked wallets) and 48h charts
  - Every individual transfer with amount, USD value, counterparty and explorer link
  - Your MM account's own ERG **and USDT** deposits/withdrawals from the MEXC / KuCoin account APIs, with a per-exchange in/out/net table over 24h, 7d and 30d
  - Alerts: `LARGE_INFLOW`, `LARGE_OUTFLOW`, `NET_INFLOW_HIGH` (+ `REDUCE_BIDS` recommendation)

- **Liquidity Protection Alerts**
  - Spread threshold warnings (configurable)
  - Depth depletion alerts
  - Extreme volatility detection
  - Volume spike detection (1h vs 24h hourly average)
  - Automated pull liquidity recommendations

- **Discord Webhook Integration**
  - Real-time alerts to your Discord server
  - Severity-based color coding
  - Detailed alert information with market data

- **Web Dashboard**
  - Password-protected access
  - Auto-refreshes every 60 seconds (click the countdown to pause)
  - Live / STALE badge driven by the age of the newest data, so a dead cron is obvious
  - KuCoin vs MEXC price gap and "books crossed?" check for cross-venue arbitrage risk
  - Inventory split (ERG vs USDT by value) per exchange when API keys are configured
  - Flows tab, alert history, recommendations, configurable settings

- **REST API**
  - JSON endpoints for all data
  - Integration-ready for custom tools

## Quick Start

### 1. Prerequisites

```bash
# Debian/Ubuntu
sudo apt-get update
sudo apt-get install apache2 libapache2-mod-perl2
sudo apt-get install mysql-server mysql-client
sudo apt-get install libdbi-perl libdbd-mysql-perl libjson-perl libwww-perl

# Enable CGI
sudo a2enmod cgi
sudo systemctl restart apache2
```

### 2. Database Setup

```bash
# Create the database (run as MySQL root)
mysql -u root -p < sql/schema.sql
```

**Upgrading an existing installation?** Apply the flow-tracking migration (idempotent, safe to re-run). It also removes duplicate rows from `trades` and adds the unique key the collector always assumed existed:

```bash
mysql -u root -p ergo_mm < sql/add_flow_tables.sql
```

Or manually run these commands:

```sql
-- Create database
CREATE DATABASE IF NOT EXISTS ergo_mm CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Use the database
USE ergo_mm;

-- Run the full schema from sql/schema.sql
SOURCE /path/to/ergo_mm_bot/sql/schema.sql;
```

### 3. Configuration

Create the MySQL password file:
```bash
echo "your_mysql_password" | sudo tee /usr/lib/cgi-bin/sql.txt
sudo chmod 600 /usr/lib/cgi-bin/sql.txt
```

### 4. Install Scripts

```bash
# Make scripts executable
chmod +x cgi-bin/*.pl

# Copy to CGI directory
sudo cp cgi-bin/*.pl /usr/lib/cgi-bin/
sudo chmod 755 /usr/lib/cgi-bin/*.pl
```

### 5. Setup Cron Job

```bash
# Edit crontab
crontab -e

# Add this line (runs every minute; monitor.pl holds a lock so overlapping runs are skipped)
* * * * * /usr/bin/perl /usr/lib/cgi-bin/monitor.pl >> /var/log/ergo_mm_monitor.log 2>&1
```

Every minute is the intended cadence: the exchange flow table, trade stats and the dashboard's Live/STALE badge all assume fresh data each minute. If a run takes longer than a minute (slow explorer), the next cron tick simply exits with "Previous monitor run is still in progress".

### 6. Access the Dashboard

Open your browser and navigate to:
```
http://your-server/cgi-bin/dashboard.pl
```

**Password:** `ergo_IS_FOR_anyone`

### 7. Exchange Wallet Addresses (on-chain flows)

The **Flows** tab and the "ERG On-chain Exchange Flows" card need the exchanges' Ergo wallet addresses. They live in the `config` table and are editable under **Settings → On-chain Flow Tracking**:

| Key | Default | Notes |
|-----|---------|-------|
| `kucoin_erg_addresses` | 4 community-tracked KuCoin wallets | Same set ergo.watch reports. Verify: the Flows tab shows each address's live balance. |
| `mexc_erg_addresses` | *(empty)* | MEXC's wallet is not publicly catalogued. Open one of your own MEXC ERG withdrawals on explorer.ergoplatform.com; the **sending** address is MEXC's hot wallet. |
| `flow_alert_threshold_erg` | `5000` | Single transfer size that alerts. 2x this as net 1h inflow raises `NET_INFLOW_HIGH` (critical). |
| `ergo_explorer_url` | `https://api.ergoplatform.com` | Point at your own explorer backend if the public one is slow. |
| `ergo_explorer_timeout` | `20` | Seconds per explorer request. |
| `flow_tracking_enabled` | `1` | Turn the whole feature off with `0`. |

How a transfer is classified: for each confirmed transaction touching a tracked address, ERG spent from tracked addresses counts as leaving and ERG paid to tracked addresses counts as arriving. The net is one **in** or **out** row, so change outputs and hot-to-cold shuffles cancel out. Fee-only transactions (< 0.01 ERG) are ignored. The first run backfills 48 hours but never alerts on backfilled history.

## MySQL Commands Reference

### Create Database
```sql
CREATE DATABASE IF NOT EXISTS ergo_mm;
```

### View Recent Data
```sql
-- Latest prices
SELECT * FROM v_latest_prices;

-- Latest orderbook depth
SELECT * FROM v_latest_depth;

-- Recent alerts
SELECT * FROM v_recent_alerts;

-- Active recommendations
SELECT * FROM v_active_recommendations;
```

### Check Monitoring Status
```sql
-- Check last data update
SELECT exchange, MAX(timestamp) as last_update
FROM price_data
GROUP BY exchange;

-- Count records by exchange
SELECT exchange, COUNT(*) as records
FROM price_data
WHERE timestamp > DATE_SUB(NOW(), INTERVAL 24 HOUR)
GROUP BY exchange;
```

### Cleanup Old Data
```sql
-- Manual cleanup
CALL cleanup_old_data();

-- Check data retention
SELECT
    (SELECT COUNT(*) FROM price_data) as price_records,
    (SELECT COUNT(*) FROM orderbook_depth) as depth_records,
    (SELECT COUNT(*) FROM trades) as trade_records,
    (SELECT COUNT(*) FROM alerts_log) as alert_records;
```

### Update Configuration
```sql
-- Set Discord webhook
UPDATE config SET config_value = 'https://discord.com/api/webhooks/YOUR_WEBHOOK'
WHERE config_key = 'discord_webhook';

-- Adjust spread threshold
UPDATE config SET config_value = '2.0'
WHERE config_key = 'spread_warning_threshold';

-- View all settings
SELECT * FROM config;
```

## API Endpoints

All endpoints (except health) require authentication via session cookie or `api_key` parameter.

### Overview
```
GET /cgi-bin/api.pl?endpoint=overview
```
Returns comprehensive dashboard data including prices, depth, metrics, and recommendations.

### Prices
```
GET /cgi-bin/api.pl?endpoint=prices&exchange=MEXC&hours=24
```
Parameters:
- `exchange` (optional): KUCOIN, MEXC, or omit for all
- `hours` (optional, default: 24): History period

### Depth
```
GET /cgi-bin/api.pl?endpoint=depth&exchange=KUCOIN&hours=12
```

### Alerts
```
GET /cgi-bin/api.pl?endpoint=alerts&hours=48&severity=critical
```
Parameters:
- `severity` (optional): info, warning, critical

### Trades
```
GET /cgi-bin/api.pl?endpoint=trades&exchange=MEXC&hours=24
```

### Flows (on-chain ERG in/out of exchanges)
```
GET /cgi-bin/api.pl?endpoint=flows&exchange=KUCOIN&hours=24
```
Returns `summary` (per exchange: `in_1h`, `out_1h`, `net_1h`, same for 6h/24h, `tx_24h`, `last_tx`), `reserves` (per exchange total and per-address balances), `transfers` (individual on-chain rows, newest first), `user_transfers` (the MM account's own ERG and USDT deposits/withdrawals from the account APIs, with `currency` and `network`) and `user_transfer_summary` (per exchange and asset: `in_1d`/`out_1d`/`net_1d`, same for 7d and 30d). The `overview` endpoint also carries `flows.summary` and `flows.reserves`.

### Health Check (No Auth Required)
```
GET /cgi-bin/api.pl?endpoint=health
```

## Discord Webhook Setup

1. In Discord, go to Server Settings > Integrations > Webhooks
2. Create a new webhook and copy the URL
3. In the dashboard, go to Settings and paste the webhook URL
4. Save settings

Alerts will now be sent to Discord with:
- Color-coded severity (Blue: Info, Yellow: Warning, Red: Critical)
- Detailed market data in embed fields
- Timestamp and exchange information

## Alert Types

| Alert | Trigger | Action |
|-------|---------|--------|
| SPREAD_WARNING | Spread > 1.5% | Review spread settings |
| SPREAD_CRITICAL | Spread > 3% | Immediate attention needed |
| DEPTH_WARNING | 2% depth < $5000 | Consider adding liquidity |
| DEPTH_CRITICAL | 2% depth < $2000 | Add liquidity urgently |
| PRICE_CHANGE_HIGH | 24h change > 10% | Monitor closely |
| VOLATILITY_EXTREME | 24h change > 15% | **PULL LIQUIDITY** |
| VOLUME_SPIKE | 1h volume > 3x the 24h hourly average | Widen spreads while it lasts |
| LARGE_INFLOW | Single on-chain deposit ≥ 5000 ERG | Expect selling; watch bids |
| LARGE_OUTFLOW | Single on-chain withdrawal ≥ 5000 ERG | Supply leaving the book (info) |
| NET_INFLOW_HIGH | Net 1h on-chain inflow ≥ 10000 ERG | **Lower/pull bids, widen spread** |
| INVENTORY_IMBALANCE | > 70% of your orders on one side | Rebalance |

Alert cooldowns are per alert type **and** exchange, so a KuCoin alert never suppresses the same alert for MEXC.

## Recommendations Engine

The system automatically generates trading recommendations:

- **PULL_LIQUIDITY**: Extreme volatility detected, protect funds
- **ADD_LIQUIDITY**: Orderbook depth critically low
- **TIGHTEN_SPREAD**: Spread too wide, adjust MM parameters
- **REDUCE_EXPOSURE**: High volatility, lower position sizes
- **REBALANCE**: Inventory imbalance detected
- **REDUCE_BIDS**: Large net on-chain inflow to the exchange; sell pressure likely incoming
- **HOLD**: Market conditions normal

## File Structure

```
ergo_mm_bot/
├── cgi-bin/
│   ├── monitor.pl      # Data collection script (cron)
│   ├── dashboard.pl    # Web dashboard
│   └── api.pl          # JSON API endpoints
├── sql/
│   ├── schema.sql              # Database schema (fresh installs)
│   ├── add_user_tables.sql     # Migration: balance / order tracking
│   ├── add_flow_tables.sql     # Migration: on-chain flows, transfers, trades de-dup
│   └── optimize_performance.sql
├── setup.sh            # Installation script
└── README.md           # This file
```

## Troubleshooting

### Monitor script not running
```bash
# Test manually
perl /usr/lib/cgi-bin/monitor.pl

# Check cron logs
grep CRON /var/log/syslog

# Check script log
tail -f /var/log/ergo_mm_monitor.log
```

### Database connection issues
```bash
# Test connection
mysql -u root -p ergo_mm -e "SELECT 1"

# Check password file
cat /usr/lib/cgi-bin/sql.txt

# Verify permissions
ls -la /usr/lib/cgi-bin/sql.txt
```

### CGI not working
```bash
# Check Apache CGI module
apache2ctl -M | grep cgi

# Check Apache error log
tail -f /var/log/apache2/error.log

# Test CGI permissions
ls -la /usr/lib/cgi-bin/
```

### No data appearing
```sql
-- Check if data is being collected
SELECT COUNT(*), MAX(timestamp) FROM price_data;

-- Check for errors in alerts
SELECT * FROM alerts_log ORDER BY created_at DESC LIMIT 10;
```

## Security Notes

- The dashboard password is stored in the script - change it for production
- Consider using HTTPS for the dashboard
- The MySQL password file should have restricted permissions (600)
- Session cookies are HTTP-only
- API rate limiting is not implemented - consider adding if publicly exposed

## Support

For issues and feature requests, please contact the ERGO community or submit issues through the appropriate channels.

---

**Protecting ERGO liquidity, one alert at a time.**

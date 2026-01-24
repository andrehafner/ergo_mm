# ERGO Market Maker Monitoring System

A comprehensive monitoring system for protecting ERGO community liquidity on KuCoin and MEXC exchanges. This system provides real-time monitoring, alerting, and recommendations for market making operations.

## Features

- **Real-time Market Monitoring**
  - Price tracking for ERG/USDT on KuCoin and MEXC
  - Orderbook depth analysis at 2%, 5%, and 10% levels
  - Spread monitoring and alerts
  - Volume tracking and spike detection

- **Liquidity Protection Alerts**
  - Spread threshold warnings (configurable)
  - Depth depletion alerts
  - Extreme volatility detection
  - Automated pull liquidity recommendations

- **Discord Webhook Integration**
  - Real-time alerts to your Discord server
  - Severity-based color coding
  - Detailed alert information with market data

- **Web Dashboard**
  - Password-protected access
  - Real-time market overview
  - Alert history and recommendations
  - Configurable settings

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

# Add this line (runs every 5 minutes)
*/5 * * * * /usr/bin/perl /usr/lib/cgi-bin/monitor.pl >> /var/log/ergo_mm_monitor.log 2>&1
```

For more frequent monitoring (every 1 minute):
```
* * * * * /usr/bin/perl /usr/lib/cgi-bin/monitor.pl >> /var/log/ergo_mm_monitor.log 2>&1
```

### 6. Access the Dashboard

Open your browser and navigate to:
```
http://your-server/cgi-bin/dashboard.pl
```

**Password:** `ergo_IS_FOR_anyone`

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

## Recommendations Engine

The system automatically generates trading recommendations:

- **PULL_LIQUIDITY**: Extreme volatility detected, protect funds
- **ADD_LIQUIDITY**: Orderbook depth critically low
- **TIGHTEN_SPREAD**: Spread too wide, adjust MM parameters
- **REDUCE_EXPOSURE**: High volatility, lower position sizes
- **REBALANCE**: Inventory imbalance detected
- **HOLD**: Market conditions normal

## File Structure

```
ergo_mm_bot/
├── cgi-bin/
│   ├── monitor.pl      # Data collection script (cron)
│   ├── dashboard.pl    # Web dashboard
│   └── api.pl          # JSON API endpoints
├── sql/
│   └── schema.sql      # Database schema
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

#!/usr/bin/perl
# ============================================================
# ERGO Market Maker Dashboard - Enhanced Version
# Web interface for monitoring ERG/USDT market making
# ============================================================

use strict;
use warnings;
use CGI qw(:standard);
use CGI::Cookie;
use DBI;
use JSON;
use POSIX qw(strftime);
use Digest::SHA qw(sha256_hex);

# ============================================================
# CONFIGURATION
# ============================================================
my $DASHBOARD_PASSWORD = 'ergo_IS_FOR_anyone';
my $SESSION_TIMEOUT = 86400;  # 24 hours in seconds

# ============================================================
# DATABASE CONNECTION
# ============================================================
sub get_db_password_file {
    # Check multiple locations for the password file
    my @paths = (
        '/var/www/ergo_mm/cgi-bin/sql.txt',  # nginx deployment
        '/usr/lib/cgi-bin/sql.txt',           # legacy/Apache deployment
    );

    for my $path (@paths) {
        return $path if -f $path;
    }

    die "Can't find password file in: " . join(', ', @paths);
}

sub get_db_connection {
    my $password_file = get_db_password_file();
    open my $fh, '<', $password_file or die "Can't open password file: $!";
    my $password = do { local $/; <$fh> };
    close $fh;
    $password =~ s/^\s+//;
    $password =~ s/\s+$//;

    my $dbh = DBI->connect(
        "DBI:mysql:database=ergo_mm:host=localhost",
        "root",
        $password,
        { RaiseError => 1, AutoCommit => 1, mysql_enable_utf8mb4 => 1 }
    ) or die "Can't connect to database: $DBI::errstr\n";

    return $dbh;
}

# ============================================================
# SESSION MANAGEMENT
# ============================================================
sub generate_session_id {
    return sha256_hex(time() . rand() . $$);
}

sub validate_session {
    my ($dbh, $session_id) = @_;
    return 0 unless $session_id;

    my $sth = $dbh->prepare(
        "SELECT 1 FROM sessions WHERE session_id = ? AND last_activity > DATE_SUB(NOW(), INTERVAL 24 HOUR)"
    );
    $sth->execute($session_id);
    my ($valid) = $sth->fetchrow_array();
    $sth->finish();

    if ($valid) {
        $dbh->do("UPDATE sessions SET last_activity = NOW() WHERE session_id = ?", undef, $session_id);
    }

    return $valid;
}

sub create_session {
    my ($dbh, $ip) = @_;
    my $session_id = generate_session_id();

    $dbh->do(
        "INSERT INTO sessions (session_id, ip_address) VALUES (?, ?)",
        undef, $session_id, $ip
    );

    return $session_id;
}

sub destroy_session {
    my ($dbh, $session_id) = @_;
    $dbh->do("DELETE FROM sessions WHERE session_id = ?", undef, $session_id);
}

# ============================================================
# DATA FETCHING FUNCTIONS
# ============================================================
sub get_latest_prices {
    my ($dbh) = @_;
    # Direct query with LIMIT - much faster than view
    my $sth = $dbh->prepare(qq{
        (SELECT * FROM price_data WHERE exchange = 'MEXC' ORDER BY timestamp DESC LIMIT 1)
        UNION ALL
        (SELECT * FROM price_data WHERE exchange = 'KUCOIN' ORDER BY timestamp DESC LIMIT 1)
    });
    $sth->execute();
    my @results;
    while (my $row = $sth->fetchrow_hashref()) {
        push @results, $row;
    }
    $sth->finish();
    return \@results;
}

sub get_latest_depth {
    my ($dbh) = @_;
    # Direct query for each exchange/level combo
    my $sth = $dbh->prepare(qq{
        SELECT * FROM orderbook_depth
        WHERE (exchange, depth_level, timestamp) IN (
            SELECT exchange, depth_level, MAX(timestamp)
            FROM orderbook_depth
            WHERE timestamp > DATE_SUB(NOW(), INTERVAL 1 HOUR)
            GROUP BY exchange, depth_level
        )
        ORDER BY exchange, depth_level
    });
    $sth->execute();
    my %results;
    while (my $row = $sth->fetchrow_hashref()) {
        $results{$row->{exchange}}{$row->{depth_level}} = $row;
    }
    $sth->finish();
    return \%results;
}

sub get_latest_metrics {
    my ($dbh) = @_;
    my $sth = $dbh->prepare(qq{
        (SELECT * FROM market_metrics WHERE exchange = 'MEXC' ORDER BY calculated_at DESC LIMIT 1)
        UNION ALL
        (SELECT * FROM market_metrics WHERE exchange = 'KUCOIN' ORDER BY calculated_at DESC LIMIT 1)
    });
    $sth->execute();
    my %results;
    while (my $row = $sth->fetchrow_hashref()) {
        $results{$row->{exchange}} = $row;
    }
    $sth->finish();
    return \%results;
}

sub get_active_recommendations {
    my ($dbh) = @_;
    # Direct query instead of view
    my $sth = $dbh->prepare(qq{
        SELECT * FROM recommendations
        WHERE is_active = 1
          AND (expires_at IS NULL OR expires_at > NOW())
        ORDER BY priority DESC, created_at DESC
        LIMIT 10
    });
    $sth->execute();
    my @results;
    while (my $row = $sth->fetchrow_hashref()) {
        push @results, $row;
    }
    $sth->finish();
    return \@results;
}

sub get_recent_alerts {
    my ($dbh, $limit) = @_;
    $limit ||= 20;
    # Direct query instead of view
    my $sth = $dbh->prepare(qq{
        SELECT * FROM alerts_log
        WHERE created_at > DATE_SUB(NOW(), INTERVAL 24 HOUR)
        ORDER BY created_at DESC
        LIMIT ?
    });
    $sth->execute($limit);
    my @results;
    while (my $row = $sth->fetchrow_hashref()) {
        push @results, $row;
    }
    $sth->finish();
    return \@results;
}

sub get_price_history {
    my ($dbh, $exchange, $hours) = @_;
    $hours ||= 24;

    # Aggregate by 5-minute buckets for better performance (max ~288 rows for 24h)
    my $sth = $dbh->prepare(qq{
        SELECT
            DATE_FORMAT(timestamp, '%Y-%m-%d %H:') as hour_part,
            LPAD(FLOOR(MINUTE(timestamp) / 5) * 5, 2, '0') as min_bucket,
            AVG(price) as price,
            AVG(spread_percent) as spread,
            MAX(high_24h) as high,
            MIN(low_24h) as low,
            AVG(volume_24h_usd) as volume
        FROM price_data
        WHERE exchange = ?
          AND timestamp > DATE_SUB(NOW(), INTERVAL ? HOUR)
        GROUP BY hour_part, min_bucket
        ORDER BY hour_part, min_bucket
        LIMIT 300
    });
    $sth->execute($exchange, $hours);
    my @results;
    while (my $row = $sth->fetchrow_hashref()) {
        $row->{time_bucket} = $row->{hour_part} . $row->{min_bucket};
        push @results, $row;
    }
    $sth->finish();
    return \@results;
}

sub get_depth_history {
    my ($dbh, $exchange, $hours) = @_;
    $hours ||= 24;

    # Aggregate by 15-minute buckets for better performance (max ~96 rows per level for 24h)
    my $sth = $dbh->prepare(qq{
        SELECT
            DATE_FORMAT(timestamp, '%Y-%m-%d %H:') as hour_part,
            LPAD(FLOOR(MINUTE(timestamp) / 15) * 15, 2, '0') as min_bucket,
            depth_level,
            AVG(bid_depth_usd) as bid_depth,
            AVG(ask_depth_usd) as ask_depth
        FROM orderbook_depth
        WHERE exchange = ?
          AND timestamp > DATE_SUB(NOW(), INTERVAL ? HOUR)
        GROUP BY hour_part, min_bucket, depth_level
        ORDER BY hour_part, min_bucket, depth_level
        LIMIT 500
    });
    $sth->execute($exchange, $hours);
    my @results;
    while (my $row = $sth->fetchrow_hashref()) {
        $row->{time_bucket} = $row->{hour_part} . $row->{min_bucket};
        push @results, $row;
    }
    $sth->finish();
    return \@results;
}

sub get_trade_history {
    my ($dbh, $exchange, $hours) = @_;
    $hours ||= 24;

    my $sth = $dbh->prepare(qq{
        SELECT
            DATE_FORMAT(recorded_at, '%Y-%m-%d %H:00') as time_bucket,
            COUNT(*) as trade_count,
            SUM(amount_usd) as total_volume,
            SUM(CASE WHEN side = 'buy' THEN amount_usd ELSE 0 END) as buy_volume,
            SUM(CASE WHEN side = 'sell' THEN amount_usd ELSE 0 END) as sell_volume,
            AVG(price) as avg_price
        FROM trades
        WHERE exchange = ?
          AND recorded_at > DATE_SUB(NOW(), INTERVAL ? HOUR)
        GROUP BY time_bucket
        ORDER BY time_bucket
        LIMIT 50
    });
    $sth->execute($exchange, $hours);
    my @results;
    while (my $row = $sth->fetchrow_hashref()) {
        push @results, $row;
    }
    $sth->finish();
    return \@results;
}

sub get_config {
    my ($dbh) = @_;
    my $sth = $dbh->prepare("SELECT config_key, config_value, description FROM config");
    $sth->execute();
    my %config;
    while (my $row = $sth->fetchrow_hashref()) {
        $config{$row->{config_key}} = {
            value => $row->{config_value},
            description => $row->{description}
        };
    }
    $sth->finish();
    return \%config;
}

sub get_latest_user_balances {
    my ($dbh) = @_;
    # Direct query - much faster than view
    my $sth = $dbh->prepare(qq{
        (SELECT * FROM user_balances WHERE exchange = 'MEXC' ORDER BY timestamp DESC LIMIT 1)
        UNION ALL
        (SELECT * FROM user_balances WHERE exchange = 'KUCOIN' ORDER BY timestamp DESC LIMIT 1)
    });
    $sth->execute();
    my %results;
    while (my $row = $sth->fetchrow_hashref()) {
        $results{$row->{exchange}} = $row;
    }
    $sth->finish();
    return \%results;
}

sub get_latest_user_depth {
    my ($dbh) = @_;
    # Direct query for recent data only
    my $sth = $dbh->prepare(qq{
        SELECT * FROM user_orderbook_depth
        WHERE timestamp > DATE_SUB(NOW(), INTERVAL 1 HOUR)
        AND (exchange, depth_level, timestamp) IN (
            SELECT exchange, depth_level, MAX(timestamp)
            FROM user_orderbook_depth
            WHERE timestamp > DATE_SUB(NOW(), INTERVAL 1 HOUR)
            GROUP BY exchange, depth_level
        )
        ORDER BY exchange, depth_level
    });
    $sth->execute();
    my %results;
    while (my $row = $sth->fetchrow_hashref()) {
        $results{$row->{exchange}}{$row->{depth_level}} = $row;
    }
    $sth->finish();
    return \%results;
}

sub get_user_open_orders {
    my ($dbh) = @_;
    # Only get orders from the last 2 hours (should be current snapshot)
    my $sth = $dbh->prepare(qq{
        SELECT * FROM user_open_orders
        WHERE recorded_at > DATE_SUB(NOW(), INTERVAL 2 HOUR)
        ORDER BY exchange, side, price
        LIMIT 200
    });
    $sth->execute();
    my %results;
    while (my $row = $sth->fetchrow_hashref()) {
        push @{$results{$row->{exchange}}{$row->{side}}}, $row;
    }
    $sth->finish();
    return \%results;
}

sub update_config {
    my ($dbh, $key, $value) = @_;
    $dbh->do(
        "UPDATE config SET config_value = ? WHERE config_key = ?",
        undef, $value, $key
    );
}

sub get_trade_summary {
    my ($dbh, $exchange, $hours) = @_;
    $hours ||= 24;

    my $sth = $dbh->prepare(qq{
        SELECT
            COUNT(*) as trade_count,
            SUM(amount) as total_erg,
            SUM(amount_usd) as total_usd,
            SUM(CASE WHEN side = 'buy' THEN amount_usd ELSE 0 END) as buy_volume,
            SUM(CASE WHEN side = 'sell' THEN amount_usd ELSE 0 END) as sell_volume,
            AVG(price) as avg_price
        FROM trades
        WHERE exchange = ?
          AND recorded_at > DATE_SUB(NOW(), INTERVAL ? HOUR)
    });
    $sth->execute($exchange, $hours);
    my $row = $sth->fetchrow_hashref();
    $sth->finish();
    return $row;
}

# ============================================================
# HTML GENERATION
# ============================================================
sub html_header {
    my ($title) = @_;
    $title ||= 'ERGO MM Dashboard';

    return qq{<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$title</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght\@400;500;600;700&display=swap" rel="stylesheet">
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns"></script>
    <style>
        :root {
            --bg-primary: #1a1d23;
            --bg-secondary: #22262e;
            --bg-tertiary: #2a2f38;
            --bg-card: #252a33;
            --text-primary: #e8eaed;
            --text-secondary: #9aa0a6;
            --text-muted: #6b7280;
            --accent-cyan: #00d4aa;
            --accent-blue: #3b82f6;
            --accent-purple: #8b5cf6;
            --accent-orange: #f59e0b;
            --accent-red: #ef4444;
            --accent-green: #22c55e;
            --border-color: #374151;
            --shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.3);
        }

        * { margin: 0; padding: 0; box-sizing: border-box; }

        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            min-height: 100vh;
            line-height: 1.5;
        }

        .container { max-width: 1800px; margin: 0 auto; padding: 20px; }

        .header {
            background: linear-gradient(135deg, var(--bg-secondary) 0%, var(--bg-tertiary) 100%);
            border-bottom: 1px solid var(--border-color);
            padding: 16px 24px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 24px;
            border-radius: 12px;
        }

        .header-title h1 {
            font-size: 24px;
            font-weight: 700;
            background: linear-gradient(90deg, var(--accent-cyan), var(--accent-blue));
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        .header-subtitle { color: var(--text-secondary); font-size: 14px; }

        .header-actions { display: flex; gap: 12px; align-items: center; }

        .btn {
            padding: 8px 16px;
            border-radius: 8px;
            font-size: 14px;
            font-weight: 500;
            cursor: pointer;
            border: none;
            transition: all 0.2s;
            text-decoration: none;
            display: inline-flex;
            align-items: center;
            gap: 6px;
        }

        .btn-primary { background: var(--accent-cyan); color: var(--bg-primary); }
        .btn-primary:hover { background: #00b894; }
        .btn-secondary { background: var(--bg-tertiary); color: var(--text-primary); border: 1px solid var(--border-color); }
        .btn-secondary:hover { background: var(--bg-card); }

        .status-indicator {
            display: flex;
            align-items: center;
            gap: 8px;
            padding: 6px 12px;
            background: var(--bg-tertiary);
            border-radius: 20px;
            font-size: 13px;
        }

        .status-dot {
            width: 8px;
            height: 8px;
            border-radius: 50%;
            animation: pulse 2s infinite;
        }

        .status-dot.online { background: var(--accent-green); }
        .status-dot.offline { background: var(--accent-red); }

        \@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }

        .dashboard-grid {
            display: grid;
            grid-template-columns: repeat(12, 1fr);
            gap: 20px;
        }

        .card {
            background: var(--bg-card);
            border-radius: 12px;
            border: 1px solid var(--border-color);
            overflow: hidden;
        }

        .card-header {
            padding: 16px 20px;
            border-bottom: 1px solid var(--border-color);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .card-title { font-size: 16px; font-weight: 600; color: var(--text-primary); }
        .card-badge { padding: 4px 10px; border-radius: 12px; font-size: 12px; font-weight: 500; background: var(--bg-tertiary); }
        .card-body { padding: 20px; }

        .exchange-card { grid-column: span 6; }

        .exchange-header { display: flex; align-items: center; gap: 12px; margin-bottom: 16px; }

        .exchange-logo {
            width: 40px;
            height: 40px;
            border-radius: 10px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-weight: 700;
            font-size: 12px;
            color: white;
        }

        .exchange-logo.kucoin { background: linear-gradient(135deg, #24ae8f, #1a7a64); }
        .exchange-logo.mexc { background: linear-gradient(135deg, #1652f0, #0d3d9e); }

        .exchange-name { font-size: 18px; font-weight: 600; }
        .exchange-pair { color: var(--text-secondary); font-size: 14px; }

        .metrics-row {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 12px;
            margin-bottom: 20px;
        }

        .metric-box {
            background: var(--bg-tertiary);
            border-radius: 10px;
            padding: 14px;
            text-align: center;
        }

        .metric-label {
            font-size: 11px;
            color: var(--text-secondary);
            text-transform: uppercase;
            letter-spacing: 0.5px;
            margin-bottom: 6px;
        }

        .metric-value { font-size: 20px; font-weight: 700; color: var(--text-primary); }
        .metric-value.positive { color: var(--accent-green); }
        .metric-value.negative { color: var(--accent-red); }
        .metric-value.warning { color: var(--accent-orange); }
        .metric-change { font-size: 11px; margin-top: 4px; color: var(--text-secondary); }

        .chart-container { position: relative; height: 200px; margin-bottom: 16px; }
        .chart-container.tall { height: 280px; }

        .depth-table { width: 100%; border-collapse: collapse; font-size: 13px; }
        .depth-table th, .depth-table td { padding: 10px 12px; text-align: right; border-bottom: 1px solid var(--border-color); }
        .depth-table th { font-size: 11px; font-weight: 600; color: var(--text-secondary); text-transform: uppercase; }
        .depth-table th:first-child, .depth-table td:first-child { text-align: left; }
        .depth-table tr:last-child td { border-bottom: none; }
        .bid-value { color: var(--accent-green); }
        .ask-value { color: var(--accent-red); }

        /* User Liquidity Section Styles */
        .section-divider {
            height: 1px;
            background: linear-gradient(90deg, transparent, var(--border-color), transparent);
            margin: 20px 0;
        }

        .user-liquidity-section {
            background: rgba(0, 212, 170, 0.05);
            border: 1px solid rgba(0, 212, 170, 0.2);
            border-radius: 8px;
            padding: 16px;
            margin-top: 16px;
        }

        .section-title {
            font-size: 14px;
            font-weight: 600;
            color: var(--accent-cyan);
            margin-bottom: 12px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }

        .balance-row {
            display: flex;
            gap: 12px;
            margin-bottom: 16px;
        }

        .balance-box {
            flex: 1;
            background: var(--bg-tertiary);
            padding: 12px;
            border-radius: 6px;
        }

        .balance-box.highlight {
            background: linear-gradient(135deg, rgba(0, 212, 170, 0.2), rgba(59, 130, 246, 0.2));
            border: 1px solid rgba(0, 212, 170, 0.3);
        }

        .balance-label {
            font-size: 11px;
            font-weight: 500;
            color: var(--text-secondary);
            text-transform: uppercase;
            margin-bottom: 4px;
        }

        .balance-value {
            font-size: 18px;
            font-weight: 600;
            color: var(--text-primary);
        }

        .balance-detail {
            font-size: 11px;
            color: var(--text-muted);
            margin-top: 4px;
        }

        .user-depth-table {
            margin-top: 12px;
            background: var(--bg-tertiary);
            border-radius: 6px;
        }

        .user-depth-table td.highlight {
            color: var(--accent-cyan);
            font-weight: 600;
        }

        .orders-summary {
            display: flex;
            gap: 12px;
            margin-top: 12px;
        }

        .orders-box {
            flex: 1;
            padding: 12px;
            border-radius: 6px;
            text-align: center;
        }

        .orders-box.bid-orders {
            background: rgba(34, 197, 94, 0.15);
            border: 1px solid rgba(34, 197, 94, 0.3);
        }

        .orders-box.ask-orders {
            background: rgba(239, 68, 68, 0.15);
            border: 1px solid rgba(239, 68, 68, 0.3);
        }

        .orders-label {
            font-size: 11px;
            color: var(--text-secondary);
            text-transform: uppercase;
        }

        .orders-count {
            font-size: 24px;
            font-weight: 600;
            margin-top: 4px;
        }

        .bid-orders .orders-count { color: var(--accent-green); }
        .ask-orders .orders-count { color: var(--accent-red); }

        .tabs {
            display: flex;
            gap: 4px;
            background: var(--bg-secondary);
            padding: 4px;
            border-radius: 10px;
            margin-bottom: 24px;
        }

        .tab {
            padding: 10px 20px;
            border-radius: 8px;
            font-size: 14px;
            font-weight: 500;
            color: var(--text-secondary);
            cursor: pointer;
            transition: all 0.2s;
            text-decoration: none;
        }

        .tab:hover { color: var(--text-primary); background: var(--bg-tertiary); }
        .tab.active { background: var(--accent-cyan); color: var(--bg-primary); }

        .full-width { grid-column: span 12; }
        .half-width { grid-column: span 6; }
        .third-width { grid-column: span 4; }

        .alert-list { max-height: 400px; overflow-y: auto; }

        .alert-item {
            display: flex;
            align-items: flex-start;
            gap: 12px;
            padding: 12px;
            border-bottom: 1px solid var(--border-color);
        }

        .alert-item:last-child { border-bottom: none; }

        .alert-severity {
            width: 10px;
            height: 10px;
            border-radius: 50%;
            margin-top: 5px;
            flex-shrink: 0;
        }

        .alert-severity.critical { background: var(--accent-red); }
        .alert-severity.warning { background: var(--accent-orange); }
        .alert-severity.info { background: var(--accent-blue); }

        .alert-message { font-size: 13px; margin-bottom: 4px; }
        .alert-time { font-size: 11px; color: var(--text-muted); }

        .recommendation-list { display: flex; flex-direction: column; gap: 10px; }

        .recommendation-item {
            display: flex;
            align-items: flex-start;
            gap: 12px;
            padding: 14px;
            background: var(--bg-tertiary);
            border-radius: 10px;
            border-left: 4px solid;
        }

        .recommendation-item.priority-high { border-left-color: var(--accent-red); }
        .recommendation-item.priority-medium { border-left-color: var(--accent-orange); }
        .recommendation-item.priority-low { border-left-color: var(--accent-blue); }

        .recommendation-icon { font-size: 20px; }
        .recommendation-action { font-weight: 600; font-size: 14px; margin-bottom: 4px; }
        .recommendation-reason { color: var(--text-secondary); font-size: 13px; }
        .recommendation-meta { display: flex; gap: 16px; margin-top: 6px; font-size: 11px; color: var(--text-muted); }

        .empty-state { text-align: center; padding: 40px 20px; color: var(--text-secondary); }
        .empty-state-icon { font-size: 48px; margin-bottom: 16px; opacity: 0.5; }

        .settings-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 20px; }
        .setting-group { background: var(--bg-tertiary); border-radius: 10px; padding: 20px; }
        .setting-group h3 { font-size: 14px; font-weight: 600; margin-bottom: 16px; }
        .setting-item { margin-bottom: 14px; }
        .setting-item:last-child { margin-bottom: 0; }
        .setting-label { display: block; font-size: 13px; color: var(--text-secondary); margin-bottom: 6px; }
        .setting-input {
            width: 100%;
            padding: 10px 14px;
            border-radius: 8px;
            border: 1px solid var(--border-color);
            background: var(--bg-secondary);
            color: var(--text-primary);
            font-size: 14px;
        }
        .setting-input:focus { outline: none; border-color: var(--accent-cyan); }
        .setting-description { font-size: 11px; color: var(--text-muted); margin-top: 4px; }

        .login-container { display: flex; align-items: center; justify-content: center; min-height: 100vh; }
        .login-box {
            background: var(--bg-card);
            border-radius: 16px;
            padding: 40px;
            width: 100%;
            max-width: 400px;
            border: 1px solid var(--border-color);
        }
        .login-title { text-align: center; margin-bottom: 32px; }
        .login-title h1 {
            font-size: 28px;
            font-weight: 700;
            margin-bottom: 8px;
            background: linear-gradient(90deg, var(--accent-cyan), var(--accent-blue));
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .login-title p { color: var(--text-secondary); font-size: 14px; }
        .login-form input {
            width: 100%;
            padding: 14px 18px;
            border-radius: 10px;
            border: 1px solid var(--border-color);
            background: var(--bg-secondary);
            color: var(--text-primary);
            font-size: 16px;
            margin-bottom: 20px;
        }
        .login-form input:focus { outline: none; border-color: var(--accent-cyan); }
        .login-form button {
            width: 100%;
            padding: 14px;
            border-radius: 10px;
            background: linear-gradient(90deg, var(--accent-cyan), var(--accent-blue));
            color: var(--bg-primary);
            font-size: 16px;
            font-weight: 600;
            border: none;
            cursor: pointer;
        }
        .login-error {
            background: rgba(239, 68, 68, 0.1);
            border: 1px solid var(--accent-red);
            border-radius: 8px;
            padding: 12px;
            margin-bottom: 20px;
            color: var(--accent-red);
            font-size: 14px;
            text-align: center;
        }

        .stats-row {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 12px;
            margin-top: 16px;
        }

        .stat-box {
            background: var(--bg-secondary);
            border-radius: 8px;
            padding: 12px;
            text-align: center;
        }

        .stat-label { font-size: 10px; color: var(--text-muted); text-transform: uppercase; margin-bottom: 4px; }
        .stat-value { font-size: 16px; font-weight: 600; }

        \@media (max-width: 1200px) {
            .exchange-card, .half-width { grid-column: span 12; }
            .third-width { grid-column: span 6; }
        }

        \@media (max-width: 768px) {
            .metrics-row { grid-template-columns: repeat(2, 1fr); }
            .third-width { grid-column: span 12; }
            .settings-grid { grid-template-columns: 1fr; }
        }

        ::-webkit-scrollbar { width: 8px; height: 8px; }
        ::-webkit-scrollbar-track { background: var(--bg-secondary); }
        ::-webkit-scrollbar-thumb { background: var(--border-color); border-radius: 4px; }
    </style>
</head>
<body>
};
}

sub html_footer {
    return qq{
</body>
</html>
};
}

sub render_login_page {
    my ($error) = @_;

    print "Content-type: text/html\n\n";
    print html_header('ERGO MM Dashboard - Login');

    my $error_html = '';
    if ($error) {
        $error_html = qq{<div class="login-error">$error</div>};
    }

    print qq{
    <div class="login-container">
        <div class="login-box">
            <div class="login-title">
                <h1>ERGO MM</h1>
                <p>Market Maker Monitoring Dashboard</p>
            </div>
            $error_html
            <form class="login-form" method="POST">
                <input type="password" name="password" placeholder="Enter password" autofocus required>
                <button type="submit">Access Dashboard</button>
            </form>
        </div>
    </div>
    };

    print html_footer();
}

sub render_dashboard {
    my ($dbh, $tab, $saved) = @_;
    $tab ||= 'overview';

    my $prices = get_latest_prices($dbh);
    my $depth = get_latest_depth($dbh);
    my $metrics = get_latest_metrics($dbh);
    my $recommendations = get_active_recommendations($dbh);
    my $alerts = get_recent_alerts($dbh, 20);
    my $config = get_config($dbh);

    # Get chart data for each exchange (6h window for fast loading)
    my %chart_data;
    foreach my $exchange ('MEXC', 'KUCOIN') {
        $chart_data{$exchange} = {
            price_history => get_price_history($dbh, $exchange, 6),
            depth_history => get_depth_history($dbh, $exchange, 6),
            trade_history => get_trade_history($dbh, $exchange, 6),
            trade_summary => get_trade_summary($dbh, $exchange, 6),
        };
    }

    print "Content-type: text/html\n\n";
    print html_header('ERGO MM Dashboard');

    print qq{
    <div class="container">
        <div class="header">
            <div class="header-title">
                <div>
                    <h1>ERGO Market Maker</h1>
                    <div class="header-subtitle">Liquidity Protection Dashboard</div>
                </div>
            </div>
            <div class="header-actions">
                <div class="status-indicator">
                    <span class="status-dot online"></span>
                    <span>Monitoring Active</span>
                </div>
                <a href="?tab=settings" class="btn btn-secondary">Settings</a>
                <a href="?logout=1" class="btn btn-secondary">Logout</a>
            </div>
        </div>

        <div class="tabs">
            <a href="?tab=overview" class="tab } . ($tab eq 'overview' ? 'active' : '') . qq{">Overview</a>
            <a href="?tab=charts" class="tab } . ($tab eq 'charts' ? 'active' : '') . qq{">Charts</a>
            <a href="?tab=alerts" class="tab } . ($tab eq 'alerts' ? 'active' : '') . qq{">Alerts</a>
            <a href="?tab=settings" class="tab } . ($tab eq 'settings' ? 'active' : '') . qq{">Settings</a>
        </div>
    };

    if ($tab eq 'overview') {
        render_overview_tab($dbh, $prices, $depth, $metrics, $recommendations, $alerts, \%chart_data);
    } elsif ($tab eq 'charts') {
        render_charts_tab($dbh, \%chart_data, $config);
    } elsif ($tab eq 'alerts') {
        render_alerts_tab($alerts);
    } elsif ($tab eq 'settings') {
        render_settings_tab($config, $saved);
    }

    print qq{</div>};
    print html_footer();
}

sub render_overview_tab {
    my ($dbh, $prices, $depth, $metrics, $recommendations, $alerts, $chart_data) = @_;

    # Fetch user balance and depth data
    my $user_balances = get_latest_user_balances($dbh);
    my $user_depth = get_latest_user_depth($dbh);
    my $user_orders = get_user_open_orders($dbh);

    print qq{<div class="dashboard-grid">};

    # Exchange Cards
    foreach my $exchange_data (@$prices) {
        my $exchange = $exchange_data->{exchange};
        my $exchange_lower = lc($exchange);
        my $exchange_depth = $depth->{$exchange} || {};
        my $exchange_metrics = $metrics->{$exchange} || {};
        my $exchange_charts = $chart_data->{$exchange} || {};
        my $trade_summary = $exchange_charts->{trade_summary} || {};

        my $spread_class = '';
        if (($exchange_data->{spread_percent} || 0) >= 3) {
            $spread_class = 'negative';
        } elsif (($exchange_data->{spread_percent} || 0) >= 1.5) {
            $spread_class = 'warning';
        }

        my $change_pct = $exchange_data->{price_change_percent_24h} || 0;
        my $change_class = $change_pct >= 0 ? 'positive' : 'negative';
        my $change_sign = $change_pct >= 0 ? '+' : '';

        # Prepare price chart data
        my $price_history = $exchange_charts->{price_history} || [];
        my @price_labels = map { $_->{time_bucket} } @$price_history;
        my @price_values = map { $_->{price} || 0 } @$price_history;
        my @spread_values = map { $_->{spread} || 0 } @$price_history;

        my $price_labels_json = encode_json(\@price_labels);
        my $price_values_json = encode_json(\@price_values);
        my $spread_values_json = encode_json(\@spread_values);

        # Prepare depth chart data
        my $depth_history = $exchange_charts->{depth_history} || [];
        my %depth_by_time;
        foreach my $d (@$depth_history) {
            my $time = $d->{time_bucket};
            my $level = $d->{depth_level};
            $depth_by_time{$time}{$level}{bid} = $d->{bid_depth} || 0;
            $depth_by_time{$time}{$level}{ask} = $d->{ask_depth} || 0;
        }

        my @depth_times = sort keys %depth_by_time;
        my @bid_2pct = map { $depth_by_time{$_}{'2%'}{bid} || 0 } @depth_times;
        my @bid_5pct = map { $depth_by_time{$_}{'5%'}{bid} || 0 } @depth_times;
        my @ask_2pct = map { $depth_by_time{$_}{'2%'}{ask} || 0 } @depth_times;
        my @ask_5pct = map { $depth_by_time{$_}{'5%'}{ask} || 0 } @depth_times;

        my $depth_labels_json = encode_json(\@depth_times);
        my $bid_2pct_json = encode_json(\@bid_2pct);
        my $bid_5pct_json = encode_json(\@bid_5pct);
        my $ask_2pct_json = encode_json(\@ask_2pct);
        my $ask_5pct_json = encode_json(\@ask_5pct);

        # Prepare trade chart data
        my $trade_history = $exchange_charts->{trade_history} || [];
        my @trade_labels = map { $_->{time_bucket} } @$trade_history;
        my @buy_volumes = map { $_->{buy_volume} || 0 } @$trade_history;
        my @sell_volumes = map { $_->{sell_volume} || 0 } @$trade_history;

        my $trade_labels_json = encode_json(\@trade_labels);
        my $buy_volumes_json = encode_json(\@buy_volumes);
        my $sell_volumes_json = encode_json(\@sell_volumes);

        print qq{
        <div class="card exchange-card">
            <div class="card-body">
                <div class="exchange-header">
                    <div class="exchange-logo $exchange_lower">$exchange</div>
                    <div>
                        <div class="exchange-name">$exchange</div>
                        <div class="exchange-pair">ERG/USDT</div>
                    </div>
                </div>

                <div class="metrics-row">
                    <div class="metric-box">
                        <div class="metric-label">Price</div>
                        <div class="metric-value">\$} . sprintf("%.4f", $exchange_data->{price} || 0) . qq{</div>
                        <div class="metric-change $change_class">$change_sign} . sprintf("%.2f", $change_pct) . qq{%</div>
                    </div>
                    <div class="metric-box">
                        <div class="metric-label">Spread</div>
                        <div class="metric-value $spread_class">} . sprintf("%.2f", $exchange_data->{spread_percent} || 0) . qq{%</div>
                    </div>
                    <div class="metric-box">
                        <div class="metric-label">24h Volume</div>
                        <div class="metric-value">\$} . format_number($exchange_data->{volume_24h_usd}) . qq{</div>
                    </div>
                    <div class="metric-box">
                        <div class="metric-label">24h Range</div>
                        <div class="metric-value">} . sprintf("%.1f", $exchange_metrics->{price_range_24h} || 0) . qq{%</div>
                    </div>
                </div>

                <!-- Price History Chart -->
                <div class="chart-container">
                    <canvas id="priceChart_$exchange_lower"></canvas>
                </div>

                <!-- Spread Chart -->
                <div class="chart-container">
                    <canvas id="spreadChart_$exchange_lower"></canvas>
                </div>

                <!-- Depth Table -->
                <table class="depth-table">
                    <thead>
                        <tr>
                            <th>Depth</th>
                            <th>Bid</th>
                            <th>Ask</th>
                            <th>Total</th>
                        </tr>
                    </thead>
                    <tbody>
        };

        foreach my $level ('2%', '5%', '10%') {
            my $level_depth = $exchange_depth->{$level} || {};
            my $bid_usd = $level_depth->{bid_depth_usd} || 0;
            my $ask_usd = $level_depth->{ask_depth_usd} || 0;
            my $total = $bid_usd + $ask_usd;

            print qq{
                        <tr>
                            <td>$level</td>
                            <td class="bid-value">\$} . format_number($bid_usd) . qq{</td>
                            <td class="ask-value">\$} . format_number($ask_usd) . qq{</td>
                            <td>\$} . format_number($total) . qq{</td>
                        </tr>
            };
        }

        # Display user liquidity data if available
        my $user_bal = $user_balances->{$exchange};
        my $user_dep = $user_depth->{$exchange} || {};
        my $user_ord = $user_orders->{$exchange} || {};

        if ($user_bal || %$user_dep) {
            print qq{
                    </tbody>
                </table>

                <div class="section-divider"></div>
                <div class="user-liquidity-section">
                    <h4 class="section-title">Your Liquidity</h4>
            };

            # Display balances
            if ($user_bal) {
                print qq{
                    <div class="balance-row">
                        <div class="balance-box">
                            <div class="balance-label">ERG Balance</div>
                            <div class="balance-value">} . sprintf("%.2f", $user_bal->{erg_total} || 0) . qq{</div>
                            <div class="balance-detail">Free: } . sprintf("%.2f", $user_bal->{erg_free} || 0) . qq{ | In Orders: } . sprintf("%.2f", $user_bal->{erg_locked} || 0) . qq{</div>
                        </div>
                        <div class="balance-box">
                            <div class="balance-label">USDT Balance</div>
                            <div class="balance-value">\$} . sprintf("%.2f", $user_bal->{usdt_total} || 0) . qq{</div>
                            <div class="balance-detail">Free: \$} . sprintf("%.2f", $user_bal->{usdt_free} || 0) . qq{ | In Orders: \$} . sprintf("%.2f", $user_bal->{usdt_locked} || 0) . qq{</div>
                        </div>
                        <div class="balance-box highlight">
                            <div class="balance-label">Total Value</div>
                            <div class="balance-value">\$} . sprintf("%.2f", $user_bal->{total_value_usd} || 0) . qq{</div>
                        </div>
                    </div>
                };
            }

            # Display user depth share table
            if (%$user_dep) {
                print qq{
                    <table class="depth-table user-depth-table">
                        <thead>
                            <tr>
                                <th>Depth</th>
                                <th>Your Bids</th>
                                <th>Your Asks</th>
                                <th>Bid Share</th>
                                <th>Ask Share</th>
                            </tr>
                        </thead>
                        <tbody>
                };

                foreach my $level ('2%', '5%', '10%') {
                    my $ud = $user_dep->{$level} || {};
                    my $bid_share = $ud->{bid_share_pct} || 0;
                    my $ask_share = $ud->{ask_share_pct} || 0;
                    my $bid_class = $bid_share > 20 ? 'highlight' : '';
                    my $ask_class = $ask_share > 20 ? 'highlight' : '';

                    print qq{
                            <tr>
                                <td>$level</td>
                                <td class="bid-value">\$} . format_number($ud->{bid_depth_usd} || 0) . qq{</td>
                                <td class="ask-value">\$} . format_number($ud->{ask_depth_usd} || 0) . qq{</td>
                                <td class="$bid_class">} . sprintf("%.1f", $bid_share) . qq{%</td>
                                <td class="$ask_class">} . sprintf("%.1f", $ask_share) . qq{%</td>
                            </tr>
                    };
                }

                print qq{
                        </tbody>
                    </table>
                };
            }

            # Display open orders summary
            my @buy_orders = @{$user_ord->{buy} || []};
            my @sell_orders = @{$user_ord->{sell} || []};

            if (@buy_orders || @sell_orders) {
                print qq{
                    <div class="orders-summary">
                        <div class="orders-box bid-orders">
                            <div class="orders-label">Buy Orders</div>
                            <div class="orders-count">} . scalar(@buy_orders) . qq{</div>
                        </div>
                        <div class="orders-box ask-orders">
                            <div class="orders-label">Sell Orders</div>
                            <div class="orders-count">} . scalar(@sell_orders) . qq{</div>
                        </div>
                    </div>
                };
            }

            print qq{
                </div>
            };
        }

        print qq{
                    </tbody>
                </table>
        } unless ($user_bal || %$user_dep);

        my $buy_vol = $trade_summary->{buy_volume} || 0;
        my $sell_vol = $trade_summary->{sell_volume} || 0;
        my $total_vol = $buy_vol + $sell_vol;
        my $buy_ratio = $total_vol > 0 ? ($buy_vol / $total_vol * 100) : 50;

        print qq{
                    </tbody>
                </table>

                <div class="stats-row">
                    <div class="stat-box">
                        <div class="stat-label">24h Trades</div>
                        <div class="stat-value">} . ($trade_summary->{trade_count} || 0) . qq{</div>
                    </div>
                    <div class="stat-box">
                        <div class="stat-label">Buy Vol</div>
                        <div class="stat-value bid-value">\$} . format_number($buy_vol) . qq{</div>
                    </div>
                    <div class="stat-box">
                        <div class="stat-label">Sell Vol</div>
                        <div class="stat-value ask-value">\$} . format_number($sell_vol) . qq{</div>
                    </div>
                </div>
            </div>
        </div>

        <script>
        (function() {
            // Price Chart
            const priceCtx_$exchange_lower = document.getElementById('priceChart_$exchange_lower').getContext('2d');
            new Chart(priceCtx_$exchange_lower, {
                type: 'line',
                data: {
                    labels: $price_labels_json,
                    datasets: [{
                        label: 'Price',
                        data: $price_values_json,
                        borderColor: '#00d4aa',
                        backgroundColor: 'rgba(0, 212, 170, 0.1)',
                        fill: true,
                        tension: 0.4,
                        pointRadius: 0,
                        borderWidth: 2
                    }]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    interaction: { mode: 'index', intersect: false },
                    plugins: {
                        legend: { display: false },
                        title: { display: true, text: 'Price History', color: '#9aa0a6', font: { size: 12 } },
                        tooltip: { mode: 'index', intersect: false }
                    },
                    scales: {
                        x: {
                            display: true,
                            grid: { display: false },
                            ticks: {
                                color: '#6b7280',
                                maxTicksLimit: 6,
                                font: { size: 9 },
                                callback: function(value) {
                                    const label = this.getLabelForValue(value);
                                    if (label && label.length > 5) {
                                        const parts = label.split(' ');
                                        return parts.length > 1 ? parts[1] : label.slice(-5);
                                    }
                                    return label;
                                }
                            }
                        },
                        y: {
                            grid: { color: '#374151' },
                            ticks: { color: '#9aa0a6', callback: v => '\$' + v.toFixed(4) }
                        }
                    }
                }
            });

            // Spread Chart
            const spreadCtx_$exchange_lower = document.getElementById('spreadChart_$exchange_lower').getContext('2d');
            new Chart(spreadCtx_$exchange_lower, {
                type: 'line',
                data: {
                    labels: $price_labels_json,
                    datasets: [{
                        label: 'Spread %',
                        data: $spread_values_json,
                        borderColor: '#8b5cf6',
                        backgroundColor: 'rgba(139, 92, 246, 0.1)',
                        fill: true,
                        tension: 0.4,
                        pointRadius: 0,
                        borderWidth: 2
                    }, {
                        label: 'Warning (1%)',
                        data: Array($spread_values_json.length).fill(1),
                        borderColor: '#f59e0b',
                        borderDash: [5, 5],
                        borderWidth: 1,
                        pointRadius: 0,
                        fill: false
                    }]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    interaction: { mode: 'index', intersect: false },
                    plugins: {
                        legend: { display: false },
                        title: { display: true, text: 'Spread %', color: '#9aa0a6', font: { size: 12 } },
                        tooltip: { mode: 'index', intersect: false }
                    },
                    scales: {
                        x: {
                            display: true,
                            grid: { display: false },
                            ticks: {
                                color: '#6b7280',
                                maxTicksLimit: 6,
                                font: { size: 9 },
                                callback: function(value) {
                                    const label = this.getLabelForValue(value);
                                    if (label && label.length > 5) {
                                        const parts = label.split(' ');
                                        return parts.length > 1 ? parts[1] : label.slice(-5);
                                    }
                                    return label;
                                }
                            }
                        },
                        y: {
                            grid: { color: '#374151' },
                            ticks: { color: '#9aa0a6', callback: v => v.toFixed(2) + '%' },
                            min: 0
                        }
                    }
                }
            });
        })();
        </script>
        };
    }

    # Show message if no exchange data
    unless (@$prices) {
        print qq{
        <div class="card exchange-card">
            <div class="card-body">
                <div class="empty-state">
                    <div class="empty-state-icon">📊</div>
                    <p>No market data available yet. Run the monitor script to collect data:</p>
                    <p style="margin-top: 10px; font-family: monospace; background: var(--bg-tertiary); padding: 10px; border-radius: 6px;">perl monitor.pl</p>
                </div>
            </div>
        </div>
        };
    }

    # Recommendations Card
    print qq{
        <div class="card full-width">
            <div class="card-header">
                <div class="card-title">Trading Recommendations</div>
                <span class="card-badge">} . scalar(@$recommendations) . qq{ Active</span>
            </div>
            <div class="card-body">
    };

    if (@$recommendations) {
        print qq{<div class="recommendation-list">};
        foreach my $rec (@$recommendations) {
            my $priority_class = $rec->{priority} >= 8 ? 'priority-high' :
                                 $rec->{priority} >= 5 ? 'priority-medium' : 'priority-low';
            my $icon = $rec->{action} eq 'PULL_LIQUIDITY' ? '⚠️' :
                       $rec->{action} eq 'ADD_LIQUIDITY' ? '💰' :
                       $rec->{action} eq 'TIGHTEN_SPREAD' ? '📉' : '💡';

            print qq{
                <div class="recommendation-item $priority_class">
                    <div class="recommendation-icon">$icon</div>
                    <div>
                        <div class="recommendation-action">$rec->{action}</div>
                        <div class="recommendation-reason">$rec->{reason}</div>
                        <div class="recommendation-meta">
                            <span>Exchange: } . ($rec->{exchange} || 'All') . qq{</span>
                            <span>Priority: $rec->{priority}/10</span>
                        </div>
                    </div>
                </div>
            };
        }
        print qq{</div>};
    } else {
        print qq{<div class="empty-state"><div class="empty-state-icon">✅</div><p>No active recommendations. Market conditions are within normal parameters.</p></div>};
    }

    print qq{</div></div>};

    # Recent Alerts Card
    print qq{
        <div class="card half-width">
            <div class="card-header">
                <div class="card-title">Recent Alerts (24h)</div>
            </div>
            <div class="card-body">
                <div class="alert-list">
    };

    if (@$alerts) {
        foreach my $alert (@$alerts[0..9]) {
            last unless $alert;
            print qq{
                    <div class="alert-item">
                        <div class="alert-severity $alert->{severity}"></div>
                        <div>
                            <div class="alert-message">$alert->{message}</div>
                            <div class="alert-time">$alert->{created_at}</div>
                        </div>
                    </div>
            };
        }
    } else {
        print qq{<div class="empty-state"><p>No alerts in the last 24 hours</p></div>};
    }

    print qq{</div></div></div>};

    # Tips Card
    print qq{
        <div class="card half-width">
            <div class="card-header">
                <div class="card-title">Market Making Tips</div>
            </div>
            <div class="card-body">
                <div class="recommendation-list">
                    <div class="recommendation-item priority-low">
                        <div class="recommendation-icon">📈</div>
                        <div>
                            <div class="recommendation-action">Watch for Volume Spikes</div>
                            <div class="recommendation-reason">Large volume increases often precede price movements. Consider widening spreads during high volume.</div>
                        </div>
                    </div>
                    <div class="recommendation-item priority-low">
                        <div class="recommendation-icon">🔄</div>
                        <div>
                            <div class="recommendation-action">Cross-Exchange Monitoring</div>
                            <div class="recommendation-reason">Monitor price differences between KuCoin and MEXC. Consistent spreads >0.5% may indicate arbitrage opportunities.</div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    };

    print qq{</div>};
}

sub render_charts_tab {
    my ($dbh, $chart_data, $config) = @_;

    print qq{<div class="dashboard-grid">};

    foreach my $exchange ('MEXC', 'KUCOIN') {
        my $exchange_lower = lc($exchange);
        my $exchange_charts = $chart_data->{$exchange} || {};

        # Prepare data
        my $price_history = $exchange_charts->{price_history} || [];
        my @price_labels = map { $_->{time_bucket} } @$price_history;
        my @price_values = map { $_->{price} || 0 } @$price_history;
        my @spread_values = map { $_->{spread} || 0 } @$price_history;

        my $depth_history = $exchange_charts->{depth_history} || [];
        my %depth_by_time;
        foreach my $d (@$depth_history) {
            my $time = $d->{time_bucket};
            my $level = $d->{depth_level};
            $depth_by_time{$time}{$level}{bid} = $d->{bid_depth} || 0;
            $depth_by_time{$time}{$level}{ask} = $d->{ask_depth} || 0;
        }
        my @depth_times = sort keys %depth_by_time;
        my @bid_2pct = map { $depth_by_time{$_}{'2%'}{bid} || 0 } @depth_times;
        my @bid_5pct = map { $depth_by_time{$_}{'5%'}{bid} || 0 } @depth_times;
        my @bid_10pct = map { $depth_by_time{$_}{'10%'}{bid} || 0 } @depth_times;
        my @ask_2pct = map { $depth_by_time{$_}{'2%'}{ask} || 0 } @depth_times;
        my @ask_5pct = map { $depth_by_time{$_}{'5%'}{ask} || 0 } @depth_times;
        my @ask_10pct = map { $depth_by_time{$_}{'10%'}{ask} || 0 } @depth_times;

        my $trade_history = $exchange_charts->{trade_history} || [];
        my @trade_labels = map { $_->{time_bucket} } @$trade_history;
        my @trade_counts = map { $_->{trade_count} || 0 } @$trade_history;
        my @buy_volumes = map { $_->{buy_volume} || 0 } @$trade_history;
        my @sell_volumes = map { $_->{sell_volume} || 0 } @$trade_history;

        my $price_labels_json = encode_json(\@price_labels);
        my $price_values_json = encode_json(\@price_values);
        my $spread_values_json = encode_json(\@spread_values);
        my $depth_labels_json = encode_json(\@depth_times);
        my $bid_2pct_json = encode_json(\@bid_2pct);
        my $bid_5pct_json = encode_json(\@bid_5pct);
        my $bid_10pct_json = encode_json(\@bid_10pct);
        my $ask_2pct_json = encode_json(\@ask_2pct);
        my $ask_5pct_json = encode_json(\@ask_5pct);
        my $ask_10pct_json = encode_json(\@ask_10pct);
        my $trade_labels_json = encode_json(\@trade_labels);
        my $trade_counts_json = encode_json(\@trade_counts);
        my $buy_volumes_json = encode_json(\@buy_volumes);
        my $sell_volumes_json = encode_json(\@sell_volumes);

        print qq{
        <div class="card full-width">
            <div class="card-header">
                <div class="card-title">$exchange - ERG/USDT Charts (48h)</div>
            </div>
            <div class="card-body">
                <div class="dashboard-grid" style="gap: 16px;">
                    <!-- Price History -->
                    <div class="half-width">
                        <div class="chart-container tall">
                            <canvas id="priceChartFull_$exchange_lower"></canvas>
                        </div>
                    </div>

                    <!-- Spread History -->
                    <div class="half-width">
                        <div class="chart-container tall">
                            <canvas id="spreadChartFull_$exchange_lower"></canvas>
                        </div>
                    </div>

                    <!-- Bid Depth History -->
                    <div class="half-width">
                        <div class="chart-container tall">
                            <canvas id="bidDepthChart_$exchange_lower"></canvas>
                        </div>
                    </div>

                    <!-- Ask Depth History -->
                    <div class="half-width">
                        <div class="chart-container tall">
                            <canvas id="askDepthChart_$exchange_lower"></canvas>
                        </div>
                    </div>

                    <!-- Trade Volume -->
                    <div class="half-width">
                        <div class="chart-container tall">
                            <canvas id="volumeChart_$exchange_lower"></canvas>
                        </div>
                    </div>

                    <!-- Trade Count -->
                    <div class="half-width">
                        <div class="chart-container tall">
                            <canvas id="tradeCountChart_$exchange_lower"></canvas>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <script>
        (function() {
            const chartOptions = {
                responsive: true,
                maintainAspectRatio: false,
                interaction: {
                    mode: 'index',
                    intersect: false
                },
                plugins: {
                    legend: { labels: { color: '#9aa0a6', boxWidth: 12, font: { size: 11 } } },
                    tooltip: {
                        enabled: true,
                        mode: 'index',
                        intersect: false,
                        backgroundColor: 'rgba(30, 34, 42, 0.95)',
                        titleColor: '#e8eaed',
                        bodyColor: '#9aa0a6',
                        borderColor: '#374151',
                        borderWidth: 1,
                        padding: 10,
                        displayColors: true
                    }
                },
                scales: {
                    x: {
                        grid: { color: '#374151' },
                        ticks: {
                            color: '#9aa0a6',
                            maxRotation: 45,
                            maxTicksLimit: 8,
                            callback: function(value, index, values) {
                                // Extract just HH:MM from the label
                                const label = this.getLabelForValue(value);
                                if (label && label.length > 5) {
                                    const parts = label.split(' ');
                                    return parts.length > 1 ? parts[1] : label.slice(-5);
                                }
                                return label;
                            }
                        }
                    },
                    y: { grid: { color: '#374151' }, ticks: { color: '#9aa0a6' } }
                }
            };

            // Price Chart
            new Chart(document.getElementById('priceChartFull_$exchange_lower'), {
                type: 'line',
                data: {
                    labels: $price_labels_json,
                    datasets: [{
                        label: 'Price (\$)',
                        data: $price_values_json,
                        borderColor: '#00d4aa',
                        backgroundColor: 'rgba(0, 212, 170, 0.1)',
                        fill: true,
                        tension: 0.3,
                        pointRadius: 0,
                        borderWidth: 2
                    }]
                },
                options: {
                    ...chartOptions,
                    plugins: { ...chartOptions.plugins, title: { display: true, text: 'Price History', color: '#e8eaed' } },
                    scales: { ...chartOptions.scales, y: { ...chartOptions.scales.y, ticks: { ...chartOptions.scales.y.ticks, callback: v => '\$' + v.toFixed(4) } } }
                }
            });

            // Spread Chart
            new Chart(document.getElementById('spreadChartFull_$exchange_lower'), {
                type: 'line',
                data: {
                    labels: $price_labels_json,
                    datasets: [{
                        label: 'Spread %',
                        data: $spread_values_json,
                        borderColor: '#8b5cf6',
                        backgroundColor: 'rgba(139, 92, 246, 0.1)',
                        fill: true,
                        tension: 0.3,
                        pointRadius: 0,
                        borderWidth: 2
                    }, {
                        label: 'Warning (1%)',
                        data: Array($spread_values_json.length).fill(1),
                        borderColor: '#f59e0b',
                        borderDash: [5, 5],
                        borderWidth: 1,
                        pointRadius: 0
                    }]
                },
                options: {
                    ...chartOptions,
                    plugins: { ...chartOptions.plugins, title: { display: true, text: 'Spread History', color: '#e8eaed' } },
                    scales: { ...chartOptions.scales, y: { ...chartOptions.scales.y, min: 0, ticks: { ...chartOptions.scales.y.ticks, callback: v => v.toFixed(2) + '%' } } }
                }
            });

            // Bid Depth Chart
            new Chart(document.getElementById('bidDepthChart_$exchange_lower'), {
                type: 'line',
                data: {
                    labels: $depth_labels_json,
                    datasets: [
                        { label: '2% Depth', data: $bid_2pct_json, borderColor: '#22c55e', backgroundColor: 'rgba(34, 197, 94, 0.1)', fill: true, tension: 0.3, pointRadius: 0 },
                        { label: '5% Depth', data: $bid_5pct_json, borderColor: '#3b82f6', backgroundColor: 'rgba(59, 130, 246, 0.1)', fill: true, tension: 0.3, pointRadius: 0 },
                        { label: '10% Depth', data: $bid_10pct_json, borderColor: '#8b5cf6', backgroundColor: 'rgba(139, 92, 246, 0.1)', fill: true, tension: 0.3, pointRadius: 0 }
                    ]
                },
                options: {
                    ...chartOptions,
                    plugins: { ...chartOptions.plugins, title: { display: true, text: 'Bid Orderbook Depth', color: '#e8eaed' } },
                    scales: { ...chartOptions.scales, y: { ...chartOptions.scales.y, ticks: { ...chartOptions.scales.y.ticks, callback: v => '\$' + (v/1000).toFixed(1) + 'k' } } }
                }
            });

            // Ask Depth Chart
            new Chart(document.getElementById('askDepthChart_$exchange_lower'), {
                type: 'line',
                data: {
                    labels: $depth_labels_json,
                    datasets: [
                        { label: '2% Depth', data: $ask_2pct_json, borderColor: '#ef4444', backgroundColor: 'rgba(239, 68, 68, 0.1)', fill: true, tension: 0.3, pointRadius: 0 },
                        { label: '5% Depth', data: $ask_5pct_json, borderColor: '#f59e0b', backgroundColor: 'rgba(245, 158, 11, 0.1)', fill: true, tension: 0.3, pointRadius: 0 },
                        { label: '10% Depth', data: $ask_10pct_json, borderColor: '#ec4899', backgroundColor: 'rgba(236, 72, 153, 0.1)', fill: true, tension: 0.3, pointRadius: 0 }
                    ]
                },
                options: {
                    ...chartOptions,
                    plugins: { ...chartOptions.plugins, title: { display: true, text: 'Ask Orderbook Depth', color: '#e8eaed' } },
                    scales: { ...chartOptions.scales, y: { ...chartOptions.scales.y, ticks: { ...chartOptions.scales.y.ticks, callback: v => '\$' + (v/1000).toFixed(1) + 'k' } } }
                }
            });

            // Volume Chart
            new Chart(document.getElementById('volumeChart_$exchange_lower'), {
                type: 'bar',
                data: {
                    labels: $trade_labels_json,
                    datasets: [
                        { label: 'Buy Volume', data: $buy_volumes_json, backgroundColor: 'rgba(34, 197, 94, 0.7)' },
                        { label: 'Sell Volume', data: $sell_volumes_json, backgroundColor: 'rgba(239, 68, 68, 0.7)' }
                    ]
                },
                options: {
                    ...chartOptions,
                    plugins: { ...chartOptions.plugins, title: { display: true, text: 'Trade Volume (Hourly)', color: '#e8eaed' } },
                    scales: { ...chartOptions.scales, x: { ...chartOptions.scales.x, stacked: true }, y: { ...chartOptions.scales.y, stacked: true, ticks: { ...chartOptions.scales.y.ticks, callback: v => '\$' + v.toFixed(0) } } }
                }
            });

            // Trade Count Chart
            new Chart(document.getElementById('tradeCountChart_$exchange_lower'), {
                type: 'bar',
                data: {
                    labels: $trade_labels_json,
                    datasets: [{
                        label: 'Trade Count',
                        data: $trade_counts_json,
                        backgroundColor: 'rgba(0, 212, 170, 0.7)'
                    }]
                },
                options: {
                    ...chartOptions,
                    plugins: { ...chartOptions.plugins, title: { display: true, text: 'Filled Trades (Hourly)', color: '#e8eaed' } }
                }
            });
        })();
        </script>
        };
    }

    print qq{</div>};
}

sub render_alerts_tab {
    my ($alerts) = @_;

    print qq{
        <div class="dashboard-grid">
            <div class="card full-width">
                <div class="card-header">
                    <div class="card-title">Alert History (Last 24 Hours)</div>
                </div>
                <div class="card-body">
    };

    if (@$alerts) {
        print qq{<div class="alert-list" style="max-height: none;">};
        foreach my $alert (@$alerts) {
            print qq{
                    <div class="alert-item">
                        <div class="alert-severity $alert->{severity}"></div>
                        <div>
                            <div class="alert-message"><strong>[$alert->{alert_type}]</strong> $alert->{message}</div>
                            <div class="alert-time">
                                $alert->{created_at} |
                                Exchange: } . ($alert->{exchange} || 'All') . qq{ |
                                Discord: } . ($alert->{discord_sent} ? 'Sent' : 'Not Sent') . qq{
                            </div>
                        </div>
                    </div>
            };
        }
        print qq{</div>};
    } else {
        print qq{<div class="empty-state"><div class="empty-state-icon">🔔</div><p>No alerts recorded in the last 24 hours.</p></div>};
    }

    print qq{</div></div></div>};
}

sub render_settings_tab {
    my ($config, $saved) = @_;

    my $saved_msg = '';
    if ($saved) {
        $saved_msg = '<div style="background: rgba(34,197,94,0.2); border: 1px solid #22c55e; color: #22c55e; padding: 12px 16px; border-radius: 8px; margin-bottom: 20px;">Settings saved successfully!</div>';
    }

    print qq{
        <div class="dashboard-grid">
            <div class="card full-width">
                <div class="card-header">
                    <div class="card-title">Dashboard Settings</div>
                </div>
                <div class="card-body">
                    $saved_msg
                    <form method="POST">
                        <input type="hidden" name="action" value="save">
                        <input type="hidden" name="tab" value="settings">
                        <div class="settings-grid">
                            <div class="setting-group">
                                <h3>Discord Notifications</h3>
                                <div class="setting-item">
                                    <label class="setting-label">Discord Webhook URL</label>
                                    <input type="text" name="discord_webhook" class="setting-input"
                                           value="} . ($config->{discord_webhook}{value} || '') . qq{"
                                           placeholder="https://discord.com/api/webhooks/...">
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">Alert Cooldown (minutes)</label>
                                    <input type="number" name="alert_cooldown_minutes" class="setting-input"
                                           value="} . ($config->{alert_cooldown_minutes}{value} || '30') . qq{">
                                </div>
                            </div>

                            <div class="setting-group">
                                <h3>Spread Thresholds</h3>
                                <div class="setting-item">
                                    <label class="setting-label">Warning Threshold (%)</label>
                                    <input type="number" step="0.1" name="spread_warning_threshold" class="setting-input"
                                           value="} . ($config->{spread_warning_threshold}{value} || '1.5') . qq{">
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">Critical Threshold (%)</label>
                                    <input type="number" step="0.1" name="spread_critical_threshold" class="setting-input"
                                           value="} . ($config->{spread_critical_threshold}{value} || '3.0') . qq{">
                                </div>
                            </div>

                            <div class="setting-group">
                                <h3>Depth Thresholds</h3>
                                <div class="setting-item">
                                    <label class="setting-label">Warning Threshold (USD)</label>
                                    <input type="number" name="depth_warning_threshold" class="setting-input"
                                           value="} . ($config->{depth_warning_threshold}{value} || '5000') . qq{">
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">Critical Threshold (USD)</label>
                                    <input type="number" name="depth_critical_threshold" class="setting-input"
                                           value="} . ($config->{depth_critical_threshold}{value} || '2000') . qq{">
                                </div>
                            </div>

                            <div class="setting-group">
                                <h3>Exchange Monitoring</h3>
                                <div class="setting-item">
                                    <label class="setting-label">Monitor KuCoin</label>
                                    <select name="kucoin_enabled" class="setting-input">
                                        <option value="1" } . (($config->{kucoin_enabled}{value} || '') eq '1' ? 'selected' : '') . qq{>Enabled</option>
                                        <option value="0" } . (($config->{kucoin_enabled}{value} || '') eq '0' ? 'selected' : '') . qq{>Disabled</option>
                                    </select>
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">Monitor MEXC</label>
                                    <select name="mexc_enabled" class="setting-input">
                                        <option value="1" } . (($config->{mexc_enabled}{value} || '') eq '1' ? 'selected' : '') . qq{>Enabled</option>
                                        <option value="0" } . (($config->{mexc_enabled}{value} || '') eq '0' ? 'selected' : '') . qq{>Disabled</option>
                                    </select>
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">Monitoring Enabled</label>
                                    <select name="monitoring_enabled" class="setting-input">
                                        <option value="1" } . (($config->{monitoring_enabled}{value} || '') eq '1' ? 'selected' : '') . qq{>Enabled</option>
                                        <option value="0" } . (($config->{monitoring_enabled}{value} || '') eq '0' ? 'selected' : '') . qq{>Disabled</option>
                                    </select>
                                </div>
                            </div>

                            <div class="setting-group">
                                <h3>Volatility Thresholds</h3>
                                <div class="setting-item">
                                    <label class="setting-label">Price Change Warning (%)</label>
                                    <input type="number" step="0.1" name="price_change_warning" class="setting-input"
                                           value="} . ($config->{price_change_warning}{value} || '5.0') . qq{">
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">Liquidity Pull Threshold (%)</label>
                                    <input type="number" step="0.1" name="liquidity_pull_threshold" class="setting-input"
                                           value="} . ($config->{liquidity_pull_threshold}{value} || '15.0') . qq{">
                                </div>
                            </div>

                            <div class="setting-group">
                                <h3>Volume Alerts</h3>
                                <div class="setting-item">
                                    <label class="setting-label">Volume Spike Multiplier</label>
                                    <input type="number" step="0.1" name="volume_spike_threshold" class="setting-input"
                                           value="} . ($config->{volume_spike_threshold}{value} || '3.0') . qq{">
                                    <div class="setting-description">Volume vs 24h average to flag as spike</div>
                                </div>
                            </div>
                        </div>

                        <div style="margin-top: 24px; display: flex; gap: 12px;">
                            <button type="submit" class="btn btn-primary">Save Settings</button>
                            <a href="?tab=overview" class="btn btn-secondary">Cancel</a>
                        </div>
                    </form>
                </div>
            </div>
        </div>
    };
}

sub format_number {
    my ($num) = @_;
    return '0' unless defined $num;

    if ($num >= 1000000) {
        return sprintf("%.2fM", $num / 1000000);
    } elsif ($num >= 1000) {
        return sprintf("%.1fK", $num / 1000);
    } else {
        return sprintf("%.2f", $num);
    }
}

# ============================================================
# MAIN CGI HANDLER
# ============================================================
sub main {
    my $q = CGI->new();
    my $dbh = get_db_connection();

    my %cookies = CGI::Cookie->fetch();
    my $session_id = $cookies{'ergo_mm_session'} ? $cookies{'ergo_mm_session'}->value() : undef;

    if ($q->param('logout')) {
        destroy_session($dbh, $session_id) if $session_id;
        my $cookie = CGI::Cookie->new(-name => 'ergo_mm_session', -value => '', -expires => '-1d');
        print $q->redirect(-uri => $q->url(), -cookie => $cookie);
        return;
    }

    if ($q->request_method() eq 'POST' && !validate_session($dbh, $session_id)) {
        my $password = $q->param('password') || '';

        if ($password eq $DASHBOARD_PASSWORD) {
            $session_id = create_session($dbh, $ENV{REMOTE_ADDR} || '0.0.0.0');
            my $cookie = CGI::Cookie->new(-name => 'ergo_mm_session', -value => $session_id, -expires => '+24h', -httponly => 1);
            print $q->redirect(-uri => $q->url(), -cookie => $cookie);
            return;
        } else {
            render_login_page('Invalid password. Please try again.');
            return;
        }
    }

    unless (validate_session($dbh, $session_id)) {
        render_login_page();
        return;
    }

    if (($q->param('action') || '') eq 'save' && $q->request_method() eq 'POST') {
        my @settings = qw(
            discord_webhook alert_cooldown_minutes
            spread_warning_threshold spread_critical_threshold
            depth_warning_threshold depth_critical_threshold
            price_change_warning price_change_critical liquidity_pull_threshold
            volume_spike_threshold
            kucoin_enabled mexc_enabled monitoring_enabled
        );

        foreach my $setting (@settings) {
            my $value = $q->param($setting);
            if (defined $value) {
                update_config($dbh, $setting, $value);
            }
        }

        print $q->redirect(-uri => $q->url() . '?tab=settings&saved=1');
        return;
    }

    my $tab = $q->param('tab') || 'overview';
    my $saved = $q->param('saved') || 0;
    render_dashboard($dbh, $tab, $saved);

    $dbh->disconnect();
}

main();

1;

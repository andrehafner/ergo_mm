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
            DATE_FORMAT(trade_time, '%Y-%m-%d %H:00') as time_bucket,
            COUNT(*) as trade_count,
            SUM(amount_usd) as total_volume,
            SUM(CASE WHEN side = 'buy' THEN amount_usd ELSE 0 END) as buy_volume,
            SUM(CASE WHEN side = 'sell' THEN amount_usd ELSE 0 END) as sell_volume,
            AVG(price) as avg_price
        FROM trades
        WHERE exchange = ?
          AND trade_time > DATE_SUB(NOW(), INTERVAL ? HOUR)
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
          AND trade_time > DATE_SUB(NOW(), INTERVAL ? HOUR)
    });
    $sth->execute($exchange, $hours);
    my $row = $sth->fetchrow_hashref();
    $sth->finish();
    return $row;
}

sub get_data_freshness {
    my ($dbh) = @_;
    my $sth = $dbh->prepare("SELECT MAX(timestamp), TIMESTAMPDIFF(SECOND, MAX(timestamp), NOW()) FROM price_data");
    $sth->execute();
    my ($last_update, $age) = $sth->fetchrow_array();
    $sth->finish();
    return { last_update => $last_update, age_seconds => $age };
}

# ------------------------------------------------------------
# On-chain exchange flows (tables from sql/add_flow_tables.sql)
# ------------------------------------------------------------
sub parse_address_list {
    my ($text) = @_;
    return () unless defined $text;
    my %seen;
    my @addresses;
    foreach my $candidate (split /[\s,;]+/, $text) {
        next unless length $candidate;
        next unless $candidate =~ /^[1-9A-HJ-NP-Za-km-z]{20,120}$/;   # base58 only
        push @addresses, $candidate unless $seen{$candidate}++;
    }
    return @addresses;
}

sub get_flow_summary {
    my ($dbh) = @_;
    my $sth = $dbh->prepare(qq{
        SELECT
            exchange,
            SUM(CASE WHEN direction = 'in'  AND tx_time > DATE_SUB(NOW(), INTERVAL 1 HOUR) THEN amount_erg ELSE 0 END) AS in_1h,
            SUM(CASE WHEN direction = 'out' AND tx_time > DATE_SUB(NOW(), INTERVAL 1 HOUR) THEN amount_erg ELSE 0 END) AS out_1h,
            SUM(CASE WHEN direction = 'in'  AND tx_time > DATE_SUB(NOW(), INTERVAL 6 HOUR) THEN amount_erg ELSE 0 END) AS in_6h,
            SUM(CASE WHEN direction = 'out' AND tx_time > DATE_SUB(NOW(), INTERVAL 6 HOUR) THEN amount_erg ELSE 0 END) AS out_6h,
            SUM(CASE WHEN direction = 'in'  THEN amount_erg ELSE 0 END) AS in_24h,
            SUM(CASE WHEN direction = 'out' THEN amount_erg ELSE 0 END) AS out_24h,
            COUNT(*) AS tx_24h,
            MAX(tx_time) AS last_tx
        FROM exchange_flows
        WHERE tx_time > DATE_SUB(NOW(), INTERVAL 24 HOUR)
        GROUP BY exchange
    });
    $sth->execute();
    my %results;
    while (my $row = $sth->fetchrow_hashref()) {
        $results{$row->{exchange}} = $row;
    }
    $sth->finish();
    return \%results;
}

sub get_flow_last_activity {
    my ($dbh) = @_;
    # Newest recorded on-chain transfer per exchange, any age - tells a dormant wallet from a quiet day
    my $sth = $dbh->prepare(qq{
        SELECT exchange, MAX(tx_time) AS last_tx, TIMESTAMPDIFF(DAY, MAX(tx_time), NOW()) AS days_ago
        FROM exchange_flows
        GROUP BY exchange
    });
    $sth->execute();
    my %results;
    while (my $row = $sth->fetchrow_hashref()) {
        $results{$row->{exchange}} = $row;
    }
    $sth->finish();
    return \%results;
}

sub get_flow_reserves {
    my ($dbh) = @_;
    my $sth = $dbh->prepare(qq{
        SELECT r.exchange, r.address, r.balance_erg, r.timestamp
        FROM exchange_reserves r
        INNER JOIN (
            SELECT exchange, address, MAX(timestamp) AS max_time
            FROM exchange_reserves
            WHERE timestamp > DATE_SUB(NOW(), INTERVAL 1 DAY)
            GROUP BY exchange, address
        ) x ON r.exchange = x.exchange AND r.address = x.address AND r.timestamp = x.max_time
        ORDER BY r.exchange, r.balance_erg DESC
    });
    $sth->execute();
    my %results;
    while (my $row = $sth->fetchrow_hashref()) {
        my $ex = $results{$row->{exchange}} ||= { total_erg => 0, addresses => [], updated => undef };
        $ex->{total_erg} += $row->{balance_erg};
        push @{$ex->{addresses}}, $row;
        $ex->{updated} = $row->{timestamp} if !defined $ex->{updated} || $row->{timestamp} gt $ex->{updated};
    }
    $sth->finish();
    return \%results;
}

sub get_recent_flows {
    my ($dbh, $limit, $hours) = @_;
    $limit ||= 100;
    $hours ||= 48;
    my $sth = $dbh->prepare(qq{
        SELECT exchange, tx_id, direction, amount_erg, amount_usd, counterparty, block_height, tx_time
        FROM exchange_flows
        WHERE tx_time > DATE_SUB(NOW(), INTERVAL ? HOUR)
        ORDER BY tx_time DESC
        LIMIT ?
    });
    $sth->execute($hours, $limit);
    my @results;
    while (my $row = $sth->fetchrow_hashref()) {
        push @results, $row;
    }
    $sth->finish();
    return \@results;
}

sub get_flow_history {
    my ($dbh, $hours) = @_;
    $hours ||= 48;
    my $sth = $dbh->prepare(qq{
        SELECT
            exchange,
            DATE_FORMAT(tx_time, '%Y-%m-%d %H:00') AS time_bucket,
            SUM(CASE WHEN direction = 'in'  THEN amount_erg ELSE 0 END) AS in_erg,
            SUM(CASE WHEN direction = 'out' THEN amount_erg ELSE 0 END) AS out_erg
        FROM exchange_flows
        WHERE tx_time > DATE_SUB(NOW(), INTERVAL ? HOUR)
        GROUP BY exchange, time_bucket
        ORDER BY time_bucket
    });
    $sth->execute($hours);
    my @results;
    while (my $row = $sth->fetchrow_hashref()) {
        push @results, $row;
    }
    $sth->finish();
    return \@results;
}

sub get_reserve_history {
    my ($dbh, $hours) = @_;
    $hours ||= 48;
    # Average each address within a 30-minute bucket, then sum the addresses per exchange
    my $sth = $dbh->prepare(qq{
        SELECT exchange, time_bucket, SUM(avg_balance) AS balance_erg
        FROM (
            SELECT
                exchange,
                address,
                CONCAT(DATE_FORMAT(timestamp, '%Y-%m-%d %H:'), LPAD(FLOOR(MINUTE(timestamp) / 30) * 30, 2, '0')) AS time_bucket,
                AVG(balance_erg) AS avg_balance
            FROM exchange_reserves
            WHERE timestamp > DATE_SUB(NOW(), INTERVAL ? HOUR)
            GROUP BY exchange, address, time_bucket
        ) per_address
        GROUP BY exchange, time_bucket
        ORDER BY time_bucket
    });
    $sth->execute($hours);
    my @results;
    while (my $row = $sth->fetchrow_hashref()) {
        push @results, $row;
    }
    $sth->finish();
    return \@results;
}

sub get_wallet_hints {
    my ($dbh) = @_;
    # Addresses that sent your own withdrawals = the exchange's hot wallet(s)
    my $sth = $dbh->prepare(qq{
        SELECT exchange, address, COUNT(DISTINCT tx_id) AS withdrawals, MAX(checked_at) AS last_seen
        FROM exchange_wallet_hints
        WHERE address IS NOT NULL
        GROUP BY exchange, address
        ORDER BY withdrawals DESC, last_seen DESC
    });
    $sth->execute();
    my %results;
    while (my $row = $sth->fetchrow_hashref()) {
        next unless $row->{address} =~ /^[1-9A-HJ-NP-Za-km-z]{20,120}$/;   # only ever print base58
        push @{$results{$row->{exchange}}}, $row;
    }
    $sth->finish();
    return \%results;
}

sub get_user_transfer_summary {
    my ($dbh) = @_;
    # Deposits/withdrawals of the MM account per exchange and asset over 1d / 7d / 30d.
    # Failed, cancelled and rejected transfers never moved funds, so they are excluded.
    my $sth = $dbh->prepare(qq{
        SELECT
            exchange,
            currency,
            SUM(CASE WHEN direction = 'deposit'    AND tx_time > DATE_SUB(NOW(), INTERVAL 1 DAY)  THEN amount ELSE 0 END) AS in_1d,
            SUM(CASE WHEN direction = 'withdrawal' AND tx_time > DATE_SUB(NOW(), INTERVAL 1 DAY)  THEN amount ELSE 0 END) AS out_1d,
            SUM(CASE WHEN direction = 'deposit'    AND tx_time > DATE_SUB(NOW(), INTERVAL 7 DAY)  THEN amount ELSE 0 END) AS in_7d,
            SUM(CASE WHEN direction = 'withdrawal' AND tx_time > DATE_SUB(NOW(), INTERVAL 7 DAY)  THEN amount ELSE 0 END) AS out_7d,
            SUM(CASE WHEN direction = 'deposit'    THEN amount ELSE 0 END) AS in_30d,
            SUM(CASE WHEN direction = 'withdrawal' THEN amount ELSE 0 END) AS out_30d,
            COUNT(*) AS tx_30d,
            MAX(tx_time) AS last_tx
        FROM user_transfers
        WHERE tx_time > DATE_SUB(NOW(), INTERVAL 30 DAY)
          AND (status IS NULL OR status NOT REGEXP 'FAIL|CANCEL|REJECT')
        GROUP BY exchange, currency
    });
    $sth->execute();
    my %results;
    while (my $row = $sth->fetchrow_hashref()) {
        $results{$row->{exchange}}{$row->{currency}} = $row;
    }
    $sth->finish();
    return \%results;
}

sub get_user_transfers {
    my ($dbh, $limit) = @_;
    $limit ||= 50;
    my $sth = $dbh->prepare(qq{
        SELECT exchange, currency, direction, amount, fee, status, network, address, tx_id, tx_time
        FROM user_transfers
        ORDER BY tx_time DESC
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

        /* Live / stale data indicator + auto-refresh countdown */
        .status-indicator.stale { background: rgba(239, 68, 68, 0.15); color: var(--accent-red); border: 1px solid rgba(239, 68, 68, 0.4); }
        .status-indicator.stale .status-dot { background: var(--accent-red); }
        .refresh-timer { font-size: 12px; color: var(--text-muted); cursor: pointer; user-select: none; white-space: nowrap; }
        .refresh-timer:hover { color: var(--text-secondary); }
        .refresh-timer.paused { color: var(--accent-orange); }

        /* Cross-exchange strip */
        .xchg-strip { grid-column: span 12; display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; }
        .xchg-box { background: var(--bg-card); border: 1px solid var(--border-color); border-radius: 10px; padding: 12px 16px; }
        .xchg-label { font-size: 11px; color: var(--text-secondary); text-transform: uppercase; letter-spacing: .5px; }
        .xchg-value { font-size: 18px; font-weight: 600; margin-top: 4px; }
        .xchg-value.positive { color: var(--accent-green); }
        .xchg-value.warning { color: var(--accent-orange); }
        .xchg-value.negative { color: var(--accent-red); }
        .xchg-sub { font-size: 11px; color: var(--text-muted); margin-top: 2px; }

        /* On-chain flow tables */
        .flow-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 16px; }
        .flow-exchange { background: var(--bg-tertiary); border-radius: 10px; padding: 14px; }
        .flow-exchange-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; gap: 12px; }
        .flow-reserve { font-size: 12px; color: var(--text-secondary); text-align: right; line-height: 1.3; }
        .flow-reserve strong { color: var(--text-primary); font-size: 15px; }
        .flow-table { width: 100%; border-collapse: collapse; font-size: 13px; }
        .flow-table th, .flow-table td { padding: 8px 10px; text-align: right; border-bottom: 1px solid var(--border-color); white-space: nowrap; }
        .flow-table th { font-size: 11px; font-weight: 600; color: var(--text-secondary); text-transform: uppercase; }
        .flow-table th:first-child, .flow-table td:first-child { text-align: left; }
        .flow-table tr:last-child td { border-bottom: none; }
        .flow-table.wide td { white-space: normal; }
        .flow-in { color: var(--accent-orange); }       /* ERG arriving on the exchange = potential sell pressure */
        .flow-out { color: var(--accent-cyan); }        /* ERG leaving the exchange = supply off the book */
        .flow-net-pos { color: var(--accent-orange); font-weight: 600; }
        .flow-net-neg { color: var(--accent-cyan); font-weight: 600; }
        .flow-badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: 600; text-transform: uppercase; }
        .flow-badge.in { background: rgba(245, 158, 11, 0.15); color: var(--accent-orange); }
        .flow-badge.out { background: rgba(0, 212, 170, 0.15); color: var(--accent-cyan); }
        .flow-badge.deposit { background: rgba(34, 197, 94, 0.15); color: var(--accent-green); }
        .flow-badge.withdrawal { background: rgba(139, 92, 246, 0.15); color: var(--accent-purple); }
        .flow-note { font-size: 12px; color: var(--text-muted); margin-top: 10px; line-height: 1.5; }
        .acct-in { color: var(--accent-green); }        /* funds you moved onto the exchange */
        .acct-out { color: var(--accent-purple); }      /* funds you took off the exchange */
        .acct-net-pos { color: var(--accent-green); font-weight: 600; }
        .acct-net-neg { color: var(--accent-purple); font-weight: 600; }
        .asset-tag { font-weight: 600; letter-spacing: .3px; }
        .flow-table td.asset-cell { border-bottom: none; vertical-align: top; }
        .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 12px; }
        .tx-link { color: var(--accent-blue); text-decoration: none; }
        .tx-link:hover { text-decoration: underline; }
        .addr-list { list-style: none; margin-top: 10px; font-size: 11px; color: var(--text-muted); border-top: 1px solid var(--border-color); padding-top: 8px; }
        .addr-list li { display: flex; justify-content: space-between; gap: 8px; padding: 2px 0; }
        .setup-hint { background: rgba(59, 130, 246, 0.08); border: 1px dashed rgba(59, 130, 246, 0.4); border-radius: 8px; padding: 12px 14px; font-size: 13px; color: var(--text-secondary); line-height: 1.5; }
        .setup-hint a { color: var(--accent-cyan); }
        .setup-hint code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; background: var(--bg-secondary); padding: 1px 6px; border-radius: 4px; }
        .table-scroll { overflow-x: auto; }
        .inventory-bar { height: 8px; border-radius: 4px; background: var(--accent-blue); overflow: hidden; margin-top: 6px; display: flex; }
        .inventory-bar span { display: block; height: 100%; background: var(--accent-cyan); }
        textarea.setting-input { min-height: 76px; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 12px; resize: vertical; }

        \@media (max-width: 900px) {
            .flow-grid, .xchg-strip { grid-template-columns: 1fr; }
        }
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
    my $freshness = get_data_freshness($dbh);

    # Get chart data for each exchange (6h window for fast loading) - only the tabs that draw them
    my %chart_data;
    if ($tab eq 'overview' || $tab eq 'charts') {
        foreach my $exchange ('MEXC', 'KUCOIN') {
            $chart_data{$exchange} = {
                price_history => get_price_history($dbh, $exchange, 6),
                depth_history => get_depth_history($dbh, $exchange, 6),
                trade_history => get_trade_history($dbh, $exchange, 6),
                trade_summary => get_trade_summary($dbh, $exchange, 6),
            };
        }
    }

    # Live / stale badge: the monitor is expected every minute; 5 minutes without data is a problem
    my $age = $freshness->{age_seconds};
    my ($status_class, $status_text);
    if (!defined $age) {
        ($status_class, $status_text) = ('stale', 'No data yet');
    } elsif ($age > 300) {
        ($status_class, $status_text) = ('stale', 'STALE - last data ' . format_age($age) . ' ago');
    } else {
        ($status_class, $status_text) = ('', 'Live - updated ' . format_age($age) . ' ago');
    }
    my $auto_refresh = $tab eq 'settings' ? 0 : 60;   # never reload under someone editing settings

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
                <div class="status-indicator $status_class" title="Newest price sample: } . ($freshness->{last_update} || 'none') . qq{">
                    <span class="status-dot online"></span>
                    <span>$status_text</span>
                </div>
                } . ($auto_refresh ? qq{<span id="refresh-timer" class="refresh-timer" title="Click to pause/resume auto-refresh">Refresh in ${auto_refresh}s</span>} : '') . qq{
                <a href="?tab=settings" class="btn btn-secondary">Settings</a>
                <a href="?logout=1" class="btn btn-secondary">Logout</a>
            </div>
        </div>

        <div class="tabs">
            <a href="?tab=overview" class="tab } . ($tab eq 'overview' ? 'active' : '') . qq{">Overview</a>
            <a href="?tab=flows" class="tab } . ($tab eq 'flows' ? 'active' : '') . qq{">Flows</a>
            <a href="?tab=charts" class="tab } . ($tab eq 'charts' ? 'active' : '') . qq{">Charts</a>
            <a href="?tab=alerts" class="tab } . ($tab eq 'alerts' ? 'active' : '') . qq{">Alerts</a>
            <a href="?tab=settings" class="tab } . ($tab eq 'settings' ? 'active' : '') . qq{">Settings</a>
        </div>
    };

    if ($tab eq 'overview') {
        render_overview_tab($dbh, $prices, $depth, $metrics, $recommendations, $alerts, \%chart_data, $config);
    } elsif ($tab eq 'flows') {
        render_flows_tab($dbh, $config);
    } elsif ($tab eq 'charts') {
        render_charts_tab($dbh, \%chart_data, $config);
    } elsif ($tab eq 'alerts') {
        render_alerts_tab($alerts);
    } elsif ($tab eq 'settings') {
        render_settings_tab($config, $saved, $dbh);
    }

    print qq{</div>};

    if ($auto_refresh) {
        print qq{
    <script>
    (function() {
        var seconds = $auto_refresh;
        var el = document.getElementById('refresh-timer');
        if (!el) return;
        var paused = false;
        try { paused = localStorage.getItem('ergo_mm_autorefresh') === 'off'; } catch (e) {}
        var deadline = Date.now() + seconds * 1000;
        function draw(remaining) {
            el.textContent = paused ? 'Auto-refresh paused (click to resume)' : ('Refresh in ' + remaining + 's');
            el.className = 'refresh-timer' + (paused ? ' paused' : '');
        }
        function tick() {
            if (paused) { draw(seconds); return; }
            var remaining = Math.max(0, Math.ceil((deadline - Date.now()) / 1000));
            if (remaining <= 0) {
                if (!document.hidden) { location.reload(); }   // background tabs reload when they come back
                return;
            }
            draw(remaining);
        }
        el.addEventListener('click', function() {
            paused = !paused;
            try { localStorage.setItem('ergo_mm_autorefresh', paused ? 'off' : 'on'); } catch (e) {}
            deadline = Date.now() + seconds * 1000;
            tick();
        });
        setInterval(tick, 1000);
        document.addEventListener('visibilitychange', tick);
        tick();
    })();
    </script>
        };
    }

    print html_footer();
}

sub render_overview_tab {
    my ($dbh, $prices, $depth, $metrics, $recommendations, $alerts, $chart_data, $config) = @_;
    $config ||= {};

    # Fetch user balance and depth data
    my $user_balances = get_latest_user_balances($dbh);
    my $user_depth = get_latest_user_depth($dbh);
    my $user_orders = get_user_open_orders($dbh);

    print qq{<div class="dashboard-grid">};

    # KuCoin vs MEXC price gap - are the books crossed against you?
    render_cross_exchange_strip($prices);

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

                # Inventory skew: a market maker usually wants to sit near 50/50 ERG/USDT by value
                my $erg_value = ($user_bal->{erg_total} || 0) * ($exchange_data->{price} || 0);
                my $total_value = $user_bal->{total_value_usd} || 0;
                if ($total_value > 0) {
                    my $erg_pct = $erg_value / $total_value * 100;
                    $erg_pct = 100 if $erg_pct > 100;
                    my $skew_style = abs($erg_pct - 50) > 25 ? 'color: var(--accent-orange); font-weight: 600;' : 'color: var(--text-primary);';
                    print qq{
                    <div class="balance-detail" style="margin: -8px 0 14px;">
                        Inventory split: <span style="$skew_style">} . sprintf("%.0f", $erg_pct) . qq{% ERG / } . sprintf("%.0f", 100 - $erg_pct) . qq{% USDT</span>
                        <span style="color: var(--text-muted);">(50/50 = neutral; &gt;75% one side = skewed)</span>
                        <div class="inventory-bar" title="Cyan = ERG, blue = USDT"><span style="width: } . sprintf("%.0f", $erg_pct) . qq{%;"></span></div>
                    </div>
                    };
                }
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
                        <div class="stat-label">6h Trades</div>
                        <div class="stat-value">} . ($trade_summary->{trade_count} || 0) . qq{</div>
                    </div>
                    <div class="stat-box">
                        <div class="stat-label">6h Buy Vol</div>
                        <div class="stat-value bid-value">\$} . format_number($buy_vol) . qq{</div>
                    </div>
                    <div class="stat-box">
                        <div class="stat-label">6h Sell Vol (} . sprintf("%.0f", 100 - $buy_ratio) . qq{%)</div>
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

    # ERG moving on/off the exchanges (on-chain)
    render_flow_summary_card($dbh, $config, 0);

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
                       $rec->{action} eq 'TIGHTEN_SPREAD' ? '📉' :
                       $rec->{action} eq 'REDUCE_BIDS' ? '📥' : '💡';

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

sub render_cross_exchange_strip {
    my ($prices) = @_;

    my %by_exchange = map { $_->{exchange} => $_ } @$prices;
    my ($m, $k) = ($by_exchange{MEXC}, $by_exchange{KUCOIN});
    return unless $m && $k && $m->{price} && $k->{price};

    my $mid_m = ($m->{bid_price} && $m->{ask_price}) ? ($m->{bid_price} + $m->{ask_price}) / 2 : $m->{price};
    my $mid_k = ($k->{bid_price} && $k->{ask_price}) ? ($k->{bid_price} + $k->{ask_price}) / 2 : $k->{price};
    my $avg = ($mid_m + $mid_k) / 2;
    my $gap_pct = $avg ? ($mid_m - $mid_k) / $avg * 100 : 0;
    my $gap_class = abs($gap_pct) >= 1 ? 'negative' : abs($gap_pct) >= 0.5 ? 'warning' : 'positive';
    my $gap_note = $gap_pct > 0.05 ? 'MEXC trades above KuCoin' : $gap_pct < -0.05 ? 'KuCoin trades above MEXC' : 'Venues aligned';

    # Can someone buy on one book and sell on the other at a profit? If yes, your quotes are being arbed.
    my $arb_buy_k = ($k->{ask_price} && $m->{bid_price}) ? ($m->{bid_price} - $k->{ask_price}) / $k->{ask_price} * 100 : -99;
    my $arb_buy_m = ($m->{ask_price} && $k->{bid_price}) ? ($k->{bid_price} - $m->{ask_price}) / $m->{ask_price} * 100 : -99;
    my ($best_arb, $arb_route) = $arb_buy_k >= $arb_buy_m
        ? ($arb_buy_k, 'buy KuCoin ask, sell MEXC bid')
        : ($arb_buy_m, 'buy MEXC ask, sell KuCoin bid');
    my $arb_class = $best_arb > 0.3 ? 'negative' : $best_arb > 0 ? 'warning' : 'positive';
    my $arb_value = $best_arb > 0 ? sprintf("CROSSED +%.2f%%", $best_arb) : sprintf("No (%.2f%%)", $best_arb);
    my $arb_note = $best_arb > 0 ? "Profitable: $arb_route" : "Best route ($arb_route) loses money";

    print qq{
        <div class="xchg-strip">
            <div class="xchg-box">
                <div class="xchg-label">MEXC mid</div>
                <div class="xchg-value">\$} . sprintf("%.4f", $mid_m) . qq{</div>
                <div class="xchg-sub">bid } . sprintf("%.4f", $m->{bid_price} || 0) . qq{ / ask } . sprintf("%.4f", $m->{ask_price} || 0) . qq{ · spread } . sprintf("%.2f", $m->{spread_percent} || 0) . qq{%</div>
            </div>
            <div class="xchg-box">
                <div class="xchg-label">KuCoin mid</div>
                <div class="xchg-value">\$} . sprintf("%.4f", $mid_k) . qq{</div>
                <div class="xchg-sub">bid } . sprintf("%.4f", $k->{bid_price} || 0) . qq{ / ask } . sprintf("%.4f", $k->{ask_price} || 0) . qq{ · spread } . sprintf("%.2f", $k->{spread_percent} || 0) . qq{%</div>
            </div>
            <div class="xchg-box">
                <div class="xchg-label">Price gap (MEXC vs KuCoin)</div>
                <div class="xchg-value $gap_class">} . sprintf("%+.2f%%", $gap_pct) . qq{</div>
                <div class="xchg-sub">$gap_note · \$} . sprintf("%.4f", abs($mid_m - $mid_k)) . qq{ apart</div>
            </div>
            <div class="xchg-box">
                <div class="xchg-label">Books crossed?</div>
                <div class="xchg-value $arb_class">$arb_value</div>
                <div class="xchg-sub">$arb_note</div>
            </div>
        </div>
    };
}

sub render_flow_exchange_box {
    my ($exchange, $summary, $reserve, $config, $show_addresses, $hints, $last_activity) = @_;
    $hints ||= {};

    my $exchange_lower = lc($exchange);
    my $display = $exchange eq 'KUCOIN' ? 'KuCoin' : $exchange;
    my @addresses = parse_address_list($config->{"${exchange_lower}_erg_addresses"}{value});

    print qq{
        <div class="flow-exchange">
            <div class="flow-exchange-header">
                <div class="exchange-header" style="margin-bottom: 0;">
                    <div class="exchange-logo $exchange_lower" style="width: 32px; height: 32px; font-size: 10px;">$exchange</div>
                    <div class="exchange-name" style="font-size: 16px;">$display</div>
                </div>
    };

    unless (@addresses) {
        my @found = map { $_->{address} } @{ $hints->{$exchange} || [] };
        my $how = @found
            ? "Your withdrawals were sent from <span class=\"mono\">" . join('</span>, <span class="mono">', @found) . "</span>: that is the hot wallet. Add it with one click in "
            : $exchange eq 'MEXC'
                ? "MEXC's wallet is not publicly catalogued; once api_keys.conf works the monitor finds it from your own withdrawals and offers it in "
                : "Add them in ";
        print qq{
            </div>
            <div class="setup-hint">No $display wallet addresses configured, so on-chain flows are not tracked yet. $how<a href="?tab=settings">Settings &rarr; On-chain Flow Tracking</a>.</div>
        </div>
        };
        return;
    }

    my $reserve_html;
    if ($reserve && $reserve->{total_erg}) {
        $reserve_html = qq{<div class="flow-reserve"><strong>} . format_erg($reserve->{total_erg}) . qq{ ERG</strong> in tracked wallets<br>as of $reserve->{updated}</div>};
    } else {
        $reserve_html = qq{<div class="flow-reserve">Reserve: waiting for the first explorer poll</div>};
    }

    print qq{
                $reserve_html
            </div>
            <table class="flow-table">
                <thead><tr><th>Window</th><th>In (deposits)</th><th>Out (withdrawals)</th><th>Net</th></tr></thead>
                <tbody>
    };

    foreach my $window ('1h', '6h', '24h') {
        my $in  = $summary ? ($summary->{"in_$window"}  || 0) : 0;
        my $out = $summary ? ($summary->{"out_$window"} || 0) : 0;
        my $net = $in - $out;
        my $net_class = $net > 0 ? 'flow-net-pos' : $net < 0 ? 'flow-net-neg' : '';
        print qq{
                    <tr>
                        <td>$window</td>
                        <td class="flow-in">} . format_erg($in) . qq{</td>
                        <td class="flow-out">} . format_erg($out) . qq{</td>
                        <td class="$net_class">} . format_signed_erg($net) . qq{</td>
                    </tr>
        };
    }

    my $tx_count = $summary ? ($summary->{tx_24h} || 0) : 0;
    my $activity_note;
    if ($tx_count > 0) {
        $activity_note = "$tx_count transfer" . ($tx_count == 1 ? '' : 's') . " in 24h &middot; last: $summary->{last_tx}";
    } elsif ($last_activity && $last_activity->{last_tx}) {
        my $days = $last_activity->{days_ago} || 0;
        $activity_note = "no transfers in 24h &middot; last recorded on-chain activity: $last_activity->{last_tx}";
        $activity_note .= qq{ <span style="color: var(--accent-orange);">&middot; $days days ago: these addresses look dormant, check the wallet hints in <a href="?tab=settings" style="color: var(--accent-cyan);">Settings</a></span>} if $days >= 7;
    } else {
        $activity_note = "no on-chain transfers recorded yet";
    }

    print qq{
                </tbody>
            </table>
            <div class="flow-note">$activity_note</div>
    };

    if ($show_addresses) {
        my %balance_by_addr = map { $_->{address} => $_->{balance_erg} } @{ ($reserve && $reserve->{addresses}) || [] };
        print qq{<ul class="addr-list">};
        foreach my $address (@addresses) {
            my $balance = defined $balance_by_addr{$address} ? format_erg($balance_by_addr{$address}) . ' ERG' : 'no balance fetched yet';
            print qq{<li><a class="tx-link mono" href="} . explorer_addr_url($address) . qq{" target="_blank" rel="noopener">} . short_hash($address, 12, 8) . qq{</a><span>$balance</span></li>};
        }
        print qq{</ul>};
    }

    print qq{</div>};
}

sub render_flow_summary_card {
    my ($dbh, $config, $show_addresses) = @_;

    # Quiet DBI's PrintError here: a missing table just means the migration has not been applied yet
    local $dbh->{PrintError} = 0;
    my $summary  = eval { get_flow_summary($dbh) };
    my $tables_ok = defined $summary;
    my $reserves = $tables_ok ? (eval { get_flow_reserves($dbh) } || {}) : {};
    my $hints    = $tables_ok ? (eval { get_wallet_hints($dbh) } || {}) : {};
    my $activity = $tables_ok ? (eval { get_flow_last_activity($dbh) } || {}) : {};
    my $tracking_on = !defined $config->{flow_tracking_enabled} || ($config->{flow_tracking_enabled}{value} // '1') ne '0';

    print qq{
        <div class="card full-width">
            <div class="card-header">
                <div class="card-title">ERG On-chain Exchange Flows} . ($show_addresses ? '' : ' (24h)') . qq{</div>
                } . ($show_addresses ? '' : qq{<a href="?tab=flows" class="btn btn-secondary" style="padding: 6px 12px; font-size: 12px;">Full history &rarr;</a>}) . qq{
            </div>
            <div class="card-body">
    };

    if (!$tables_ok) {
        print qq{<div class="setup-hint">Flow tables are not installed yet. Run <code>mysql -u root -p ergo_mm &lt; sql/add_flow_tables.sql</code> on the server, then the monitor will start recording ERG moving in and out of the exchanges.</div>};
    } else {
        print qq{<div class="setup-hint" style="margin-bottom: 14px;">On-chain flow tracking is disabled in <a href="?tab=settings">Settings</a>; the numbers below will not update.</div>} unless $tracking_on;
        print qq{<div class="flow-grid">};
        foreach my $exchange ('MEXC', 'KUCOIN') {
            render_flow_exchange_box($exchange, $summary->{$exchange}, $reserves->{$exchange}, $config, $show_addresses, $hints, $activity->{$exchange});
        }
        print qq{</div>
            <div class="flow-note">
                <span class="flow-in">In</span> = ERG deposited into the exchange's wallets (deposits are usually sold soon after, so treat a jump as incoming sell pressure).
                <span class="flow-out">Out</span> = ERG withdrawn from the exchange (supply leaving the book).
                Net &gt; 0 means the exchange is stacking sell-side inventory; net &lt; 0 means it is draining. Polled every minute from the Ergo explorer.
            </div>};
    }

    print qq{</div></div>};
}

sub render_account_transfers_card {
    my ($summary, $user_transfers) = @_;

    my $have_keys_data = (keys %$summary) || @$user_transfers;

    print qq{
        <div class="card full-width">
            <div class="card-header">
                <div class="card-title">Your MM Account: ERG &amp; USDT In / Out</div>
                <span class="card-badge">deposits &amp; withdrawals</span>
            </div>
            <div class="card-body">
    };

    unless ($have_keys_data) {
        print qq{<div class="setup-hint">Nothing recorded for the market-maker account yet. Deposits and withdrawals are read from the MEXC and KuCoin account APIs, so <code>api_keys.conf</code> must contain read-only keys for each exchange. The first run backfills the last 30 days.</div></div></div>};
        return;
    }

    print qq{<div class="flow-grid">};
    foreach my $exchange ('MEXC', 'KUCOIN') {
        my $exchange_lower = lc($exchange);
        my $display = $exchange eq 'KUCOIN' ? 'KuCoin' : $exchange;
        my $by_currency = $summary->{$exchange} || {};

        my $last_tx = '';
        foreach my $row (values %$by_currency) {
            $last_tx = $row->{last_tx} if $row->{last_tx} && $row->{last_tx} gt $last_tx;
        }

        print qq{
            <div class="flow-exchange">
                <div class="flow-exchange-header">
                    <div class="exchange-header" style="margin-bottom: 0;">
                        <div class="exchange-logo $exchange_lower" style="width: 32px; height: 32px; font-size: 10px;">$exchange</div>
                        <div class="exchange-name" style="font-size: 16px;">$display</div>
                    </div>
                    <div class="flow-reserve">} . ($last_tx ? "last transfer<br>$last_tx" : 'no transfers in 30 days') . qq{</div>
                </div>
                <table class="flow-table">
                    <thead><tr><th>Asset</th><th>Window</th><th>Deposits (in)</th><th>Withdrawals (out)</th><th>Net</th></tr></thead>
                    <tbody>
        };

        foreach my $currency ('ERG', 'USDT') {
            my $row = $by_currency->{$currency} || {};
            my $first = 1;
            foreach my $window (['1d', '24h'], ['7d', '7d'], ['30d', '30d']) {
                my ($key, $label) = @$window;
                my $in  = $row->{"in_$key"}  || 0;
                my $out = $row->{"out_$key"} || 0;
                my $net = $in - $out;
                my $net_class = $net > 0 ? 'acct-net-pos' : $net < 0 ? 'acct-net-neg' : '';
                my $asset_cell = $first ? qq{<td class="asset-cell" rowspan="3"><span class="asset-tag">$currency</span></td>} : '';
                print qq{
                        <tr>
                            $asset_cell
                            <td style="text-align: left;">$label</td>
                            <td class="acct-in">} . format_amount($in, $currency) . qq{</td>
                            <td class="acct-out">} . format_amount($out, $currency) . qq{</td>
                            <td class="$net_class">} . format_signed_amount($net, $currency) . qq{</td>
                        </tr>
                };
                $first = 0;
            }
        }

        print qq{
                    </tbody>
                </table>
            </div>
        };
    }
    print qq{</div>
            <div class="flow-note">
                <span class="acct-in">Deposits</span> = funds you moved onto the exchange, <span class="acct-out">withdrawals</span> = funds you took off it, so net &gt; 0 means capital was added to that venue in the window.
                Failed, cancelled and rejected transfers are excluded. Read from the exchange account APIs every minute (7-day window; the first run backfills 30 days).
            </div>
        </div></div>};
}

sub render_flows_tab {
    my ($dbh, $config) = @_;

    print qq{<div class="dashboard-grid">};

    render_flow_summary_card($dbh, $config, 1);

    local $dbh->{PrintError} = 0;   # tables may not exist yet; the card above already explains that
    my $flow_history    = eval { get_flow_history($dbh, 48) } || [];
    my $reserve_history = eval { get_reserve_history($dbh, 48) } || [];
    my $recent_flows    = eval { get_recent_flows($dbh, 100, 48) } || [];
    my $user_transfers  = eval { get_user_transfers($dbh, 50) } || [];
    my $account_summary = eval { get_user_transfer_summary($dbh) } || {};

    # Charts: net flow per hour + reserve balance
    my (%net_by_bucket, %reserve_by_bucket);
    foreach my $row (@$flow_history) {
        $net_by_bucket{$row->{time_bucket}}{$row->{exchange}} = ($row->{in_erg} || 0) - ($row->{out_erg} || 0);
    }
    foreach my $row (@$reserve_history) {
        $reserve_by_bucket{$row->{time_bucket}}{$row->{exchange}} = $row->{balance_erg} + 0;
    }
    my @flow_labels = sort keys %net_by_bucket;
    my @reserve_labels = sort keys %reserve_by_bucket;
    my @mexc_net   = map { $net_by_bucket{$_}{MEXC}   // 0 } @flow_labels;
    my @kucoin_net = map { $net_by_bucket{$_}{KUCOIN} // 0 } @flow_labels;
    my @mexc_res   = map { $reserve_by_bucket{$_}{MEXC}   } @reserve_labels;     # undef -> null (gap)
    my @kucoin_res = map { $reserve_by_bucket{$_}{KUCOIN} } @reserve_labels;

    my $flow_labels_json    = encode_json(\@flow_labels);
    my $reserve_labels_json = encode_json(\@reserve_labels);
    my $mexc_net_json       = encode_json(\@mexc_net);
    my $kucoin_net_json     = encode_json(\@kucoin_net);
    my $mexc_res_json       = encode_json(\@mexc_res);
    my $kucoin_res_json     = encode_json(\@kucoin_res);

    print qq{
        <div class="card half-width">
            <div class="card-header"><div class="card-title">Net Flow per Hour (48h)</div></div>
            <div class="card-body"><div class="chart-container tall"><canvas id="flowNetChart"></canvas></div></div>
        </div>
        <div class="card half-width">
            <div class="card-header"><div class="card-title">ERG Held in Tracked Exchange Wallets (48h)</div></div>
            <div class="card-body"><div class="chart-container tall"><canvas id="reserveChart"></canvas></div></div>
        </div>

        <script>
        (function() {
            const tickCb = function(value) {
                const label = this.getLabelForValue(value);
                if (label && label.length > 5) {
                    const parts = label.split(' ');
                    return parts.length > 1 ? parts[1] : label.slice(-5);
                }
                return label;
            };
            const base = {
                responsive: true,
                maintainAspectRatio: false,
                interaction: { mode: 'index', intersect: false },
                plugins: {
                    legend: { labels: { color: '#9aa0a6', boxWidth: 12, font: { size: 11 } } },
                    tooltip: { mode: 'index', intersect: false, backgroundColor: 'rgba(30, 34, 42, 0.95)', titleColor: '#e8eaed', bodyColor: '#9aa0a6', borderColor: '#374151', borderWidth: 1, padding: 10 }
                },
                scales: {
                    x: { grid: { color: '#374151' }, ticks: { color: '#9aa0a6', maxTicksLimit: 12, maxRotation: 45, callback: tickCb } },
                    y: { grid: { color: '#374151' }, ticks: { color: '#9aa0a6' } }
                }
            };
            new Chart(document.getElementById('flowNetChart'), {
                type: 'bar',
                data: {
                    labels: $flow_labels_json,
                    datasets: [
                        { label: 'MEXC net (ERG)', data: $mexc_net_json, backgroundColor: 'rgba(22, 82, 240, 0.75)' },
                        { label: 'KuCoin net (ERG)', data: $kucoin_net_json, backgroundColor: 'rgba(36, 174, 143, 0.75)' }
                    ]
                },
                options: {
                    ...base,
                    plugins: { ...base.plugins, title: { display: true, text: 'Positive = ERG arriving on the exchange, negative = leaving', color: '#e8eaed' } }
                }
            });
            new Chart(document.getElementById('reserveChart'), {
                type: 'line',
                data: {
                    labels: $reserve_labels_json,
                    datasets: [
                        { label: 'MEXC (ERG)', data: $mexc_res_json, borderColor: '#1652f0', backgroundColor: 'rgba(22, 82, 240, 0.1)', fill: true, tension: 0.3, pointRadius: 0, spanGaps: true },
                        { label: 'KuCoin (ERG)', data: $kucoin_res_json, borderColor: '#24ae8f', backgroundColor: 'rgba(36, 174, 143, 0.1)', fill: true, tension: 0.3, pointRadius: 0, spanGaps: true }
                    ]
                },
                options: {
                    ...base,
                    plugins: { ...base.plugins, title: { display: true, text: 'Confirmed balance of the tracked wallets', color: '#e8eaed' } },
                    scales: { ...base.scales, y: { ...base.scales.y, ticks: { ...base.scales.y.ticks, callback: v => (v / 1000).toFixed(1) + 'k' } } }
                }
            });
        })();
        </script>
    };

    # Recent on-chain transfers
    print qq{
        <div class="card full-width">
            <div class="card-header">
                <div class="card-title">Recent On-chain Transfers (48h)</div>
                <span class="card-badge">} . scalar(@$recent_flows) . qq{ shown</span>
            </div>
            <div class="card-body">
    };

    if (@$recent_flows) {
        print qq{
                <div class="table-scroll">
                <table class="flow-table wide">
                    <thead><tr><th>Time</th><th>Exchange</th><th>Direction</th><th>Amount</th><th>&asymp; USD</th><th>Counterparty</th><th>Transaction</th></tr></thead>
                    <tbody>
        };
        foreach my $flow (@$recent_flows) {
            my $dir = $flow->{direction} eq 'in' ? 'in' : 'out';
            my $dir_label = $dir eq 'in' ? 'IN (deposit)' : 'OUT (withdrawal)';
            my $tx_id = escapeHTML($flow->{tx_id} || '');
            my $counterparty = $flow->{counterparty} ? escapeHTML($flow->{counterparty}) : '';
            my $counterparty_html = $counterparty
                ? qq{<a class="tx-link mono" href="} . explorer_addr_url($counterparty) . qq{" target="_blank" rel="noopener">} . short_hash($counterparty, 8, 6) . qq{</a>}
                : '<span class="mono" style="color: var(--text-muted);">-</span>';
            my $usd = defined $flow->{amount_usd} ? '$' . commify(sprintf("%.0f", $flow->{amount_usd})) : '-';
            print qq{
                        <tr>
                            <td style="text-align: left;">$flow->{tx_time}</td>
                            <td style="text-align: left;">} . ($flow->{exchange} eq 'KUCOIN' ? 'KuCoin' : $flow->{exchange}) . qq{</td>
                            <td style="text-align: left;"><span class="flow-badge $dir">$dir_label</span></td>
                            <td class="flow-$dir">} . format_erg($flow->{amount_erg}) . qq{ ERG</td>
                            <td>$usd</td>
                            <td>$counterparty_html</td>
                            <td><a class="tx-link mono" href="} . explorer_tx_url($tx_id) . qq{" target="_blank" rel="noopener">} . short_hash($tx_id, 10, 6) . qq{</a></td>
                        </tr>
            };
        }
        print qq{</tbody></table></div>};
    } else {
        print qq{<div class="empty-state"><div class="empty-state-icon">&#9878;</div><p>No on-chain transfers recorded in the last 48 hours. Once wallet addresses are configured and the monitor has polled the explorer, deposits and withdrawals will appear here within a minute of confirming.</p></div>};
    }
    print qq{</div></div>};

    # The MM account's own deposits / withdrawals (ERG + USDT) from the exchange account APIs
    render_account_transfers_card($account_summary, $user_transfers);

    print qq{
        <div class="card full-width">
            <div class="card-header">
                <div class="card-title">Your MM Account: Transfer History</div>
                <span class="card-badge">} . scalar(@$user_transfers) . qq{ shown</span>
            </div>
            <div class="card-body">
    };

    if (@$user_transfers) {
        print qq{
                <div class="table-scroll">
                <table class="flow-table wide">
                    <thead><tr><th>Time</th><th>Exchange</th><th>Asset</th><th>Type</th><th>Amount</th><th>Fee</th><th>Network</th><th>Status</th><th>Address</th><th>Transaction</th></tr></thead>
                    <tbody>
        };
        foreach my $t (@$user_transfers) {
            my $type = $t->{direction} eq 'deposit' ? 'deposit' : 'withdrawal';
            my $currency = uc($t->{currency} || 'ERG');
            my $status = escapeHTML($t->{status} || '');
            my $network = escapeHTML($t->{network} || '-');
            my $address = $t->{address} ? escapeHTML($t->{address}) : '';
            my $tx_id = $t->{tx_id} ? escapeHTML($t->{tx_id}) : '';
            my $tx_html = !$tx_id ? '<span style="color: var(--text-muted);">-</span>'
                : $currency eq 'ERG'
                    ? qq{<a class="tx-link mono" href="} . explorer_tx_url($tx_id) . qq{" target="_blank" rel="noopener">} . short_hash($tx_id, 10, 6) . qq{</a>}
                    : qq{<span class="mono" title="$tx_id">} . short_hash($tx_id, 10, 6) . qq{</span>};
            my $fee_html = ($t->{fee} || 0) > 0 ? sprintf("%.4f %s", $t->{fee}, $currency) : '-';
            print qq{
                        <tr>
                            <td style="text-align: left;">} . ($t->{tx_time} || '-') . qq{</td>
                            <td style="text-align: left;">} . ($t->{exchange} eq 'KUCOIN' ? 'KuCoin' : $t->{exchange}) . qq{</td>
                            <td style="text-align: left;"><span class="asset-tag">$currency</span></td>
                            <td style="text-align: left;"><span class="flow-badge $type">$type</span></td>
                            <td class="acct-} . ($type eq 'deposit' ? 'in' : 'out') . qq{">} . format_amount($t->{amount}, $currency) . qq{</td>
                            <td>$fee_html</td>
                            <td>$network</td>
                            <td>$status</td>
                            <td><span class="mono" title="$address">} . short_hash($address, 8, 6) . qq{</span></td>
                            <td>$tx_html</td>
                        </tr>
            };
        }
        print qq{</tbody></table></div>};
    } else {
        print qq{<div class="empty-state"><p>No account deposits or withdrawals recorded yet. This list fills in from the MEXC/KuCoin account APIs when <code>api_keys.conf</code> is configured with read-only keys (the first run backfills 30 days).</p></div>};
    }
    print qq{</div></div>};

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

sub render_wallet_hints_html {
    my ($exchange, $hints, $textarea_name, $configured) = @_;
    my @rows = @{ $hints->{$exchange} || [] };
    return '' unless @rows;

    my %configured = map { $_ => 1 } @$configured;
    my $html = qq{<div class="setting-description" style="margin-top: 8px; color: var(--text-secondary);">Seen sending your withdrawals (the exchange's hot wallet):</div><ul class="addr-list" style="border-top: none; padding-top: 2px; margin-top: 2px;">};
    foreach my $h (@rows) {
        my $address = $h->{address};
        my $n = $h->{withdrawals} || 0;
        my $action = $configured{$address}
            ? qq{<span style="color: var(--accent-green);">tracked</span>}
            : qq{<a href="#" class="tx-link" onclick="return ergoAddAddress('$textarea_name', '$address');">add</a>};
        $html .= qq{<li><span class="mono">$address</span><span>$n withdrawal} . ($n == 1 ? '' : 's') . qq{ &middot; $action</span></li>};
    }
    return $html . '</ul>';
}

sub render_settings_tab {
    my ($config, $saved, $dbh) = @_;

    my $hints = {};
    if ($dbh) {
        local $dbh->{PrintError} = 0;
        $hints = eval { get_wallet_hints($dbh) } || {};
    }
    my @kucoin_configured = parse_address_list($config->{kucoin_erg_addresses}{value});
    my @mexc_configured   = parse_address_list($config->{mexc_erg_addresses}{value});

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
                                    <label class="setting-label">Price Change Critical (%)</label>
                                    <input type="number" step="0.1" name="price_change_critical" class="setting-input"
                                           value="} . ($config->{price_change_critical}{value} || '10.0') . qq{">
                                    <div class="setting-description">24h move that raises PRICE_CHANGE_HIGH and a REDUCE_EXPOSURE recommendation</div>
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">Liquidity Pull Threshold (%)</label>
                                    <input type="number" step="0.1" name="liquidity_pull_threshold" class="setting-input"
                                           value="} . ($config->{liquidity_pull_threshold}{value} || '15.0') . qq{">
                                </div>
                            </div>

                            <div class="setting-group">
                                <h3>On-chain Flow Tracking</h3>
                                <div class="setting-item">
                                    <label class="setting-label">Track ERG flows in/out of exchanges</label>
                                    <select name="flow_tracking_enabled" class="setting-input">
                                        <option value="1" } . (($config->{flow_tracking_enabled}{value} // '1') ne '0' ? 'selected' : '') . qq{>Enabled</option>
                                        <option value="0" } . (($config->{flow_tracking_enabled}{value} // '1') eq '0' ? 'selected' : '') . qq{>Disabled</option>
                                    </select>
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">KuCoin ERG Wallet Addresses</label>
                                    <textarea name="kucoin_erg_addresses" class="setting-input" placeholder="One per line or comma-separated">} . escapeHTML($config->{kucoin_erg_addresses}{value} // '') . qq{</textarea>
                                    <div class="setting-description">Pre-filled with one known KuCoin wallet. The Flows tab shows each address's live balance; the monitor log reports any address the explorer rejects.</div>
                                    } . render_wallet_hints_html('KUCOIN', $hints, 'kucoin_erg_addresses', \@kucoin_configured) . qq{
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">MEXC ERG Wallet Addresses</label>
                                    <textarea name="mexc_erg_addresses" class="setting-input" placeholder="One per line or comma-separated">} . escapeHTML($config->{mexc_erg_addresses}{value} // '') . qq{</textarea>
                                    <div class="setting-description">MEXC's wallet is not publicly catalogued. Once api_keys.conf is working, the monitor looks up your own MEXC withdrawals and lists the sending address here; or open one on explorer.ergoplatform.com yourself.</div>
                                    } . render_wallet_hints_html('MEXC', $hints, 'mexc_erg_addresses', \@mexc_configured) . qq{
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">Large Transfer Alert (ERG)</label>
                                    <input type="number" step="1" min="0" name="flow_alert_threshold_erg" class="setting-input"
                                           value="} . ($config->{flow_alert_threshold_erg}{value} // '5000') . qq{">
                                    <div class="setting-description">A single deposit/withdrawal this size alerts (LARGE_INFLOW / LARGE_OUTFLOW). Net 1h inflow of 2x this raises a critical NET_INFLOW_HIGH alert and a REDUCE_BIDS recommendation. 0 disables.</div>
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">Ergo Explorer API URL</label>
                                    <input type="text" name="ergo_explorer_url" class="setting-input"
                                           value="} . escapeHTML($config->{ergo_explorer_url}{value} // 'https://api.ergoplatform.com') . qq{">
                                    <div class="setting-description">Point this at your own explorer backend if the public one is slow or rate-limited.</div>
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
        <script>
        function ergoAddAddress(fieldName, address) {
            var field = document.getElementsByName(fieldName)[0];
            if (!field) return false;
            if (field.value.indexOf(address) === -1) {
                field.value = (field.value.trim() ? field.value.trim() + "\\n" : '') + address;
            }
            field.focus();
            return false;
        }
        </script>
    };
}

sub commify {
    my ($num) = @_;
    my $text = reverse "$num";
    $text =~ s/(\d\d\d)(?=\d)(?!\d*\.)/$1,/g;
    return scalar reverse $text;
}

sub format_erg {
    my ($num) = @_;
    $num = 0 unless defined $num;
    return '0' if $num == 0;
    return commify(sprintf("%.0f", $num)) if abs($num) >= 100;
    return sprintf("%.2f", $num);
}

sub format_signed_erg {
    my ($num) = @_;
    $num = 0 unless defined $num;
    my $sign = $num > 0 ? '+' : $num < 0 ? '-' : '';
    return $sign . format_erg(abs($num));
}

# Amount with its unit: "1,234 ERG" / "$2,500" (USDT shown as dollars)
sub format_amount {
    my ($num, $currency) = @_;
    $num = 0 unless defined $num;
    $currency = uc($currency || 'ERG');
    if ($currency eq 'USDT') {
        return '$0' if $num == 0;
        return '$' . (abs($num) >= 1000 ? commify(sprintf("%.0f", $num)) : sprintf("%.2f", $num));
    }
    return format_erg($num) . " $currency";
}

sub format_signed_amount {
    my ($num, $currency) = @_;
    $num = 0 unless defined $num;
    my $sign = $num > 0 ? '+' : $num < 0 ? '-' : '';
    return $sign . format_amount(abs($num), $currency);
}

sub format_age {
    my ($seconds) = @_;
    return 'n/a' unless defined $seconds;
    return sprintf("%ds", $seconds) if $seconds < 60;
    return sprintf("%dm", $seconds / 60) if $seconds < 3600;
    return sprintf("%.1fh", $seconds / 3600);
}

sub short_hash {
    my ($text, $head, $tail) = @_;
    return '' unless defined $text;
    $head ||= 8;
    $tail ||= 6;
    return $text if length($text) <= $head + $tail + 3;
    return substr($text, 0, $head) . '&hellip;' . substr($text, -$tail);
}

sub explorer_tx_url   { return "https://explorer.ergoplatform.com/en/transactions/$_[0]"; }
sub explorer_addr_url { return "https://explorer.ergoplatform.com/en/addresses/$_[0]"; }

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
            flow_tracking_enabled kucoin_erg_addresses mexc_erg_addresses
            flow_alert_threshold_erg ergo_explorer_url
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

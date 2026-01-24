#!/usr/bin/perl
# ============================================================
# ERGO Market Maker Dashboard
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
sub get_db_connection {
    open my $fh, '<', '/usr/lib/cgi-bin/sql.txt' or die "Can't open password file: $!";
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
        # Update last activity
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
    my $sth = $dbh->prepare("SELECT * FROM v_latest_prices ORDER BY exchange");
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
    my $sth = $dbh->prepare("SELECT * FROM v_latest_depth ORDER BY exchange, depth_level");
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
    my $sth = $dbh->prepare("SELECT * FROM v_latest_metrics ORDER BY exchange");
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
    my $sth = $dbh->prepare("SELECT * FROM v_active_recommendations LIMIT 10");
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
    my $sth = $dbh->prepare("SELECT * FROM v_recent_alerts LIMIT ?");
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

    my $sth = $dbh->prepare(qq{
        SELECT
            DATE_FORMAT(timestamp, '%Y-%m-%d %H:%i') as time_bucket,
            AVG(price) as price,
            AVG(spread_percent) as spread,
            MAX(high_24h) as high,
            MIN(low_24h) as low
        FROM price_data
        WHERE exchange = ?
          AND timestamp > DATE_SUB(NOW(), INTERVAL ? HOUR)
        GROUP BY time_bucket
        ORDER BY time_bucket
    });
    $sth->execute($exchange, $hours);
    my @results;
    while (my $row = $sth->fetchrow_hashref()) {
        push @results, $row;
    }
    $sth->finish();
    return \@results;
}

sub get_depth_history {
    my ($dbh, $exchange, $hours) = @_;
    $hours ||= 24;

    my $sth = $dbh->prepare(qq{
        SELECT
            DATE_FORMAT(timestamp, '%Y-%m-%d %H:%i') as time_bucket,
            depth_level,
            AVG(bid_depth_usd) as bid_depth,
            AVG(ask_depth_usd) as ask_depth
        FROM orderbook_depth
        WHERE exchange = ?
          AND timestamp > DATE_SUB(NOW(), INTERVAL ? HOUR)
        GROUP BY time_bucket, depth_level
        ORDER BY time_bucket, depth_level
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
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
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

        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            min-height: 100vh;
            line-height: 1.5;
        }

        .container {
            max-width: 1600px;
            margin: 0 auto;
            padding: 20px;
        }

        /* Header */
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

        .header-title {
            display: flex;
            align-items: center;
            gap: 12px;
        }

        .header-title h1 {
            font-size: 24px;
            font-weight: 700;
            background: linear-gradient(90deg, var(--accent-cyan), var(--accent-blue));
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        .header-subtitle {
            color: var(--text-secondary);
            font-size: 14px;
        }

        .header-actions {
            display: flex;
            gap: 12px;
            align-items: center;
        }

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

        .btn-primary {
            background: var(--accent-cyan);
            color: var(--bg-primary);
        }

        .btn-primary:hover {
            background: #00b894;
        }

        .btn-secondary {
            background: var(--bg-tertiary);
            color: var(--text-primary);
            border: 1px solid var(--border-color);
        }

        .btn-secondary:hover {
            background: var(--bg-card);
        }

        .btn-danger {
            background: var(--accent-red);
            color: white;
        }

        /* Status Indicator */
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

        .status-dot.online {
            background: var(--accent-green);
        }

        .status-dot.offline {
            background: var(--accent-red);
        }

        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
        }

        /* Grid Layout */
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

        .card-title {
            font-size: 16px;
            font-weight: 600;
            color: var(--text-primary);
        }

        .card-badge {
            padding: 4px 10px;
            border-radius: 12px;
            font-size: 12px;
            font-weight: 500;
        }

        .card-body {
            padding: 20px;
        }

        /* Exchange Cards */
        .exchange-card {
            grid-column: span 6;
        }

        .exchange-header {
            display: flex;
            align-items: center;
            gap: 12px;
            margin-bottom: 20px;
        }

        .exchange-logo {
            width: 40px;
            height: 40px;
            border-radius: 10px;
            background: var(--bg-tertiary);
            display: flex;
            align-items: center;
            justify-content: center;
            font-weight: 700;
            font-size: 14px;
        }

        .exchange-logo.kucoin {
            background: linear-gradient(135deg, #24ae8f, #1a7a64);
        }

        .exchange-logo.mexc {
            background: linear-gradient(135deg, #1652f0, #0d3d9e);
        }

        .exchange-name {
            font-size: 18px;
            font-weight: 600;
        }

        .exchange-pair {
            color: var(--text-secondary);
            font-size: 14px;
        }

        /* Metrics Grid */
        .metrics-grid {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 16px;
            margin-bottom: 24px;
        }

        .metric-box {
            background: var(--bg-tertiary);
            border-radius: 10px;
            padding: 16px;
            text-align: center;
        }

        .metric-label {
            font-size: 12px;
            color: var(--text-secondary);
            text-transform: uppercase;
            letter-spacing: 0.5px;
            margin-bottom: 8px;
        }

        .metric-value {
            font-size: 24px;
            font-weight: 700;
            color: var(--text-primary);
        }

        .metric-value.positive {
            color: var(--accent-green);
        }

        .metric-value.negative {
            color: var(--accent-red);
        }

        .metric-value.warning {
            color: var(--accent-orange);
        }

        .metric-change {
            font-size: 12px;
            margin-top: 4px;
        }

        /* Depth Table */
        .depth-table {
            width: 100%;
            border-collapse: collapse;
        }

        .depth-table th,
        .depth-table td {
            padding: 12px 16px;
            text-align: right;
            border-bottom: 1px solid var(--border-color);
        }

        .depth-table th {
            font-size: 12px;
            font-weight: 600;
            color: var(--text-secondary);
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }

        .depth-table th:first-child,
        .depth-table td:first-child {
            text-align: left;
        }

        .depth-table tr:last-child td {
            border-bottom: none;
        }

        .bid-value {
            color: var(--accent-green);
        }

        .ask-value {
            color: var(--accent-red);
        }

        /* Recommendations Panel */
        .recommendations-card {
            grid-column: span 12;
        }

        .recommendation-list {
            display: flex;
            flex-direction: column;
            gap: 12px;
        }

        .recommendation-item {
            display: flex;
            align-items: flex-start;
            gap: 16px;
            padding: 16px;
            background: var(--bg-tertiary);
            border-radius: 10px;
            border-left: 4px solid;
        }

        .recommendation-item.priority-high {
            border-left-color: var(--accent-red);
        }

        .recommendation-item.priority-medium {
            border-left-color: var(--accent-orange);
        }

        .recommendation-item.priority-low {
            border-left-color: var(--accent-blue);
        }

        .recommendation-icon {
            width: 40px;
            height: 40px;
            border-radius: 10px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 20px;
            flex-shrink: 0;
        }

        .recommendation-content {
            flex: 1;
        }

        .recommendation-action {
            font-weight: 600;
            font-size: 15px;
            margin-bottom: 4px;
        }

        .recommendation-reason {
            color: var(--text-secondary);
            font-size: 14px;
        }

        .recommendation-meta {
            display: flex;
            gap: 16px;
            margin-top: 8px;
            font-size: 12px;
            color: var(--text-muted);
        }

        /* Alerts Panel */
        .alerts-card {
            grid-column: span 6;
        }

        .alert-list {
            max-height: 400px;
            overflow-y: auto;
        }

        .alert-item {
            display: flex;
            align-items: flex-start;
            gap: 12px;
            padding: 14px;
            border-bottom: 1px solid var(--border-color);
        }

        .alert-item:last-child {
            border-bottom: none;
        }

        .alert-severity {
            width: 10px;
            height: 10px;
            border-radius: 50%;
            margin-top: 6px;
            flex-shrink: 0;
        }

        .alert-severity.critical {
            background: var(--accent-red);
        }

        .alert-severity.warning {
            background: var(--accent-orange);
        }

        .alert-severity.info {
            background: var(--accent-blue);
        }

        .alert-content {
            flex: 1;
        }

        .alert-message {
            font-size: 14px;
            margin-bottom: 4px;
        }

        .alert-time {
            font-size: 12px;
            color: var(--text-muted);
        }

        /* Charts */
        .chart-container {
            position: relative;
            height: 250px;
        }

        /* Settings Panel */
        .settings-grid {
            display: grid;
            grid-template-columns: repeat(2, 1fr);
            gap: 20px;
        }

        .setting-group {
            background: var(--bg-tertiary);
            border-radius: 10px;
            padding: 20px;
        }

        .setting-group h3 {
            font-size: 14px;
            font-weight: 600;
            margin-bottom: 16px;
            color: var(--text-primary);
        }

        .setting-item {
            margin-bottom: 16px;
        }

        .setting-item:last-child {
            margin-bottom: 0;
        }

        .setting-label {
            display: block;
            font-size: 13px;
            color: var(--text-secondary);
            margin-bottom: 6px;
        }

        .setting-input {
            width: 100%;
            padding: 10px 14px;
            border-radius: 8px;
            border: 1px solid var(--border-color);
            background: var(--bg-secondary);
            color: var(--text-primary);
            font-size: 14px;
        }

        .setting-input:focus {
            outline: none;
            border-color: var(--accent-cyan);
        }

        .setting-description {
            font-size: 11px;
            color: var(--text-muted);
            margin-top: 4px;
        }

        /* Login Form */
        .login-container {
            display: flex;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            background: var(--bg-primary);
        }

        .login-box {
            background: var(--bg-card);
            border-radius: 16px;
            padding: 40px;
            width: 100%;
            max-width: 400px;
            border: 1px solid var(--border-color);
            box-shadow: var(--shadow);
        }

        .login-title {
            text-align: center;
            margin-bottom: 32px;
        }

        .login-title h1 {
            font-size: 28px;
            font-weight: 700;
            margin-bottom: 8px;
            background: linear-gradient(90deg, var(--accent-cyan), var(--accent-blue));
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        .login-title p {
            color: var(--text-secondary);
            font-size: 14px;
        }

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

        .login-form input:focus {
            outline: none;
            border-color: var(--accent-cyan);
        }

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
            transition: transform 0.2s, box-shadow 0.2s;
        }

        .login-form button:hover {
            transform: translateY(-2px);
            box-shadow: 0 4px 12px rgba(0, 212, 170, 0.3);
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

        /* Tabs */
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

        .tab:hover {
            color: var(--text-primary);
            background: var(--bg-tertiary);
        }

        .tab.active {
            background: var(--accent-cyan);
            color: var(--bg-primary);
        }

        /* Responsive */
        @media (max-width: 1200px) {
            .exchange-card {
                grid-column: span 12;
            }

            .metrics-grid {
                grid-template-columns: repeat(2, 1fr);
            }
        }

        @media (max-width: 768px) {
            .container {
                padding: 12px;
            }

            .header {
                flex-direction: column;
                gap: 16px;
                text-align: center;
            }

            .metrics-grid {
                grid-template-columns: 1fr;
            }

            .settings-grid {
                grid-template-columns: 1fr;
            }

            .alerts-card {
                grid-column: span 12;
            }
        }

        /* Scrollbar */
        ::-webkit-scrollbar {
            width: 8px;
            height: 8px;
        }

        ::-webkit-scrollbar-track {
            background: var(--bg-secondary);
        }

        ::-webkit-scrollbar-thumb {
            background: var(--border-color);
            border-radius: 4px;
        }

        ::-webkit-scrollbar-thumb:hover {
            background: var(--text-muted);
        }

        /* Empty State */
        .empty-state {
            text-align: center;
            padding: 40px 20px;
            color: var(--text-secondary);
        }

        .empty-state-icon {
            font-size: 48px;
            margin-bottom: 16px;
            opacity: 0.5;
        }

        /* Tooltip */
        .tooltip {
            position: relative;
            cursor: help;
        }

        .tooltip::after {
            content: attr(data-tooltip);
            position: absolute;
            bottom: 100%;
            left: 50%;
            transform: translateX(-50%);
            padding: 6px 10px;
            background: var(--bg-primary);
            border: 1px solid var(--border-color);
            border-radius: 6px;
            font-size: 12px;
            white-space: nowrap;
            opacity: 0;
            visibility: hidden;
            transition: all 0.2s;
            z-index: 100;
        }

        .tooltip:hover::after {
            opacity: 1;
            visibility: visible;
        }
    </style>
</head>
<body>
};
}

sub html_footer {
    return qq{
    <script>
        // Auto-refresh every 60 seconds
        setTimeout(function() {
            location.reload();
        }, 60000);

        // Chart configuration
        Chart.defaults.color = '#9aa0a6';
        Chart.defaults.borderColor = '#374151';
    </script>
</body>
</html>
};
}

sub render_login_page {
    my ($error) = @_;

    print "Content-type: text/html\\n\\n";
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
    my ($dbh, $tab) = @_;
    $tab ||= 'overview';

    my $prices = get_latest_prices($dbh);
    my $depth = get_latest_depth($dbh);
    my $metrics = get_latest_metrics($dbh);
    my $recommendations = get_active_recommendations($dbh);
    my $alerts = get_recent_alerts($dbh, 20);
    my $config = get_config($dbh);

    print "Content-type: text/html\\n\\n";
    print html_header('ERGO MM Dashboard');

    print qq{
    <div class="container">
        <!-- Header -->
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

        <!-- Navigation Tabs -->
        <div class="tabs">
            <a href="?tab=overview" class="tab } . ($tab eq 'overview' ? 'active' : '') . qq{">Overview</a>
            <a href="?tab=alerts" class="tab } . ($tab eq 'alerts' ? 'active' : '') . qq{">Alerts</a>
            <a href="?tab=settings" class="tab } . ($tab eq 'settings' ? 'active' : '') . qq{">Settings</a>
        </div>
    };

    if ($tab eq 'overview') {
        render_overview_tab($prices, $depth, $metrics, $recommendations, $alerts);
    } elsif ($tab eq 'alerts') {
        render_alerts_tab($alerts);
    } elsif ($tab eq 'settings') {
        render_settings_tab($config);
    }

    print qq{
    </div>
    };

    print html_footer();
}

sub render_overview_tab {
    my ($prices, $depth, $metrics, $recommendations, $alerts) = @_;

    print qq{<div class="dashboard-grid">};

    # Exchange Cards
    foreach my $exchange_data (@$prices) {
        my $exchange = $exchange_data->{exchange};
        my $exchange_lower = lc($exchange);
        my $exchange_depth = $depth->{$exchange} || {};
        my $exchange_metrics = $metrics->{$exchange} || {};

        my $spread_class = '';
        if ($exchange_data->{spread_percent} >= 3) {
            $spread_class = 'negative';
        } elsif ($exchange_data->{spread_percent} >= 1.5) {
            $spread_class = 'warning';
        }

        my $change_class = $exchange_data->{price_change_percent_24h} >= 0 ? 'positive' : 'negative';
        my $change_sign = $exchange_data->{price_change_percent_24h} >= 0 ? '+' : '';

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

                <div class="metrics-grid">
                    <div class="metric-box">
                        <div class="metric-label">Price</div>
                        <div class="metric-value">\$} . sprintf("%.4f", $exchange_data->{price}) . qq{</div>
                        <div class="metric-change $change_class">$change_sign} . sprintf("%.2f", $exchange_data->{price_change_percent_24h}) . qq{%</div>
                    </div>
                    <div class="metric-box">
                        <div class="metric-label">Spread</div>
                        <div class="metric-value $spread_class">} . sprintf("%.2f", $exchange_data->{spread_percent}) . qq{%</div>
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

                <table class="depth-table">
                    <thead>
                        <tr>
                            <th>Depth Level</th>
                            <th>Bid Depth</th>
                            <th>Ask Depth</th>
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

        print qq{
                    </tbody>
                </table>
            </div>
        </div>
        };
    }

    # If no exchange data
    unless (@$prices) {
        print qq{
        <div class="card exchange-card">
            <div class="card-body">
                <div class="empty-state">
                    <div class="empty-state-icon">📊</div>
                    <p>No market data available yet. Run the monitor script to collect data.</p>
                </div>
            </div>
        </div>
        };
    }

    # Recommendations Card
    print qq{
        <div class="card recommendations-card">
            <div class="card-header">
                <div class="card-title">Trading Recommendations</div>
                <span class="card-badge" style="background: var(--bg-tertiary);">} . scalar(@$recommendations) . qq{ Active</span>
            </div>
            <div class="card-body">
    };

    if (@$recommendations) {
        print qq{<div class="recommendation-list">};
        foreach my $rec (@$recommendations) {
            my $priority_class = $rec->{priority} >= 8 ? 'priority-high' :
                                 $rec->{priority} >= 5 ? 'priority-medium' : 'priority-low';

            my $icon = '💡';
            if ($rec->{action} eq 'PULL_LIQUIDITY') {
                $icon = '⚠️';
            } elsif ($rec->{action} eq 'ADD_LIQUIDITY') {
                $icon = '💰';
            } elsif ($rec->{action} eq 'TIGHTEN_SPREAD') {
                $icon = '📉';
            } elsif ($rec->{action} eq 'REDUCE_EXPOSURE') {
                $icon = '🛡️';
            }

            print qq{
                <div class="recommendation-item $priority_class">
                    <div class="recommendation-icon">$icon</div>
                    <div class="recommendation-content">
                        <div class="recommendation-action">$rec->{action}</div>
                        <div class="recommendation-reason">$rec->{reason}</div>
                        <div class="recommendation-meta">
                            <span>Exchange: } . ($rec->{exchange} || 'All') . qq{</span>
                            <span>Priority: $rec->{priority}/10</span>
                            <span>Created: $rec->{created_at}</span>
                        </div>
                    </div>
                </div>
            };
        }
        print qq{</div>};
    } else {
        print qq{
            <div class="empty-state">
                <div class="empty-state-icon">✅</div>
                <p>No active recommendations. Market conditions are within normal parameters.</p>
            </div>
        };
    }

    print qq{
            </div>
        </div>
    };

    # Recent Alerts Card
    print qq{
        <div class="card alerts-card">
            <div class="card-header">
                <div class="card-title">Recent Alerts (24h)</div>
            </div>
            <div class="card-body">
                <div class="alert-list">
    };

    if (@$alerts) {
        foreach my $alert (splice(@$alerts, 0, 10)) {
            print qq{
                    <div class="alert-item">
                        <div class="alert-severity $alert->{severity}"></div>
                        <div class="alert-content">
                            <div class="alert-message">$alert->{message}</div>
                            <div class="alert-time">$alert->{created_at}</div>
                        </div>
                    </div>
            };
        }
    } else {
        print qq{
                    <div class="empty-state">
                        <p>No alerts in the last 24 hours</p>
                    </div>
        };
    }

    print qq{
                </div>
            </div>
        </div>
    };

    # Trading Tips Card
    print qq{
        <div class="card alerts-card">
            <div class="card-header">
                <div class="card-title">Market Making Tips</div>
            </div>
            <div class="card-body">
                <div class="recommendation-list">
                    <div class="recommendation-item priority-low">
                        <div class="recommendation-icon">📈</div>
                        <div class="recommendation-content">
                            <div class="recommendation-action">Watch for Volume Spikes</div>
                            <div class="recommendation-reason">Large volume increases often precede price movements. Consider widening spreads during high volume periods to protect against adverse selection.</div>
                        </div>
                    </div>
                    <div class="recommendation-item priority-low">
                        <div class="recommendation-icon">⏰</div>
                        <div class="recommendation-content">
                            <div class="recommendation-action">Time Zone Awareness</div>
                            <div class="recommendation-reason">Liquidity typically decreases during Asian trading hours (UTC+8). Consider reducing position sizes during low liquidity periods.</div>
                        </div>
                    </div>
                    <div class="recommendation-item priority-low">
                        <div class="recommendation-icon">🔄</div>
                        <div class="recommendation-content">
                            <div class="recommendation-action">Cross-Exchange Arbitrage</div>
                            <div class="recommendation-reason">Monitor price differences between KuCoin and MEXC. Consistent spreads >0.5% may indicate arbitrage opportunities or liquidity imbalances.</div>
                        </div>
                    </div>
                    <div class="recommendation-item priority-low">
                        <div class="recommendation-icon">🛡️</div>
                        <div class="recommendation-content">
                            <div class="recommendation-action">Inventory Management</div>
                            <div class="recommendation-reason">Maintain balanced ERG/USDT ratios (ideally 50/50 by value). Skewed inventory increases directional risk.</div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    };

    print qq{</div>};
}

sub render_alerts_tab {
    my ($alerts) = @_;

    print qq{
        <div class="dashboard-grid">
            <div class="card" style="grid-column: span 12;">
                <div class="card-header">
                    <div class="card-title">Alert History (Last 24 Hours)</div>
                </div>
                <div class="card-body">
    };

    if (@$alerts) {
        print qq{<div class="alert-list" style="max-height: none;">};
        foreach my $alert (@$alerts) {
            my $details = '';
            if ($alert->{details} && $alert->{details} ne '{}') {
                $details = $alert->{details};
            }

            print qq{
                    <div class="alert-item">
                        <div class="alert-severity $alert->{severity}"></div>
                        <div class="alert-content">
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
        print qq{
            <div class="empty-state">
                <div class="empty-state-icon">🔔</div>
                <p>No alerts recorded in the last 24 hours.</p>
            </div>
        };
    }

    print qq{
                </div>
            </div>
        </div>
    };
}

sub render_settings_tab {
    my ($config) = @_;

    print qq{
        <div class="dashboard-grid">
            <div class="card" style="grid-column: span 12;">
                <div class="card-header">
                    <div class="card-title">Dashboard Settings</div>
                </div>
                <div class="card-body">
                    <form method="POST" action="?tab=settings&action=save">
                        <div class="settings-grid">
                            <div class="setting-group">
                                <h3>Discord Notifications</h3>
                                <div class="setting-item">
                                    <label class="setting-label">Discord Webhook URL</label>
                                    <input type="text" name="discord_webhook" class="setting-input"
                                           value="} . ($config->{discord_webhook}{value} || '') . qq{"
                                           placeholder="https://discord.com/api/webhooks/...">
                                    <div class="setting-description">Webhook URL for Discord alerts</div>
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">Alert Cooldown (minutes)</label>
                                    <input type="number" name="alert_cooldown_minutes" class="setting-input"
                                           value="} . ($config->{alert_cooldown_minutes}{value} || '30') . qq{">
                                    <div class="setting-description">Minimum time between repeat alerts of same type</div>
                                </div>
                            </div>

                            <div class="setting-group">
                                <h3>Spread Thresholds</h3>
                                <div class="setting-item">
                                    <label class="setting-label">Warning Threshold (%)</label>
                                    <input type="number" step="0.1" name="spread_warning_threshold" class="setting-input"
                                           value="} . ($config->{spread_warning_threshold}{value} || '1.5') . qq{">
                                    <div class="setting-description">Spread % to trigger warning alert</div>
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">Critical Threshold (%)</label>
                                    <input type="number" step="0.1" name="spread_critical_threshold" class="setting-input"
                                           value="} . ($config->{spread_critical_threshold}{value} || '3.0') . qq{">
                                    <div class="setting-description">Spread % to trigger critical alert</div>
                                </div>
                            </div>

                            <div class="setting-group">
                                <h3>Depth Thresholds</h3>
                                <div class="setting-item">
                                    <label class="setting-label">Warning Threshold (USD)</label>
                                    <input type="number" name="depth_warning_threshold" class="setting-input"
                                           value="} . ($config->{depth_warning_threshold}{value} || '5000') . qq{">
                                    <div class="setting-description">Minimum depth at 2% before warning</div>
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">Critical Threshold (USD)</label>
                                    <input type="number" name="depth_critical_threshold" class="setting-input"
                                           value="} . ($config->{depth_critical_threshold}{value} || '2000') . qq{">
                                    <div class="setting-description">Minimum depth at 2% before critical alert</div>
                                </div>
                            </div>

                            <div class="setting-group">
                                <h3>Volatility Thresholds</h3>
                                <div class="setting-item">
                                    <label class="setting-label">Price Change Warning (%)</label>
                                    <input type="number" step="0.1" name="price_change_warning" class="setting-input"
                                           value="} . ($config->{price_change_warning}{value} || '5.0') . qq{">
                                    <div class="setting-description">24h price change % for warning</div>
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">Price Change Critical (%)</label>
                                    <input type="number" step="0.1" name="price_change_critical" class="setting-input"
                                           value="} . ($config->{price_change_critical}{value} || '10.0') . qq{">
                                    <div class="setting-description">24h price change % for critical alert</div>
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">Liquidity Pull Threshold (%)</label>
                                    <input type="number" step="0.1" name="liquidity_pull_threshold" class="setting-input"
                                           value="} . ($config->{liquidity_pull_threshold}{value} || '15.0') . qq{">
                                    <div class="setting-description">Volatility % to recommend pulling liquidity</div>
                                </div>
                            </div>

                            <div class="setting-group">
                                <h3>Exchange Monitoring</h3>
                                <div class="setting-item">
                                    <label class="setting-label">Monitor KuCoin</label>
                                    <select name="kucoin_enabled" class="setting-input">
                                        <option value="1" } . ($config->{kucoin_enabled}{value} eq '1' ? 'selected' : '') . qq{>Enabled</option>
                                        <option value="0" } . ($config->{kucoin_enabled}{value} eq '0' ? 'selected' : '') . qq{>Disabled</option>
                                    </select>
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">Monitor MEXC</label>
                                    <select name="mexc_enabled" class="setting-input">
                                        <option value="1" } . ($config->{mexc_enabled}{value} eq '1' ? 'selected' : '') . qq{>Enabled</option>
                                        <option value="0" } . ($config->{mexc_enabled}{value} eq '0' ? 'selected' : '') . qq{>Disabled</option>
                                    </select>
                                </div>
                                <div class="setting-item">
                                    <label class="setting-label">Monitoring Enabled</label>
                                    <select name="monitoring_enabled" class="setting-input">
                                        <option value="1" } . ($config->{monitoring_enabled}{value} eq '1' ? 'selected' : '') . qq{>Enabled</option>
                                        <option value="0" } . ($config->{monitoring_enabled}{value} eq '0' ? 'selected' : '') . qq{>Disabled</option>
                                    </select>
                                </div>
                            </div>

                            <div class="setting-group">
                                <h3>Volume Alerts</h3>
                                <div class="setting-item">
                                    <label class="setting-label">Volume Spike Multiplier</label>
                                    <input type="number" step="0.1" name="volume_spike_threshold" class="setting-input"
                                           value="} . ($config->{volume_spike_threshold}{value} || '3.0') . qq{">
                                    <div class="setting-description">Volume vs 24h average to flag as spike (e.g., 3.0 = 3x average)</div>
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

    # Get session cookie
    my %cookies = CGI::Cookie->fetch();
    my $session_id = $cookies{'ergo_mm_session'} ? $cookies{'ergo_mm_session'}->value() : undef;

    # Handle logout
    if ($q->param('logout')) {
        destroy_session($dbh, $session_id) if $session_id;
        my $cookie = CGI::Cookie->new(
            -name => 'ergo_mm_session',
            -value => '',
            -expires => '-1d'
        );
        print $q->redirect(-uri => $q->url(), -cookie => $cookie);
        return;
    }

    # Handle login POST
    if ($q->request_method() eq 'POST' && !validate_session($dbh, $session_id)) {
        my $password = $q->param('password');

        if ($password eq $DASHBOARD_PASSWORD) {
            $session_id = create_session($dbh, $ENV{REMOTE_ADDR} || '0.0.0.0');
            my $cookie = CGI::Cookie->new(
                -name => 'ergo_mm_session',
                -value => $session_id,
                -expires => '+24h',
                -httponly => 1
            );
            print $q->redirect(-uri => $q->url(), -cookie => $cookie);
            return;
        } else {
            render_login_page('Invalid password. Please try again.');
            return;
        }
    }

    # Check authentication
    unless (validate_session($dbh, $session_id)) {
        render_login_page();
        return;
    }

    # Handle settings save
    if ($q->param('action') eq 'save' && $q->request_method() eq 'POST') {
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

    # Render dashboard
    my $tab = $q->param('tab') || 'overview';
    render_dashboard($dbh, $tab);

    $dbh->disconnect();
}

main();

1;

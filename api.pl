#!/usr/bin/perl
# ============================================================
# ERGO Market Maker API
# JSON API endpoints for dashboard data
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
# SESSION VALIDATION
# ============================================================
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

# ============================================================
# API RESPONSE HELPERS
# ============================================================
sub json_response {
    my ($data, $status) = @_;
    $status ||= 200;

    my %status_text = (
        200 => 'OK',
        400 => 'Bad Request',
        401 => 'Unauthorized',
        404 => 'Not Found',
        500 => 'Internal Server Error'
    );

    print "Content-type: application/json\n";
    print "Access-Control-Allow-Origin: *\n";
    print "Cache-Control: no-cache\n\n";

    print encode_json($data);
}

sub error_response {
    my ($message, $status) = @_;
    $status ||= 400;
    json_response({ error => $message, status => $status }, $status);
}

# ============================================================
# API ENDPOINTS
# ============================================================
sub get_overview {
    my ($dbh) = @_;

    my %data;

    # Latest prices
    my $sth = $dbh->prepare("SELECT * FROM v_latest_prices ORDER BY exchange");
    $sth->execute();
    $data{prices} = $sth->fetchall_arrayref({});
    $sth->finish();

    # Latest depth
    $sth = $dbh->prepare("SELECT * FROM v_latest_depth ORDER BY exchange, depth_level");
    $sth->execute();
    my @depth_rows = @{$sth->fetchall_arrayref({})};
    my %depth;
    foreach my $row (@depth_rows) {
        $depth{$row->{exchange}}{$row->{depth_level}} = $row;
    }
    $data{depth} = \%depth;
    $sth->finish();

    # Latest metrics
    $sth = $dbh->prepare("SELECT * FROM v_latest_metrics ORDER BY exchange");
    $sth->execute();
    my @metrics_rows = @{$sth->fetchall_arrayref({})};
    my %metrics;
    foreach my $row (@metrics_rows) {
        $metrics{$row->{exchange}} = $row;
    }
    $data{metrics} = \%metrics;
    $sth->finish();

    # Active recommendations
    $sth = $dbh->prepare("SELECT * FROM v_active_recommendations LIMIT 10");
    $sth->execute();
    $data{recommendations} = $sth->fetchall_arrayref({});
    $sth->finish();

    # Recent alerts count by severity
    $sth = $dbh->prepare(qq{
        SELECT severity, COUNT(*) as count
        FROM alerts_log
        WHERE created_at > DATE_SUB(NOW(), INTERVAL 24 HOUR)
        GROUP BY severity
    });
    $sth->execute();
    my %alert_counts;
    while (my $row = $sth->fetchrow_hashref()) {
        $alert_counts{$row->{severity}} = $row->{count};
    }
    $data{alert_counts} = \%alert_counts;
    $sth->finish();

    # On-chain exchange flows (skipped gracefully if sql/add_flow_tables.sql has not been applied)
    my $flows = do {
        local $dbh->{PrintError} = 0;
        eval { { summary => get_flow_summary($dbh), reserves => get_flow_reserves($dbh) } };
    };
    $data{flows} = $flows if $flows;

    $data{timestamp} = strftime("%Y-%m-%d %H:%M:%S", localtime());

    return \%data;
}

sub get_prices {
    my ($dbh, $exchange, $hours) = @_;
    $hours ||= 24;

    my $sql = qq{
        SELECT
            exchange,
            DATE_FORMAT(timestamp, '%Y-%m-%d %H:%i:00') as time,
            AVG(price) as price,
            AVG(spread_percent) as spread,
            AVG(bid_price) as bid,
            AVG(ask_price) as ask,
            MAX(high_24h) as high,
            MIN(low_24h) as low
        FROM price_data
        WHERE timestamp > DATE_SUB(NOW(), INTERVAL ? HOUR)
    };

    if ($exchange) {
        $sql .= " AND exchange = ?";
    }

    $sql .= " GROUP BY exchange, time ORDER BY exchange, time";

    my $sth = $dbh->prepare($sql);
    if ($exchange) {
        $sth->execute($hours, uc($exchange));
    } else {
        $sth->execute($hours);
    }

    my $data = $sth->fetchall_arrayref({});
    $sth->finish();

    return { prices => $data, hours => $hours, exchange => $exchange || 'all' };
}

sub get_depth_history {
    my ($dbh, $exchange, $hours) = @_;
    $hours ||= 24;

    my $sql = qq{
        SELECT
            exchange,
            depth_level,
            DATE_FORMAT(timestamp, '%Y-%m-%d %H:%i:00') as time,
            AVG(bid_depth_usd) as bid_depth,
            AVG(ask_depth_usd) as ask_depth
        FROM orderbook_depth
        WHERE timestamp > DATE_SUB(NOW(), INTERVAL ? HOUR)
    };

    if ($exchange) {
        $sql .= " AND exchange = ?";
    }

    $sql .= " GROUP BY exchange, depth_level, time ORDER BY exchange, depth_level, time";

    my $sth = $dbh->prepare($sql);
    if ($exchange) {
        $sth->execute($hours, uc($exchange));
    } else {
        $sth->execute($hours);
    }

    my $data = $sth->fetchall_arrayref({});
    $sth->finish();

    return { depth => $data, hours => $hours, exchange => $exchange || 'all' };
}

sub get_alerts {
    my ($dbh, $hours, $severity) = @_;
    $hours ||= 24;

    my $sql = qq{
        SELECT *
        FROM alerts_log
        WHERE created_at > DATE_SUB(NOW(), INTERVAL ? HOUR)
    };

    if ($severity) {
        $sql .= " AND severity = ?";
    }

    $sql .= " ORDER BY created_at DESC LIMIT 100";

    my $sth = $dbh->prepare($sql);
    if ($severity) {
        $sth->execute($hours, $severity);
    } else {
        $sth->execute($hours);
    }

    my $data = $sth->fetchall_arrayref({});
    $sth->finish();

    return { alerts => $data, hours => $hours, severity => $severity || 'all' };
}

sub get_trades {
    my ($dbh, $exchange, $hours) = @_;
    $hours ||= 24;

    my $sql = qq{
        SELECT
            exchange,
            COUNT(*) as trade_count,
            SUM(amount) as total_erg,
            SUM(amount_usd) as total_usd,
            SUM(CASE WHEN side = 'buy' THEN amount_usd ELSE 0 END) as buy_volume,
            SUM(CASE WHEN side = 'sell' THEN amount_usd ELSE 0 END) as sell_volume,
            AVG(price) as avg_price,
            MIN(price) as min_price,
            MAX(price) as max_price
        FROM trades
        WHERE trade_time > DATE_SUB(NOW(), INTERVAL ? HOUR)
    };

    if ($exchange) {
        $sql .= " AND exchange = ?";
    }

    $sql .= " GROUP BY exchange";

    my $sth = $dbh->prepare($sql);
    if ($exchange) {
        $sth->execute($hours, uc($exchange));
    } else {
        $sth->execute($hours);
    }

    my $data = $sth->fetchall_arrayref({});
    $sth->finish();

    return { trades => $data, hours => $hours, exchange => $exchange || 'all' };
}

sub get_recommendations {
    my ($dbh) = @_;

    my $sth = $dbh->prepare("SELECT * FROM v_active_recommendations");
    $sth->execute();
    my $data = $sth->fetchall_arrayref({});
    $sth->finish();

    return { recommendations => $data };
}

# ------------------------------------------------------------
# On-chain exchange flows (ERG in/out of exchange wallets)
# ------------------------------------------------------------
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
    my %summary;
    while (my $row = $sth->fetchrow_hashref()) {
        foreach my $window ('1h', '6h', '24h') {
            $row->{"in_$window"}  += 0;
            $row->{"out_$window"} += 0;
            $row->{"net_$window"} = $row->{"in_$window"} - $row->{"out_$window"};
        }
        $summary{$row->{exchange}} = $row;
    }
    $sth->finish();
    return \%summary;
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
    my %reserves;
    while (my $row = $sth->fetchrow_hashref()) {
        my $ex = $reserves{$row->{exchange}} ||= { total_erg => 0, addresses => [], updated => undef };
        $ex->{total_erg} += $row->{balance_erg};
        push @{$ex->{addresses}}, $row;
        $ex->{updated} = $row->{timestamp} if !defined $ex->{updated} || $row->{timestamp} gt $ex->{updated};
    }
    $sth->finish();
    return \%reserves;
}

sub get_flows {
    my ($dbh, $exchange, $hours) = @_;
    $hours ||= 24;

    my %data = (
        summary  => get_flow_summary($dbh),
        reserves => get_flow_reserves($dbh),
    );

    # Individual on-chain transfers
    my $sql = qq{
        SELECT exchange, tx_id, direction, amount_erg, amount_usd, price_usd, counterparty, block_height, tx_time
        FROM exchange_flows
        WHERE tx_time > DATE_SUB(NOW(), INTERVAL ? HOUR)
    };
    $sql .= " AND exchange = ?" if $exchange;
    $sql .= " ORDER BY tx_time DESC LIMIT 500";
    my $sth = $dbh->prepare($sql);
    $exchange ? $sth->execute($hours, uc($exchange)) : $sth->execute($hours);
    $data{transfers} = $sth->fetchall_arrayref({});
    $sth->finish();

    # Your own deposits / withdrawals (from the exchange account APIs)
    $sql = qq{
        SELECT exchange, direction, transfer_id, amount_erg, fee_erg, status, address, tx_id, tx_time
        FROM user_transfers
        WHERE 1 = 1
    };
    $sql .= " AND exchange = ?" if $exchange;
    $sql .= " ORDER BY tx_time DESC LIMIT 100";
    $sth = $dbh->prepare($sql);
    $exchange ? $sth->execute(uc($exchange)) : $sth->execute();
    $data{user_transfers} = $sth->fetchall_arrayref({});
    $sth->finish();

    $data{hours} = $hours;
    $data{exchange} = $exchange || 'all';
    return \%data;
}

sub get_health {
    my ($dbh) = @_;

    my %health;

    # Check last data update times
    my $sth = $dbh->prepare(qq{
        SELECT exchange, MAX(timestamp) as last_update
        FROM price_data
        GROUP BY exchange
    });
    $sth->execute();
    my %last_updates;
    while (my $row = $sth->fetchrow_hashref()) {
        $last_updates{$row->{exchange}} = $row->{last_update};
    }
    $health{last_updates} = \%last_updates;
    $sth->finish();

    # Check if monitoring is working (data within last 10 minutes)
    $sth = $dbh->prepare(qq{
        SELECT COUNT(*) as count FROM price_data
        WHERE timestamp > DATE_SUB(NOW(), INTERVAL 10 MINUTE)
    });
    $sth->execute();
    my ($recent_count) = $sth->fetchrow_array();
    $health{monitoring_active} = $recent_count > 0 ? 1 : 0;
    $sth->finish();

    # Seconds since the newest price sample (what the dashboard's Live/Stale badge uses)
    $sth = $dbh->prepare("SELECT TIMESTAMPDIFF(SECOND, MAX(timestamp), NOW()) FROM price_data");
    $sth->execute();
    ($health{data_age_seconds}) = $sth->fetchrow_array();
    $sth->finish();

    # Get config status
    $sth = $dbh->prepare("SELECT config_value FROM config WHERE config_key = 'monitoring_enabled'");
    $sth->execute();
    my ($monitoring_enabled) = $sth->fetchrow_array();
    $health{monitoring_enabled} = $monitoring_enabled eq '1' ? 1 : 0;
    $sth->finish();

    # Database stats
    $sth = $dbh->prepare(qq{
        SELECT
            (SELECT COUNT(*) FROM price_data) as price_records,
            (SELECT COUNT(*) FROM orderbook_depth) as depth_records,
            (SELECT COUNT(*) FROM trades) as trade_records,
            (SELECT COUNT(*) FROM alerts_log) as alert_records
    });
    $sth->execute();
    $health{database_stats} = $sth->fetchrow_hashref();
    $sth->finish();

    $health{timestamp} = strftime("%Y-%m-%d %H:%M:%S", localtime());
    $health{status} = $health{monitoring_active} ? 'healthy' : 'degraded';

    return \%health;
}

# ============================================================
# MAIN CGI HANDLER
# ============================================================
sub main {
    my $q = CGI->new();
    my $dbh = get_db_connection();

    # Get API key or session for authentication
    my %cookies = CGI::Cookie->fetch();
    my $session_id = $cookies{'ergo_mm_session'} ? $cookies{'ergo_mm_session'}->value() : undef;
    my $api_key = $q->param('api_key') || $q->http('X-API-Key');

    # Health endpoint doesn't require auth
    my $endpoint = $q->param('endpoint') || 'overview';

    if ($endpoint eq 'health') {
        my $data = get_health($dbh);
        json_response($data);
        $dbh->disconnect();
        return;
    }

    # All other endpoints require authentication
    my $authenticated = validate_session($dbh, $session_id);

    # Also accept password as API key for simplicity
    if (!$authenticated && $api_key && $api_key eq $DASHBOARD_PASSWORD) {
        $authenticated = 1;
    }

    unless ($authenticated) {
        error_response('Authentication required. Provide valid session or api_key parameter.', 401);
        $dbh->disconnect();
        return;
    }

    # Route to appropriate endpoint
    my $exchange = $q->param('exchange');
    my $hours = $q->param('hours') || 24;
    my $severity = $q->param('severity');

    my $data;

    if ($endpoint eq 'overview') {
        $data = get_overview($dbh);
    }
    elsif ($endpoint eq 'prices') {
        $data = get_prices($dbh, $exchange, $hours);
    }
    elsif ($endpoint eq 'depth') {
        $data = get_depth_history($dbh, $exchange, $hours);
    }
    elsif ($endpoint eq 'alerts') {
        $data = get_alerts($dbh, $hours, $severity);
    }
    elsif ($endpoint eq 'trades') {
        $data = get_trades($dbh, $exchange, $hours);
    }
    elsif ($endpoint eq 'recommendations') {
        $data = get_recommendations($dbh);
    }
    elsif ($endpoint eq 'flows') {
        $data = do { local $dbh->{PrintError} = 0; eval { get_flows($dbh, $exchange, $hours) } };
        unless ($data) {
            error_response("Flow tables not available - apply sql/add_flow_tables.sql ($@)", 500);
            $dbh->disconnect();
            return;
        }
    }
    else {
        error_response("Unknown endpoint: $endpoint", 404);
        $dbh->disconnect();
        return;
    }

    json_response($data);
    $dbh->disconnect();
}

main();

1;

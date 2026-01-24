#!/usr/bin/perl
# ============================================================
# ERGO Market Maker Monitoring Script
# Monitors ERG/USDT on MEXC and KuCoin exchanges
# Designed to run via cron every 1-5 minutes
# ============================================================

use strict;
use warnings;
use DBI;
use LWP::UserAgent;
use JSON;
use POSIX qw(strftime);
use Time::HiRes qw(time);
use Digest::SHA qw(sha256_hex);

# ============================================================
# DATABASE CONNECTION
# ============================================================
sub get_db_connection {
    # Read MySQL password from file
    open my $fh, '<', '/usr/lib/cgi-bin/sql.txt' or die "Can't open password file: $!";
    my $password = do { local $/; <$fh> };
    close $fh;
    $password =~ s/^\s+//;
    $password =~ s/\s+$//;

    my $db = "ergo_mm";
    my $host = "localhost";
    my $user = "root";

    my $dbh = DBI->connect(
        "DBI:mysql:database=$db:host=$host",
        $user,
        $password,
        { RaiseError => 1, AutoCommit => 1, mysql_enable_utf8mb4 => 1 }
    ) or die "Can't connect to database: $DBI::errstr\n";

    return $dbh;
}

# ============================================================
# CONFIGURATION LOADER
# ============================================================
sub load_config {
    my ($dbh) = @_;
    my %config;

    my $sth = $dbh->prepare("SELECT config_key, config_value FROM config");
    $sth->execute();
    while (my $row = $sth->fetchrow_hashref()) {
        $config{$row->{config_key}} = $row->{config_value};
    }
    $sth->finish();

    return \%config;
}

# ============================================================
# HTTP CLIENT
# ============================================================
sub create_http_client {
    my $ua = LWP::UserAgent->new(
        timeout => 30,
        agent => 'ErgoMMBot/1.0',
        ssl_opts => { verify_hostname => 0 }
    );
    return $ua;
}

# ============================================================
# MEXC API FUNCTIONS
# ============================================================
sub fetch_mexc_ticker {
    my ($ua) = @_;
    my $url = 'https://api.mexc.com/api/v3/ticker/24hr?symbol=ERGUSDT';

    my $response = $ua->get($url);
    if ($response->is_success) {
        return decode_json($response->decoded_content);
    }
    warn "MEXC ticker fetch failed: " . $response->status_line;
    return undef;
}

sub fetch_mexc_orderbook {
    my ($ua, $limit) = @_;
    $limit ||= 100;
    my $url = "https://api.mexc.com/api/v3/depth?symbol=ERGUSDT&limit=$limit";

    my $response = $ua->get($url);
    if ($response->is_success) {
        return decode_json($response->decoded_content);
    }
    warn "MEXC orderbook fetch failed: " . $response->status_line;
    return undef;
}

sub fetch_mexc_trades {
    my ($ua, $limit) = @_;
    $limit ||= 100;
    my $url = "https://api.mexc.com/api/v3/trades?symbol=ERGUSDT&limit=$limit";

    my $response = $ua->get($url);
    if ($response->is_success) {
        return decode_json($response->decoded_content);
    }
    warn "MEXC trades fetch failed: " . $response->status_line;
    return undef;
}

# ============================================================
# KUCOIN API FUNCTIONS
# ============================================================
sub fetch_kucoin_ticker {
    my ($ua) = @_;
    my $url = 'https://api.kucoin.com/api/v1/market/stats?symbol=ERG-USDT';

    my $response = $ua->get($url);
    if ($response->is_success) {
        my $data = decode_json($response->decoded_content);
        return $data->{data} if $data->{code} eq '200000';
    }
    warn "KuCoin ticker fetch failed: " . $response->status_line;
    return undef;
}

sub fetch_kucoin_orderbook {
    my ($ua) = @_;
    my $url = 'https://api.kucoin.com/api/v1/market/orderbook/level2_100?symbol=ERG-USDT';

    my $response = $ua->get($url);
    if ($response->is_success) {
        my $data = decode_json($response->decoded_content);
        return $data->{data} if $data->{code} eq '200000';
    }
    warn "KuCoin orderbook fetch failed: " . $response->status_line;
    return undef;
}

sub fetch_kucoin_trades {
    my ($ua) = @_;
    my $url = 'https://api.kucoin.com/api/v1/market/histories?symbol=ERG-USDT';

    my $response = $ua->get($url);
    if ($response->is_success) {
        my $data = decode_json($response->decoded_content);
        return $data->{data} if $data->{code} eq '200000';
    }
    warn "KuCoin trades fetch failed: " . $response->status_line;
    return undef;
}

# ============================================================
# DATA PROCESSING FUNCTIONS
# ============================================================
sub calculate_depth_at_percentage {
    my ($orderbook, $mid_price, $percentage, $side) = @_;

    my $threshold_price;
    if ($side eq 'bid') {
        $threshold_price = $mid_price * (1 - $percentage / 100);
    } else {
        $threshold_price = $mid_price * (1 + $percentage / 100);
    }

    my $orders = $side eq 'bid' ? $orderbook->{bids} : $orderbook->{asks};
    my $total_amount = 0;
    my $total_usd = 0;

    foreach my $order (@$orders) {
        my ($price, $amount) = @$order;
        $price = $price + 0;
        $amount = $amount + 0;

        if ($side eq 'bid') {
            last if $price < $threshold_price;
        } else {
            last if $price > $threshold_price;
        }

        $total_amount += $amount;
        $total_usd += $amount * $price;
    }

    return ($total_amount, $total_usd);
}

sub store_price_data {
    my ($dbh, $exchange, $data) = @_;

    my $sql = qq{
        INSERT INTO price_data
        (exchange, symbol, price, bid_price, ask_price, spread, spread_percent,
         volume_24h, volume_24h_usd, high_24h, low_24h,
         price_change_24h, price_change_percent_24h)
        VALUES (?, 'ERG/USDT', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute(
        $exchange,
        $data->{price},
        $data->{bid_price},
        $data->{ask_price},
        $data->{spread},
        $data->{spread_percent},
        $data->{volume_24h},
        $data->{volume_24h_usd},
        $data->{high_24h},
        $data->{low_24h},
        $data->{price_change_24h},
        $data->{price_change_percent_24h}
    );
    $sth->finish();
}

sub store_orderbook_depth {
    my ($dbh, $exchange, $depth_data) = @_;

    my $sql = qq{
        INSERT INTO orderbook_depth
        (exchange, symbol, depth_level, bid_depth_erg, bid_depth_usd, ask_depth_erg, ask_depth_usd)
        VALUES (?, 'ERG/USDT', ?, ?, ?, ?, ?)
    };

    my $sth = $dbh->prepare($sql);

    foreach my $level (keys %$depth_data) {
        $sth->execute(
            $exchange,
            $level,
            $depth_data->{$level}{bid_erg},
            $depth_data->{$level}{bid_usd},
            $depth_data->{$level}{ask_erg},
            $depth_data->{$level}{ask_usd}
        );
    }
    $sth->finish();
}

sub store_trades {
    my ($dbh, $exchange, $trades, $current_price) = @_;

    my $sql = qq{
        INSERT INTO trades
        (exchange, symbol, trade_id, price, amount, amount_usd, side, trade_time)
        VALUES (?, 'ERG/USDT', ?, ?, ?, ?, ?, FROM_UNIXTIME(?))
        ON DUPLICATE KEY UPDATE trade_id=trade_id
    };

    my $sth = $dbh->prepare($sql);

    foreach my $trade (@$trades) {
        my $trade_time = $trade->{time} / 1000;  # Convert ms to seconds
        my $amount_usd = $trade->{qty} * $trade->{price};

        $sth->execute(
            $exchange,
            $trade->{id} || sha256_hex($trade->{time} . $trade->{price} . $trade->{qty}),
            $trade->{price},
            $trade->{qty},
            $amount_usd,
            $trade->{isBuyerMaker} ? 'sell' : 'buy',
            $trade_time
        );
    }
    $sth->finish();
}

# ============================================================
# METRICS CALCULATION
# ============================================================
sub calculate_and_store_metrics {
    my ($dbh, $exchange) = @_;

    # Calculate 1-hour and 24-hour metrics
    my $sql = qq{
        INSERT INTO market_metrics
        (exchange, symbol, avg_spread_1h, avg_spread_24h, total_volume_1h, total_volume_24h,
         trade_count_1h, trade_count_24h, price_range_24h, volatility_1h)
        SELECT
            ?,
            'ERG/USDT',
            (SELECT AVG(spread_percent) FROM price_data
             WHERE exchange = ? AND timestamp > DATE_SUB(NOW(), INTERVAL 1 HOUR)),
            (SELECT AVG(spread_percent) FROM price_data
             WHERE exchange = ? AND timestamp > DATE_SUB(NOW(), INTERVAL 24 HOUR)),
            (SELECT COALESCE(SUM(amount_usd), 0) FROM trades
             WHERE exchange = ? AND recorded_at > DATE_SUB(NOW(), INTERVAL 1 HOUR)),
            (SELECT COALESCE(SUM(amount_usd), 0) FROM trades
             WHERE exchange = ? AND recorded_at > DATE_SUB(NOW(), INTERVAL 24 HOUR)),
            (SELECT COUNT(*) FROM trades
             WHERE exchange = ? AND recorded_at > DATE_SUB(NOW(), INTERVAL 1 HOUR)),
            (SELECT COUNT(*) FROM trades
             WHERE exchange = ? AND recorded_at > DATE_SUB(NOW(), INTERVAL 24 HOUR)),
            (SELECT COALESCE(
                ((MAX(high_24h) - MIN(low_24h)) / AVG(price)) * 100, 0)
             FROM price_data WHERE exchange = ? AND timestamp > DATE_SUB(NOW(), INTERVAL 24 HOUR)),
            (SELECT COALESCE(STDDEV(price) / AVG(price) * 100, 0)
             FROM price_data WHERE exchange = ? AND timestamp > DATE_SUB(NOW(), INTERVAL 1 HOUR))
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute($exchange, $exchange, $exchange, $exchange, $exchange,
                  $exchange, $exchange, $exchange, $exchange);
    $sth->finish();
}

# ============================================================
# ALERT SYSTEM
# ============================================================
sub check_alert_cooldown {
    my ($dbh, $alert_type, $cooldown_minutes) = @_;

    my $sql = qq{
        SELECT COUNT(*) FROM alerts_log
        WHERE alert_type = ?
        AND created_at > DATE_SUB(NOW(), INTERVAL ? MINUTE)
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute($alert_type, $cooldown_minutes);
    my ($count) = $sth->fetchrow_array();
    $sth->finish();

    return $count == 0;  # Return true if no recent alerts (cooldown passed)
}

sub log_alert {
    my ($dbh, $alert_type, $severity, $exchange, $message, $details, $discord_sent) = @_;

    my $sql = qq{
        INSERT INTO alerts_log
        (alert_type, severity, exchange, message, details, discord_sent)
        VALUES (?, ?, ?, ?, ?, ?)
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute(
        $alert_type,
        $severity,
        $exchange,
        $message,
        encode_json($details || {}),
        $discord_sent || 0
    );
    $sth->finish();
}

sub send_discord_alert {
    my ($webhook_url, $title, $message, $severity, $fields, $exchange) = @_;

    return 0 unless $webhook_url && $webhook_url =~ /^https:\/\/discord/;

    my $ua = create_http_client();

    # Color based on severity
    my %colors = (
        'info'     => 3447003,   # Blue
        'warning'  => 16776960,  # Yellow
        'critical' => 15158332,  # Red
        'success'  => 3066993,   # Green
    );

    my $color = $colors{$severity} || 3447003;

    my $embed = {
        title       => $title,
        description => $message,
        color       => $color,
        timestamp   => strftime("%Y-%m-%dT%H:%M:%SZ", gmtime()),
        footer      => {
            text => "ERGO MM Monitor" . ($exchange ? " - $exchange" : "")
        }
    };

    if ($fields && @$fields) {
        $embed->{fields} = $fields;
    }

    my $payload = {
        username   => 'ERGO MM Bot',
        avatar_url => 'https://ergoplatform.org/img/logo_ergo_platform.svg',
        embeds     => [$embed]
    };

    my $response = $ua->post(
        $webhook_url,
        Content_Type => 'application/json',
        Content      => encode_json($payload)
    );

    return $response->is_success ? 1 : 0;
}

# ============================================================
# RECOMMENDATION ENGINE
# ============================================================
sub add_recommendation {
    my ($dbh, $exchange, $type, $action, $reason, $priority, $expires_hours) = @_;

    # First, deactivate any existing recommendation of this type for this exchange
    my $deactivate_sql = qq{
        UPDATE recommendations SET is_active = 0
        WHERE exchange = ? AND recommendation_type = ? AND is_active = 1
    };
    my $sth = $dbh->prepare($deactivate_sql);
    $sth->execute($exchange || 'ALL', $type);
    $sth->finish();

    # Add new recommendation
    my $insert_sql = qq{
        INSERT INTO recommendations
        (exchange, recommendation_type, action, reason, priority, expires_at)
        VALUES (?, ?, ?, ?, ?, ?)
    };

    my $expires_at = $expires_hours ?
        strftime("%Y-%m-%d %H:%M:%S", localtime(time + $expires_hours * 3600)) : undef;

    $sth = $dbh->prepare($insert_sql);
    $sth->execute($exchange, $type, $action, $reason, $priority, $expires_at);
    $sth->finish();
}

sub analyze_and_recommend {
    my ($dbh, $config, $exchange, $price_data, $depth_data) = @_;

    my @alerts;
    my @recommendations;

    # Check spread
    if ($price_data->{spread_percent}) {
        if ($price_data->{spread_percent} >= $config->{spread_critical_threshold}) {
            push @alerts, {
                type     => 'SPREAD_CRITICAL',
                severity => 'critical',
                message  => sprintf("CRITICAL: %s spread at %.2f%% (threshold: %.2f%%)",
                    $exchange, $price_data->{spread_percent}, $config->{spread_critical_threshold}),
                fields   => [
                    { name => 'Current Spread', value => sprintf("%.4f%%", $price_data->{spread_percent}), inline => 'true' },
                    { name => 'Bid', value => sprintf("\$%.4f", $price_data->{bid_price}), inline => 'true' },
                    { name => 'Ask', value => sprintf("\$%.4f", $price_data->{ask_price}), inline => 'true' }
                ]
            };
            add_recommendation($dbh, $exchange, 'SPREAD', 'TIGHTEN_SPREAD',
                'Spread is critically wide. Consider adjusting market maker parameters.', 9, 2);
        }
        elsif ($price_data->{spread_percent} >= $config->{spread_warning_threshold}) {
            push @alerts, {
                type     => 'SPREAD_WARNING',
                severity => 'warning',
                message  => sprintf("WARNING: %s spread at %.2f%% (threshold: %.2f%%)",
                    $exchange, $price_data->{spread_percent}, $config->{spread_warning_threshold}),
                fields   => [
                    { name => 'Current Spread', value => sprintf("%.4f%%", $price_data->{spread_percent}), inline => 'true' }
                ]
            };
        }
    }

    # Check depth at 2% level
    my $depth_2pct = $depth_data->{'2%'};
    if ($depth_2pct) {
        my $total_depth = ($depth_2pct->{bid_usd} || 0) + ($depth_2pct->{ask_usd} || 0);

        if ($total_depth < $config->{depth_critical_threshold}) {
            push @alerts, {
                type     => 'DEPTH_CRITICAL',
                severity => 'critical',
                message  => sprintf("CRITICAL: %s depth at 2%% only \$%.2f (threshold: \$%s)",
                    $exchange, $total_depth, $config->{depth_critical_threshold}),
                fields   => [
                    { name => 'Bid Depth', value => sprintf("\$%.2f", $depth_2pct->{bid_usd}), inline => 'true' },
                    { name => 'Ask Depth', value => sprintf("\$%.2f", $depth_2pct->{ask_usd}), inline => 'true' }
                ]
            };
            add_recommendation($dbh, $exchange, 'DEPTH', 'ADD_LIQUIDITY',
                'Orderbook depth is critically low. Add more liquidity to protect against slippage.', 10, 1);
        }
        elsif ($total_depth < $config->{depth_warning_threshold}) {
            push @alerts, {
                type     => 'DEPTH_WARNING',
                severity => 'warning',
                message  => sprintf("WARNING: %s depth at 2%% is \$%.2f (threshold: \$%s)",
                    $exchange, $total_depth, $config->{depth_warning_threshold}),
                fields   => [
                    { name => 'Total Depth', value => sprintf("\$%.2f", $total_depth), inline => 'true' }
                ]
            };
        }
    }

    # Check price volatility
    if (abs($price_data->{price_change_percent_24h} || 0) >= $config->{liquidity_pull_threshold}) {
        my $direction = $price_data->{price_change_percent_24h} > 0 ? 'up' : 'down';
        push @alerts, {
            type     => 'VOLATILITY_EXTREME',
            severity => 'critical',
            message  => sprintf("EXTREME VOLATILITY: %s price moved %.2f%% in 24h - Consider pulling liquidity!",
                $exchange, $price_data->{price_change_percent_24h}),
            fields   => [
                { name => 'Price Change', value => sprintf("%.2f%% %s", abs($price_data->{price_change_percent_24h}), $direction), inline => 'true' },
                { name => 'Current Price', value => sprintf("\$%.4f", $price_data->{price}), inline => 'true' },
                { name => '24h High', value => sprintf("\$%.4f", $price_data->{high_24h}), inline => 'true' },
                { name => '24h Low', value => sprintf("\$%.4f", $price_data->{low_24h}), inline => 'true' }
            ]
        };
        add_recommendation($dbh, $exchange, 'VOLATILITY', 'PULL_LIQUIDITY',
            sprintf('Extreme price movement (%.2f%%). Pull liquidity to protect against losses.', $price_data->{price_change_percent_24h}),
            10, 4);
    }
    elsif (abs($price_data->{price_change_percent_24h} || 0) >= $config->{price_change_critical}) {
        push @alerts, {
            type     => 'PRICE_CHANGE_HIGH',
            severity => 'warning',
            message  => sprintf("HIGH VOLATILITY: %s price changed %.2f%% in 24h",
                $exchange, $price_data->{price_change_percent_24h}),
            fields   => [
                { name => 'Price Change', value => sprintf("%.2f%%", $price_data->{price_change_percent_24h}), inline => 'true' }
            ]
        };
        add_recommendation($dbh, $exchange, 'VOLATILITY', 'REDUCE_EXPOSURE',
            'High volatility detected. Consider reducing position sizes.', 7, 6);
    }

    return \@alerts;
}

# ============================================================
# MAIN MONITORING FUNCTION
# ============================================================
sub process_mexc {
    my ($dbh, $ua, $config) = @_;

    print "Processing MEXC...\n";

    # Fetch data
    my $ticker = fetch_mexc_ticker($ua);
    my $orderbook = fetch_mexc_orderbook($ua, 100);
    my $trades = fetch_mexc_trades($ua, 100);

    return unless $ticker && $orderbook;

    # Calculate mid price
    my $bid_price = $orderbook->{bids}[0][0] + 0;
    my $ask_price = $orderbook->{asks}[0][0] + 0;
    my $mid_price = ($bid_price + $ask_price) / 2;
    my $spread = $ask_price - $bid_price;
    my $spread_percent = ($spread / $mid_price) * 100;

    # Price data
    my $price_data = {
        price                    => $ticker->{lastPrice} + 0,
        bid_price                => $bid_price,
        ask_price                => $ask_price,
        spread                   => $spread,
        spread_percent           => $spread_percent,
        volume_24h               => $ticker->{volume} + 0,
        volume_24h_usd           => $ticker->{quoteVolume} + 0,
        high_24h                 => $ticker->{highPrice} + 0,
        low_24h                  => $ticker->{lowPrice} + 0,
        price_change_24h         => $ticker->{priceChange} + 0,
        price_change_percent_24h => $ticker->{priceChangePercent} + 0,
    };

    store_price_data($dbh, 'MEXC', $price_data);

    # Calculate depth at various levels
    my %depth_data;
    foreach my $pct (2, 5, 10) {
        my ($bid_erg, $bid_usd) = calculate_depth_at_percentage($orderbook, $mid_price, $pct, 'bid');
        my ($ask_erg, $ask_usd) = calculate_depth_at_percentage($orderbook, $mid_price, $pct, 'ask');
        $depth_data{"$pct%"} = {
            bid_erg => $bid_erg,
            bid_usd => $bid_usd,
            ask_erg => $ask_erg,
            ask_usd => $ask_usd
        };
    }

    store_orderbook_depth($dbh, 'MEXC', \%depth_data);

    # Store trades if available
    if ($trades && @$trades) {
        store_trades($dbh, 'MEXC', $trades, $price_data->{price});
    }

    # Calculate metrics
    calculate_and_store_metrics($dbh, 'MEXC');

    # Analyze and generate alerts
    my $alerts = analyze_and_recommend($dbh, $config, 'MEXC', $price_data, \%depth_data);

    return $alerts;
}

sub process_kucoin {
    my ($dbh, $ua, $config) = @_;

    print "Processing KuCoin...\n";

    # Fetch data
    my $ticker = fetch_kucoin_ticker($ua);
    my $orderbook = fetch_kucoin_orderbook($ua);
    my $trades = fetch_kucoin_trades($ua);

    return unless $ticker && $orderbook;

    # Convert orderbook format
    my @bids = map { [$_->[0] + 0, $_->[1] + 0] } @{$orderbook->{bids}};
    my @asks = map { [$_->[0] + 0, $_->[1] + 0] } @{$orderbook->{asks}};
    my $formatted_orderbook = { bids => \@bids, asks => \@asks };

    # Calculate mid price
    my $bid_price = $bids[0][0];
    my $ask_price = $asks[0][0];
    my $mid_price = ($bid_price + $ask_price) / 2;
    my $spread = $ask_price - $bid_price;
    my $spread_percent = ($spread / $mid_price) * 100;

    # Price data
    my $price_data = {
        price                    => $ticker->{last} + 0,
        bid_price                => $bid_price,
        ask_price                => $ask_price,
        spread                   => $spread,
        spread_percent           => $spread_percent,
        volume_24h               => $ticker->{vol} + 0,
        volume_24h_usd           => $ticker->{volValue} + 0,
        high_24h                 => $ticker->{high} + 0,
        low_24h                  => $ticker->{low} + 0,
        price_change_24h         => ($ticker->{last} - $ticker->{open}) + 0,
        price_change_percent_24h => $ticker->{changeRate} ? ($ticker->{changeRate} * 100) : 0,
    };

    store_price_data($dbh, 'KUCOIN', $price_data);

    # Calculate depth at various levels
    my %depth_data;
    foreach my $pct (2, 5, 10) {
        my ($bid_erg, $bid_usd) = calculate_depth_at_percentage($formatted_orderbook, $mid_price, $pct, 'bid');
        my ($ask_erg, $ask_usd) = calculate_depth_at_percentage($formatted_orderbook, $mid_price, $pct, 'ask');
        $depth_data{"$pct%"} = {
            bid_erg => $bid_erg,
            bid_usd => $bid_usd,
            ask_erg => $ask_erg,
            ask_usd => $ask_usd
        };
    }

    store_orderbook_depth($dbh, 'KUCOIN', \%depth_data);

    # Store trades if available
    if ($trades && @$trades) {
        # Convert KuCoin trade format
        my @formatted_trades;
        foreach my $t (@$trades) {
            push @formatted_trades, {
                id           => $t->{sequence},
                time         => $t->{time} / 1000000,  # KuCoin uses nanoseconds
                price        => $t->{price} + 0,
                qty          => $t->{size} + 0,
                isBuyerMaker => $t->{side} eq 'sell'
            };
        }
        store_trades($dbh, 'KUCOIN', \@formatted_trades, $price_data->{price});
    }

    # Calculate metrics
    calculate_and_store_metrics($dbh, 'KUCOIN');

    # Analyze and generate alerts
    my $alerts = analyze_and_recommend($dbh, $config, 'KUCOIN', $price_data, \%depth_data);

    return $alerts;
}

# ============================================================
# MAIN EXECUTION
# ============================================================
sub main {
    my $start_time = time();
    print "=" x 60 . "\n";
    print "ERGO MM Monitor - " . strftime("%Y-%m-%d %H:%M:%S", localtime()) . "\n";
    print "=" x 60 . "\n";

    my $dbh = get_db_connection();
    my $config = load_config($dbh);
    my $ua = create_http_client();

    unless ($config->{monitoring_enabled}) {
        print "Monitoring is disabled in configuration.\n";
        $dbh->disconnect();
        return;
    }

    my @all_alerts;

    # Process MEXC
    if ($config->{mexc_enabled}) {
        my $mexc_alerts = process_mexc($dbh, $ua, $config);
        push @all_alerts, @$mexc_alerts if $mexc_alerts;
    }

    # Process KuCoin
    if ($config->{kucoin_enabled}) {
        my $kucoin_alerts = process_kucoin($dbh, $ua, $config);
        push @all_alerts, @$kucoin_alerts if $kucoin_alerts;
    }

    # Send alerts
    my $cooldown = $config->{alert_cooldown_minutes} || 30;
    my $webhook_url = $config->{discord_webhook};

    foreach my $alert (@all_alerts) {
        if (check_alert_cooldown($dbh, $alert->{type}, $cooldown)) {
            my $sent = 0;
            if ($webhook_url) {
                $sent = send_discord_alert(
                    $webhook_url,
                    "ERGO MM Alert: " . $alert->{type},
                    $alert->{message},
                    $alert->{severity},
                    $alert->{fields}
                );
            }
            log_alert($dbh, $alert->{type}, $alert->{severity}, undef, $alert->{message}, $alert->{fields}, $sent);
            print "ALERT [$alert->{severity}]: $alert->{message}\n";
        } else {
            print "SKIPPED (cooldown): $alert->{type}\n";
        }
    }

    # Run cleanup occasionally (1% chance per run, or roughly once per 100 runs)
    if (rand() < 0.01) {
        print "Running database cleanup...\n";
        $dbh->do("CALL cleanup_old_data()");
    }

    my $elapsed = time() - $start_time;
    print "-" x 60 . "\n";
    printf "Completed in %.2f seconds\n", $elapsed;

    $dbh->disconnect();
}

# Run the main function
main();

1;

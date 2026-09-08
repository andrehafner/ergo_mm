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
use Time::HiRes qw(time gettimeofday);
use Digest::SHA qw(sha256_hex hmac_sha256_hex hmac_sha256);
use MIME::Base64;
use Time::Local qw(timegm);
use Fcntl qw(:flock);

# Prevent overlapping runs when cron fires every minute and a run overruns
my $LOCK_FILE = '/tmp/ergo_mm_monitor.lock';
my $NANOERG = 1_000_000_000;

# Global API keys (loaded from config file)
our %API_KEYS;

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
    # Read MySQL password from file
    my $password_file = get_db_password_file();
    open my $fh, '<', $password_file or die "Can't open password file: $!";
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
# API KEYS LOADER
# ============================================================
sub get_api_keys_file {
    # Check multiple locations for the API keys file
    my @paths = (
        '/var/www/ergo_mm/cgi-bin/api_keys.conf',  # nginx deployment
        '/usr/lib/cgi-bin/api_keys.conf',           # legacy/Apache deployment
    );

    for my $path (@paths) {
        return $path if -f $path;
    }

    return undef;  # Not found (optional file)
}

sub load_api_keys {
    my $config_file = get_api_keys_file();

    unless ($config_file) {
        print "API keys config file not found.\n";
        print "Create api_keys.conf with your MEXC and KuCoin API keys to enable balance/order tracking.\n";
        return;
    }

    open my $fh, '<', $config_file or do {
        warn "Cannot open API keys file: $!";
        return;
    };

    while (<$fh>) {
        chomp;
        next if /^\s*#/ || /^\s*$/;  # Skip comments and empty lines
        if (/^(\w+)\s*=\s*(.*)$/) {
            my ($key, $value) = ($1, $2);
            $value =~ s/^\s+//;
            $value =~ s/\s+$//;
            $API_KEYS{$key} = $value;
        }
    }
    close $fh;

    # Validate required keys
    my $mexc_ready = $API_KEYS{MEXC_ACCESS_KEY} && $API_KEYS{MEXC_SECRET_KEY};
    my $kucoin_ready = $API_KEYS{KUCOIN_KEY} && $API_KEYS{KUCOIN_SECRET} && $API_KEYS{KUCOIN_PASSPHRASE};

    print "API Keys Status: MEXC=" . ($mexc_ready ? "Ready" : "Missing") .
          ", KuCoin=" . ($kucoin_ready ? "Ready" : "Missing") . "\n";
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
    my ($timeout) = @_;
    my $ua = LWP::UserAgent->new(
        timeout => $timeout || 30,
        agent => 'ErgoMMBot/1.0',
        ssl_opts => { verify_hostname => 0 },
        local_address => '0.0.0.0'  # Force IPv4
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

# MEXC Authenticated API Functions
sub mexc_sign_request {
    my ($params) = @_;
    my $query_string = join('&', map { "$_=$params->{$_}" } sort keys %$params);
    my $signature = hmac_sha256_hex($query_string, $API_KEYS{MEXC_SECRET_KEY});
    return ($query_string, $signature);
}

sub fetch_mexc_balance {
    my ($ua) = @_;

    return undef unless $API_KEYS{MEXC_ACCESS_KEY} && $API_KEYS{MEXC_SECRET_KEY};

    my $timestamp = int(time * 1000);
    my $params = { timestamp => $timestamp };
    my ($query_string, $signature) = mexc_sign_request($params);

    my $url = "https://api.mexc.com/api/v3/account?$query_string&signature=$signature";

    my $response = $ua->get($url,
        'X-MEXC-APIKEY' => $API_KEYS{MEXC_ACCESS_KEY}
    );

    if ($response->is_success) {
        my $data = decode_json($response->decoded_content);
        # Extract ERG and USDT balances
        my %balances;
        foreach my $asset (@{$data->{balances} || []}) {
            if ($asset->{asset} eq 'ERG' || $asset->{asset} eq 'USDT') {
                $balances{$asset->{asset}} = {
                    free => $asset->{free} + 0,
                    locked => $asset->{locked} + 0,
                    total => ($asset->{free} + 0) + ($asset->{locked} + 0)
                };
            }
        }
        return \%balances;
    }
    warn "MEXC balance fetch failed: " . $response->status_line . " - " . $response->decoded_content;
    return undef;
}

sub fetch_mexc_open_orders {
    my ($ua) = @_;

    return undef unless $API_KEYS{MEXC_ACCESS_KEY} && $API_KEYS{MEXC_SECRET_KEY};

    my $timestamp = int(time * 1000);
    my $params = {
        symbol => 'ERGUSDT',
        timestamp => $timestamp
    };
    my ($query_string, $signature) = mexc_sign_request($params);

    my $url = "https://api.mexc.com/api/v3/openOrders?$query_string&signature=$signature";

    my $response = $ua->get($url,
        'X-MEXC-APIKEY' => $API_KEYS{MEXC_ACCESS_KEY}
    );

    if ($response->is_success) {
        return decode_json($response->decoded_content);
    }
    warn "MEXC open orders fetch failed: " . $response->status_line . " - " . $response->decoded_content;
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

# KuCoin Authenticated API Functions
sub kucoin_sign_request {
    my ($timestamp, $method, $endpoint, $body) = @_;
    $body //= '';

    my $str_to_sign = $timestamp . $method . $endpoint . $body;
    my $signature = encode_base64(hmac_sha256($str_to_sign, $API_KEYS{KUCOIN_SECRET}), '');
    my $passphrase = encode_base64(hmac_sha256($API_KEYS{KUCOIN_PASSPHRASE}, $API_KEYS{KUCOIN_SECRET}), '');

    return ($signature, $passphrase);
}

sub fetch_kucoin_balance {
    my ($ua) = @_;

    return undef unless $API_KEYS{KUCOIN_KEY} && $API_KEYS{KUCOIN_SECRET} && $API_KEYS{KUCOIN_PASSPHRASE};

    my $timestamp = int(time * 1000);
    my $endpoint = '/api/v1/accounts';
    my $method = 'GET';

    my ($signature, $passphrase) = kucoin_sign_request($timestamp, $method, $endpoint);

    my $response = $ua->get(
        "https://api.kucoin.com$endpoint",
        'KC-API-KEY' => $API_KEYS{KUCOIN_KEY},
        'KC-API-SIGN' => $signature,
        'KC-API-TIMESTAMP' => $timestamp,
        'KC-API-PASSPHRASE' => $passphrase,
        'KC-API-KEY-VERSION' => '2'
    );

    if ($response->is_success) {
        my $data = decode_json($response->decoded_content);
        if ($data->{code} eq '200000') {
            # Extract ERG and USDT balances from trading accounts
            my %balances;
            foreach my $account (@{$data->{data} || []}) {
                if (($account->{currency} eq 'ERG' || $account->{currency} eq 'USDT')
                    && $account->{type} eq 'trade') {
                    $balances{$account->{currency}} = {
                        free => $account->{available} + 0,
                        locked => $account->{holds} + 0,
                        total => $account->{balance} + 0
                    };
                }
            }
            return \%balances;
        }
    }
    warn "KuCoin balance fetch failed: " . $response->status_line . " - " . $response->decoded_content;
    return undef;
}

sub fetch_kucoin_open_orders {
    my ($ua) = @_;

    return undef unless $API_KEYS{KUCOIN_KEY} && $API_KEYS{KUCOIN_SECRET} && $API_KEYS{KUCOIN_PASSPHRASE};

    my $timestamp = int(time * 1000);
    my $endpoint = '/api/v1/orders?status=active&symbol=ERG-USDT';
    my $method = 'GET';

    my ($signature, $passphrase) = kucoin_sign_request($timestamp, $method, $endpoint);

    my $response = $ua->get(
        "https://api.kucoin.com$endpoint",
        'KC-API-KEY' => $API_KEYS{KUCOIN_KEY},
        'KC-API-SIGN' => $signature,
        'KC-API-TIMESTAMP' => $timestamp,
        'KC-API-PASSPHRASE' => $passphrase,
        'KC-API-KEY-VERSION' => '2'
    );

    if ($response->is_success) {
        my $data = decode_json($response->decoded_content);
        if ($data->{code} eq '200000') {
            return $data->{data}{items} || [];
        }
    }
    warn "KuCoin open orders fetch failed: " . $response->status_line . " - " . $response->decoded_content;
    return undef;
}

# ============================================================
# ACCOUNT DEPOSIT / WITHDRAWAL HISTORY (your own ERG transfers)
# ============================================================
my %MEXC_DEPOSIT_STATUS  = (1 => 'SMALL', 2 => 'TIME_DELAY', 3 => 'LARGE_DELAY', 4 => 'PENDING',
                            5 => 'SUCCESS', 6 => 'AUDITING', 7 => 'REJECTED');
my %MEXC_WITHDRAW_STATUS = (1 => 'APPLY', 2 => 'AUDITING', 3 => 'WAIT', 4 => 'PROCESSING', 5 => 'WAIT_PACKAGING',
                            6 => 'WAIT_CONFIRM', 7 => 'SUCCESS', 8 => 'FAILED', 9 => 'CANCEL', 10 => 'MANUAL');

# Accepts epoch seconds, epoch milliseconds or 'YYYY-MM-DD HH:MM:SS' and returns epoch seconds
sub to_epoch_seconds {
    my ($value) = @_;
    return undef unless defined $value && length $value;
    if ($value =~ /^\d+(\.\d+)?$/) {
        return $value > 100_000_000_000 ? int($value / 1000) : int($value);
    }
    if ($value =~ /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})/) {
        my $t = eval { timegm($6, $5, $4, $3, $2 - 1, $1) };
        return $t;
    }
    return undef;
}

sub mexc_signed_get {
    my ($ua, $path, $params) = @_;
    return undef unless $API_KEYS{MEXC_ACCESS_KEY} && $API_KEYS{MEXC_SECRET_KEY};

    $params ||= {};
    $params->{timestamp} = int(time * 1000);
    my ($query_string, $signature) = mexc_sign_request($params);

    my $response = $ua->get("https://api.mexc.com$path?$query_string&signature=$signature",
        'X-MEXC-APIKEY' => $API_KEYS{MEXC_ACCESS_KEY});

    unless ($response->is_success) {
        warn "MEXC $path failed: " . $response->status_line . " - " . $response->decoded_content . "\n";
        return undef;
    }
    my $data = eval { decode_json($response->decoded_content) };
    if ($@) {
        warn "MEXC $path returned invalid JSON: $@";
        return undef;
    }
    return $data;
}

sub kucoin_signed_get {
    my ($ua, $endpoint) = @_;
    return undef unless $API_KEYS{KUCOIN_KEY} && $API_KEYS{KUCOIN_SECRET} && $API_KEYS{KUCOIN_PASSPHRASE};

    my $timestamp = int(time * 1000);
    my ($signature, $passphrase) = kucoin_sign_request($timestamp, 'GET', $endpoint);

    my $response = $ua->get(
        "https://api.kucoin.com$endpoint",
        'KC-API-KEY' => $API_KEYS{KUCOIN_KEY},
        'KC-API-SIGN' => $signature,
        'KC-API-TIMESTAMP' => $timestamp,
        'KC-API-PASSPHRASE' => $passphrase,
        'KC-API-KEY-VERSION' => '2'
    );

    unless ($response->is_success) {
        warn "KuCoin $endpoint failed: " . $response->status_line . " - " . $response->decoded_content . "\n";
        return undef;
    }
    my $data = eval { decode_json($response->decoded_content) };
    if ($@ || !$data || ($data->{code} // '') ne '200000') {
        warn "KuCoin $endpoint error: " . ($data && $data->{msg} ? $data->{msg} : ($@ || 'unknown')) . "\n";
        return undef;
    }
    return $data->{data};
}

sub fetch_mexc_transfers {
    my ($ua) = @_;
    return undef unless $API_KEYS{MEXC_ACCESS_KEY} && $API_KEYS{MEXC_SECRET_KEY};

    my @transfers;

    my $deposits = mexc_signed_get($ua, '/api/v3/capital/deposit/hisrec', { coin => 'ERG', limit => 100 });
    foreach my $d (@{ ref $deposits eq 'ARRAY' ? $deposits : [] }) {
        push @transfers, {
            direction   => 'deposit',
            transfer_id => $d->{txId} || $d->{id}
                           || sha256_hex(join('|', 'mexc-deposit', $d->{insertTime} // '', $d->{amount} // '', $d->{address} // '')),
            amount      => ($d->{amount} // 0) + 0,
            fee         => 0,
            status      => $MEXC_DEPOSIT_STATUS{$d->{status} // ''} // ($d->{status} // 'UNKNOWN'),
            address     => $d->{address},
            tx_id       => $d->{txId},
            time        => to_epoch_seconds($d->{insertTime}),
        };
    }

    my $withdrawals = mexc_signed_get($ua, '/api/v3/capital/withdraw/history', { coin => 'ERG', limit => 100 });
    foreach my $w (@{ ref $withdrawals eq 'ARRAY' ? $withdrawals : [] }) {
        push @transfers, {
            direction   => 'withdrawal',
            transfer_id => $w->{id} || $w->{txId}
                           || sha256_hex(join('|', 'mexc-withdrawal', $w->{applyTime} // '', $w->{amount} // '', $w->{address} // '')),
            amount      => ($w->{amount} // 0) + 0,
            fee         => ($w->{transactionFee} // 0) + 0,
            status      => $MEXC_WITHDRAW_STATUS{$w->{status} // ''} // ($w->{status} // 'UNKNOWN'),
            address     => $w->{address},
            tx_id       => $w->{txId},
            time        => to_epoch_seconds($w->{applyTime}),
        };
    }

    return \@transfers;
}

sub fetch_kucoin_transfers {
    my ($ua) = @_;
    return undef unless $API_KEYS{KUCOIN_KEY} && $API_KEYS{KUCOIN_SECRET} && $API_KEYS{KUCOIN_PASSPHRASE};

    my @transfers;

    my $deposits = kucoin_signed_get($ua, '/api/v1/deposits?currency=ERG&pageSize=100');
    foreach my $d (@{ ($deposits && ref $deposits->{items} eq 'ARRAY') ? $deposits->{items} : [] }) {
        my $wallet_tx = $d->{walletTxId} // '';
        push @transfers, {
            direction   => 'deposit',
            transfer_id => $wallet_tx
                           || sha256_hex(join('|', 'kucoin-deposit', $d->{createdAt} // '', $d->{amount} // '', $d->{address} // '')),
            amount      => ($d->{amount} // 0) + 0,
            fee         => ($d->{fee} // 0) + 0,
            status      => $d->{status} // 'UNKNOWN',
            address     => $d->{address},
            tx_id       => (split /@/, $wallet_tx)[0],
            time        => to_epoch_seconds($d->{createdAt}),
        };
    }

    my $withdrawals = kucoin_signed_get($ua, '/api/v1/withdrawals?currency=ERG&pageSize=100');
    foreach my $w (@{ ($withdrawals && ref $withdrawals->{items} eq 'ARRAY') ? $withdrawals->{items} : [] }) {
        my $wallet_tx = $w->{walletTxId} // '';
        push @transfers, {
            direction   => 'withdrawal',
            transfer_id => $w->{id} || $wallet_tx
                           || sha256_hex(join('|', 'kucoin-withdrawal', $w->{createdAt} // '', $w->{amount} // '', $w->{address} // '')),
            amount      => ($w->{amount} // 0) + 0,
            fee         => ($w->{fee} // 0) + 0,
            status      => $w->{status} // 'UNKNOWN',
            address     => $w->{address},
            tx_id       => (split /@/, $wallet_tx)[0],
            time        => to_epoch_seconds($w->{createdAt}),
        };
    }

    return \@transfers;
}

sub store_user_transfers {
    my ($dbh, $exchange, $transfers) = @_;
    return unless $transfers;

    my $sth = $dbh->prepare(qq{
        INSERT INTO user_transfers
        (exchange, direction, transfer_id, amount_erg, fee_erg, status, address, tx_id, tx_time)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?))
        ON DUPLICATE KEY UPDATE status = VALUES(status), tx_id = VALUES(tx_id), tx_time = VALUES(tx_time)
    });

    my $new = 0;
    foreach my $t (@$transfers) {
        my $rows = $sth->execute(
            $exchange, $t->{direction}, $t->{transfer_id}, $t->{amount}, $t->{fee},
            $t->{status}, $t->{address}, $t->{tx_id}, $t->{time}
        );
        $new++ if $rows && $rows == 1;   # MySQL: 1 = inserted, 2 = updated, 0 = unchanged
    }
    $sth->finish();

    printf "  Transfers: %d deposits/withdrawals on record (%d new)\n", scalar(@$transfers), $new;
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
# USER BALANCE AND ORDER TRACKING
# ============================================================
sub store_user_balance {
    my ($dbh, $exchange, $balances, $current_price) = @_;

    return unless $balances;

    my $sql = qq{
        INSERT INTO user_balances
        (exchange, erg_free, erg_locked, erg_total, usdt_free, usdt_locked, usdt_total, total_value_usd)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    };

    my $erg = $balances->{ERG} || { free => 0, locked => 0, total => 0 };
    my $usdt = $balances->{USDT} || { free => 0, locked => 0, total => 0 };
    my $total_value = ($erg->{total} * $current_price) + $usdt->{total};

    my $sth = $dbh->prepare($sql);
    $sth->execute(
        $exchange,
        $erg->{free},
        $erg->{locked},
        $erg->{total},
        $usdt->{free},
        $usdt->{locked},
        $usdt->{total},
        $total_value
    );
    $sth->finish();

    print sprintf("  Balance: %.2f ERG (%.2f locked), %.2f USDT (%.2f locked) = \$%.2f total\n",
        $erg->{total}, $erg->{locked}, $usdt->{total}, $usdt->{locked}, $total_value);
}

sub store_user_orders {
    my ($dbh, $exchange, $orders) = @_;

    return unless $orders && @$orders;

    # Clear existing orders for this exchange and insert fresh
    $dbh->do("DELETE FROM user_open_orders WHERE exchange = ?", undef, $exchange);

    my $sql = qq{
        INSERT INTO user_open_orders
        (exchange, order_id, side, price, amount, amount_filled, order_type, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?))
    };

    my $sth = $dbh->prepare($sql);

    foreach my $order (@$orders) {
        my ($order_id, $side, $price, $amount, $filled, $order_type, $created);

        if ($exchange eq 'MEXC') {
            $order_id = $order->{orderId};
            $side = lc($order->{side});
            $price = $order->{price} + 0;
            $amount = $order->{origQty} + 0;
            $filled = $order->{executedQty} + 0;
            $order_type = $order->{type};
            $created = $order->{time} / 1000;
        } else {  # KuCoin
            $order_id = $order->{id};
            $side = $order->{side};
            $price = $order->{price} + 0;
            $amount = $order->{size} + 0;
            $filled = $order->{dealSize} + 0;
            $order_type = $order->{type};
            $created = $order->{createdAt} / 1000;
        }

        $sth->execute($exchange, $order_id, $side, $price, $amount, $filled, $order_type, $created);
    }
    $sth->finish();

    print sprintf("  Stored %d open orders\n", scalar(@$orders));
}

sub calculate_user_depth {
    my ($orders, $mid_price, $percentage, $side) = @_;

    return (0, 0) unless $orders && @$orders;

    my $threshold_price;
    if ($side eq 'bid') {
        $threshold_price = $mid_price * (1 - $percentage / 100);
    } else {
        $threshold_price = $mid_price * (1 + $percentage / 100);
    }

    my $total_amount = 0;
    my $total_usd = 0;

    foreach my $order (@$orders) {
        my ($price, $amount, $order_side);

        # Handle both MEXC and KuCoin order formats
        if (exists $order->{origQty}) {  # MEXC
            $price = $order->{price} + 0;
            $amount = ($order->{origQty} + 0) - ($order->{executedQty} + 0);  # Remaining
            $order_side = lc($order->{side});
        } else {  # KuCoin
            $price = $order->{price} + 0;
            $amount = ($order->{size} + 0) - ($order->{dealSize} + 0);  # Remaining
            $order_side = $order->{side};
        }

        # Only count orders on the correct side
        next if ($side eq 'bid' && $order_side ne 'buy');
        next if ($side eq 'ask' && $order_side ne 'sell');

        # Check if within price range
        if ($side eq 'bid') {
            next if $price < $threshold_price;
        } else {
            next if $price > $threshold_price;
        }

        $total_amount += $amount;
        $total_usd += $amount * $price;
    }

    return ($total_amount, $total_usd);
}

sub store_user_depth {
    my ($dbh, $exchange, $orders, $mid_price, $market_depth) = @_;

    return unless $orders;

    my $sql = qq{
        INSERT INTO user_orderbook_depth
        (exchange, depth_level, bid_depth_erg, bid_depth_usd, ask_depth_erg, ask_depth_usd,
         market_bid_usd, market_ask_usd, bid_share_pct, ask_share_pct)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    };

    my $sth = $dbh->prepare($sql);

    foreach my $pct (2, 5, 10) {
        my ($user_bid_erg, $user_bid_usd) = calculate_user_depth($orders, $mid_price, $pct, 'bid');
        my ($user_ask_erg, $user_ask_usd) = calculate_user_depth($orders, $mid_price, $pct, 'ask');

        my $market_bid = $market_depth->{"$pct%"}{bid_usd} || 0;
        my $market_ask = $market_depth->{"$pct%"}{ask_usd} || 0;

        my $bid_share = $market_bid > 0 ? ($user_bid_usd / $market_bid) * 100 : 0;
        my $ask_share = $market_ask > 0 ? ($user_ask_usd / $market_ask) * 100 : 0;

        $sth->execute(
            $exchange,
            "$pct%",
            $user_bid_erg,
            $user_bid_usd,
            $user_ask_erg,
            $user_ask_usd,
            $market_bid,
            $market_ask,
            $bid_share,
            $ask_share
        );

        if ($user_bid_usd > 0 || $user_ask_usd > 0) {
            print sprintf("  Your depth at %d%%: Bid \$%.2f (%.1f%%), Ask \$%.2f (%.1f%%)\n",
                $pct, $user_bid_usd, $bid_share, $user_ask_usd, $ask_share);
        }
    }
    $sth->finish();
}

# ============================================================
# ON-CHAIN EXCHANGE FLOW TRACKING (Ergo explorer API)
# Watches the exchanges' known ERG wallet addresses and records
# every confirmed transaction that moved ERG in or out of them.
# ============================================================
sub parse_address_list {
    my ($text) = @_;
    return () unless defined $text;
    my %seen;
    my @addresses;
    foreach my $candidate (split /[\s,;]+/, $text) {
        next unless length $candidate;
        # Ergo addresses are base58 (no 0, O, I, l); reject anything else so it never reaches a URL
        next unless $candidate =~ /^[1-9A-HJ-NP-Za-km-z]{20,120}$/;
        push @addresses, $candidate unless $seen{$candidate}++;
    }
    return @addresses;
}

sub explorer_get {
    my ($ua, $base_url, $path) = @_;
    my $response = $ua->get("$base_url$path", 'Accept' => 'application/json');
    unless ($response->is_success) {
        warn "Explorer request failed ($path): " . $response->status_line . "\n";
        return undef;
    }
    my $data = eval { decode_json($response->decoded_content) };
    if ($@) {
        warn "Explorer returned invalid JSON ($path): $@";
        return undef;
    }
    return $data;
}

sub fetch_address_balance_erg {
    my ($ua, $base_url, $address) = @_;
    my $data = explorer_get($ua, $base_url, "/api/v1/addresses/$address/balance/confirmed");
    return undef unless $data && ref $data eq 'HASH' && defined $data->{nanoErgs};
    return $data->{nanoErgs} / $NANOERG;
}

sub fetch_address_transactions {
    my ($ua, $base_url, $address, $offset, $limit) = @_;
    my $data = explorer_get($ua, $base_url, "/api/v1/addresses/$address/transactions?offset=$offset&limit=$limit");
    return undef unless $data && ref $data eq 'HASH';
    return ref $data->{items} eq 'ARRAY' ? $data->{items} : [];
}

# Net ERG that one transaction moved into (+) or out of (-) the exchange's
# whole address set. Inputs spent from exchange addresses count as leaving,
# outputs paid to exchange addresses count as arriving, so change outputs
# and hot<->cold shuffles net out automatically.
sub classify_exchange_tx {
    my ($tx, $addr_set) = @_;

    my ($in_nano, $out_nano) = (0, 0);
    my (%external_senders, %external_receivers);

    foreach my $input (@{ ref $tx->{inputs} eq 'ARRAY' ? $tx->{inputs} : [] }) {
        my $address = $input->{address} // '';
        my $value = ($input->{value} // 0) + 0;
        if ($addr_set->{$address}) {
            $out_nano += $value;
        } elsif (length $address) {
            $external_senders{$address} += $value;
        }
    }
    foreach my $output (@{ ref $tx->{outputs} eq 'ARRAY' ? $tx->{outputs} : [] }) {
        my $address = $output->{address} // '';
        my $value = ($output->{value} // 0) + 0;
        if ($addr_set->{$address}) {
            $in_nano += $value;
        } elsif (length $address) {
            $external_receivers{$address} += $value;
        }
    }

    my $net_nano = $in_nano - $out_nano;
    my $direction = $net_nano >= 0 ? 'in' : 'out';
    my $counterparties = $direction eq 'in' ? \%external_senders : \%external_receivers;
    my ($counterparty) = sort { $counterparties->{$b} <=> $counterparties->{$a} } keys %$counterparties;

    return {
        direction    => $direction,
        amount_erg   => abs($net_nano) / $NANOERG,
        counterparty => $counterparty,
    };
}

sub get_latest_price {
    my ($dbh, $exchange) = @_;
    my $sth = $dbh->prepare("SELECT price FROM price_data WHERE exchange = ? ORDER BY timestamp DESC LIMIT 1");
    $sth->execute($exchange);
    my ($price) = $sth->fetchrow_array();
    $sth->finish();
    return $price;
}

sub process_exchange_flows {
    my ($dbh, $ua, $config, $exchange, $addresses, $price_usd) = @_;

    print "Tracking on-chain flows for $exchange (" . scalar(@$addresses) . " address" . (@$addresses == 1 ? '' : 'es') . ")...\n";

    my %addr_set = map { $_ => 1 } @$addresses;
    my $base_url = $config->{ergo_explorer_url} || 'https://api.ergoplatform.com';
    $base_url =~ s{/+$}{};

    my $page_size   = 50;
    my $max_pages   = 4;                      # up to 200 txs per address per run
    my $lookback_ms = 48 * 3600 * 1000;       # backfill window on first run
    my $now_ms      = int(time * 1000);
    my $min_flow_erg = 0.01;                  # ignore fee-only / internal shuffles

    my $known_sth = $dbh->prepare("SELECT 1 FROM exchange_flows WHERE exchange = ? AND tx_id = ?");
    my $insert_sth = $dbh->prepare(qq{
        INSERT IGNORE INTO exchange_flows
        (exchange, tx_id, direction, amount_erg, amount_usd, price_usd, counterparty, block_height, tx_time)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?))
    });
    my $reserve_sth = $dbh->prepare("INSERT INTO exchange_reserves (exchange, address, balance_erg) VALUES (?, ?, ?)");

    my @new_flows;
    my %seen_tx;
    my $total_reserve = 0;
    my $reserve_ok = 0;

    foreach my $address (@$addresses) {
        # Reserve snapshot
        my $balance = fetch_address_balance_erg($ua, $base_url, $address);
        if (defined $balance) {
            $reserve_sth->execute($exchange, $address, $balance);
            $total_reserve += $balance;
            $reserve_ok++;
        }

        # Recent transactions (explorer returns newest first); page until we reach ones we already have
        my $offset = 0;
        for my $page (1 .. $max_pages) {
            my $txs = fetch_address_transactions($ua, $base_url, $address, $offset, $page_size);
            last unless $txs && @$txs;

            my $known_on_page = 0;
            my $oldest_ms;

            foreach my $tx (@$txs) {
                my $tx_id = $tx->{id} or next;
                next unless $tx->{inclusionHeight};              # confirmed only
                my $ts_ms = ($tx->{timestamp} // 0) + 0;
                $oldest_ms = $ts_ms if !defined $oldest_ms || $ts_ms < $oldest_ms;
                next if $seen_tx{$tx_id}++;

                $known_sth->execute($exchange, $tx_id);
                my ($known) = $known_sth->fetchrow_array();
                $known_sth->finish();
                if ($known) { $known_on_page++; next; }

                my $flow = classify_exchange_tx($tx, \%addr_set);
                next if $flow->{amount_erg} < $min_flow_erg;

                my $amount_usd = $price_usd ? $flow->{amount_erg} * $price_usd : undef;
                my $inserted = $insert_sth->execute(
                    $exchange, $tx_id, $flow->{direction}, $flow->{amount_erg}, $amount_usd, $price_usd,
                    $flow->{counterparty}, $tx->{inclusionHeight}, int($ts_ms / 1000)
                );
                next unless $inserted && $inserted > 0;

                push @new_flows, { %$flow, tx_id => $tx_id, tx_time_ms => $ts_ms };
            }

            last if $known_on_page > 0;
            last if @$txs < $page_size;
            last if defined $oldest_ms && $oldest_ms < $now_ms - $lookback_ms;
            $offset += $page_size;
        }
    }
    $known_sth->finish();
    $insert_sth->finish();
    $reserve_sth->finish();

    my ($in_new, $out_new) = (0, 0);
    foreach my $flow (@new_flows) {
        if ($flow->{direction} eq 'in') { $in_new += $flow->{amount_erg} } else { $out_new += $flow->{amount_erg} }
    }
    printf "  Reserve: %s ERG across %d/%d addresses | new transfers: %d (in %.2f ERG, out %.2f ERG)\n",
        $reserve_ok ? sprintf("%.2f", $total_reserve) : 'n/a', $reserve_ok, scalar(@$addresses),
        scalar(@new_flows), $in_new, $out_new;

    return \@new_flows;
}

sub analyze_flows {
    my ($dbh, $config, $exchange, $new_flows, $price_usd) = @_;

    my @alerts;
    my $threshold = ($config->{flow_alert_threshold_erg} || 0) + 0;
    return \@alerts if $threshold <= 0;

    my $recent_cutoff_ms = (time - 15 * 60) * 1000;   # never alert on backfilled history

    foreach my $flow (@$new_flows) {
        next if $flow->{tx_time_ms} < $recent_cutoff_ms;
        next if $flow->{amount_erg} < $threshold;

        my $usd_note = $price_usd ? sprintf(" (~\$%.0f)", $flow->{amount_erg} * $price_usd) : '';
        my $tx_link = "https://explorer.ergoplatform.com/en/transactions/$flow->{tx_id}";
        my @fields = (
            { name => 'Amount', value => sprintf("%.2f ERG%s", $flow->{amount_erg}, $usd_note), inline => 'true' },
            { name => 'Transaction', value => "[" . substr($flow->{tx_id}, 0, 10) . "...]($tx_link)", inline => 'true' },
        );

        if ($flow->{direction} eq 'in') {
            push @alerts, {
                type     => 'LARGE_INFLOW',
                severity => 'warning',
                exchange => $exchange,
                message  => sprintf("%s: %.0f ERG%s just arrived on the exchange on-chain. Deposits this size often precede selling - watch your bids.",
                    $exchange, $flow->{amount_erg}, $usd_note),
                fields   => \@fields,
            };
        } else {
            push @alerts, {
                type     => 'LARGE_OUTFLOW',
                severity => 'info',
                exchange => $exchange,
                message  => sprintf("%s: %.0f ERG%s withdrawn from the exchange on-chain. Less sell-side supply sitting on the book.",
                    $exchange, $flow->{amount_erg}, $usd_note),
                fields   => \@fields,
            };
        }
    }

    # Net inflow over the last hour
    my $sth = $dbh->prepare(qq{
        SELECT
            COALESCE(SUM(CASE WHEN direction = 'in'  THEN amount_erg ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN direction = 'out' THEN amount_erg ELSE 0 END), 0)
        FROM exchange_flows
        WHERE exchange = ? AND tx_time > DATE_SUB(NOW(), INTERVAL 1 HOUR)
    });
    $sth->execute($exchange);
    my ($in_1h, $out_1h) = $sth->fetchrow_array();
    $sth->finish();

    my $net_1h = ($in_1h || 0) - ($out_1h || 0);
    if ($net_1h >= 2 * $threshold) {
        my $usd_note = $price_usd ? sprintf(" (~\$%.0f)", $net_1h * $price_usd) : '';
        push @alerts, {
            type     => 'NET_INFLOW_HIGH',
            severity => 'critical',
            exchange => $exchange,
            message  => sprintf("%s: net +%.0f ERG%s flowed onto the exchange in the last hour (in %.0f / out %.0f). Consider pulling or lowering bids and widening spread until it is absorbed.",
                $exchange, $net_1h, $usd_note, $in_1h, $out_1h),
            fields   => [
                { name => 'Inflow 1h',  value => sprintf("%.2f ERG", $in_1h),   inline => 'true' },
                { name => 'Outflow 1h', value => sprintf("%.2f ERG", $out_1h),  inline => 'true' },
                { name => 'Net 1h',     value => sprintf("+%.2f ERG", $net_1h), inline => 'true' },
            ],
        };
        add_recommendation($dbh, $exchange, 'FLOW', 'REDUCE_BIDS',
            sprintf('Net on-chain inflow of %.0f ERG to %s in the last hour. Large deposits usually get sold; keep bids light or widen the spread until the book absorbs it.', $net_1h, $exchange),
            8, 2);
    }

    return \@alerts;
}

# ============================================================
# METRICS CALCULATION
# ============================================================
sub calculate_and_store_metrics {
    my ($dbh, $exchange) = @_;

    # Calculate 1-hour and 24-hour metrics (trade windows use trade_time so re-fetched
    # trades never count twice - the trades table has a unique (exchange, trade_id) key)
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
             WHERE exchange = ? AND trade_time > DATE_SUB(NOW(), INTERVAL 1 HOUR)),
            (SELECT COALESCE(SUM(amount_usd), 0) FROM trades
             WHERE exchange = ? AND trade_time > DATE_SUB(NOW(), INTERVAL 24 HOUR)),
            (SELECT COUNT(*) FROM trades
             WHERE exchange = ? AND trade_time > DATE_SUB(NOW(), INTERVAL 1 HOUR)),
            (SELECT COUNT(*) FROM trades
             WHERE exchange = ? AND trade_time > DATE_SUB(NOW(), INTERVAL 24 HOUR)),
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
    my ($dbh, $alert_type, $cooldown_minutes, $exchange) = @_;

    # Cooldown is per alert type AND exchange, so a KuCoin alert never hides a MEXC one
    my $sql = qq{
        SELECT COUNT(*) FROM alerts_log
        WHERE alert_type = ?
        AND COALESCE(exchange, '') = ?
        AND created_at > DATE_SUB(NOW(), INTERVAL ? MINUTE)
    };

    my $sth = $dbh->prepare($sql);
    $sth->execute($alert_type, $exchange // '', $cooldown_minutes);
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
    my ($dbh, $config, $exchange, $price_data, $depth_data, $user_orders) = @_;

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

    # Check user order inventory imbalance (only if we have user orders)
    if ($user_orders && @$user_orders) {
        my $mid_price = ($price_data->{bid_price} + $price_data->{ask_price}) / 2;
        my ($user_bid_erg, $user_bid_usd) = calculate_user_depth($user_orders, $mid_price, 5, 'bid');
        my ($user_ask_erg, $user_ask_usd) = calculate_user_depth($user_orders, $mid_price, 5, 'ask');

        my $total_user_depth = $user_bid_usd + $user_ask_usd;

        if ($total_user_depth > 0) {
            my $bid_ratio = $user_bid_usd / $total_user_depth;
            my $ask_ratio = $user_ask_usd / $total_user_depth;

            # Alert if inventory is heavily imbalanced (more than 70% on one side)
            if ($bid_ratio > 0.7) {
                push @alerts, {
                    type     => 'INVENTORY_IMBALANCE',
                    severity => 'warning',
                    message  => sprintf("%s: Heavy bid-side exposure (%.1f%% of orders). You may accumulate excess ERG.",
                        $exchange, $bid_ratio * 100),
                    fields   => [
                        { name => 'Bid Orders', value => sprintf("\$%.2f", $user_bid_usd), inline => 'true' },
                        { name => 'Ask Orders', value => sprintf("\$%.2f", $user_ask_usd), inline => 'true' },
                        { name => 'Imbalance', value => sprintf("%.1f%% bids", $bid_ratio * 100), inline => 'true' }
                    ]
                };
                add_recommendation($dbh, $exchange, 'INVENTORY', 'REBALANCE_ASK',
                    'Order book heavily weighted to bids. Consider adding more sell orders or reducing buy orders.', 6, 4);
            }
            elsif ($ask_ratio > 0.7) {
                push @alerts, {
                    type     => 'INVENTORY_IMBALANCE',
                    severity => 'warning',
                    message  => sprintf("%s: Heavy ask-side exposure (%.1f%% of orders). You may deplete ERG reserves.",
                        $exchange, $ask_ratio * 100),
                    fields   => [
                        { name => 'Bid Orders', value => sprintf("\$%.2f", $user_bid_usd), inline => 'true' },
                        { name => 'Ask Orders', value => sprintf("\$%.2f", $user_ask_usd), inline => 'true' },
                        { name => 'Imbalance', value => sprintf("%.1f%% asks", $ask_ratio * 100), inline => 'true' }
                    ]
                };
                add_recommendation($dbh, $exchange, 'INVENTORY', 'REBALANCE_BID',
                    'Order book heavily weighted to asks. Consider adding more buy orders or reducing sell orders.', 6, 4);
            }
        }

        # Check if user has very low liquidity share compared to market
        my $market_depth_5pct = ($depth_data->{'5%'}{bid_usd} || 0) + ($depth_data->{'5%'}{ask_usd} || 0);
        if ($market_depth_5pct > 0 && $total_user_depth > 0) {
            my $user_share = ($total_user_depth / $market_depth_5pct) * 100;
            if ($user_share < 5) {
                push @alerts, {
                    type     => 'LOW_LIQUIDITY_SHARE',
                    severity => 'info',
                    message  => sprintf("%s: Your liquidity share is only %.1f%% of 5%% depth. Consider adding more orders.",
                        $exchange, $user_share),
                    fields   => [
                        { name => 'Your Depth', value => sprintf("\$%.2f", $total_user_depth), inline => 'true' },
                        { name => 'Market Depth', value => sprintf("\$%.2f", $market_depth_5pct), inline => 'true' },
                        { name => 'Your Share', value => sprintf("%.1f%%", $user_share), inline => 'true' }
                    ]
                };
            }
        }
    }

    # Volume spike: last hour vs the 24h hourly average (needs >= 12h of de-duplicated trade history)
    my $spike_mult = ($config->{volume_spike_threshold} || 0) + 0;
    if ($spike_mult > 0) {
        my $vsth = $dbh->prepare(qq{
            SELECT
                COALESCE(SUM(CASE WHEN trade_time > DATE_SUB(NOW(), INTERVAL 1 HOUR) THEN amount_usd ELSE 0 END), 0),
                COALESCE(SUM(amount_usd), 0),
                TIMESTAMPDIFF(HOUR, MIN(trade_time), NOW())
            FROM trades
            WHERE exchange = ? AND trade_time > DATE_SUB(NOW(), INTERVAL 24 HOUR)
        });
        $vsth->execute($exchange);
        my ($vol_1h, $vol_24h, $hours_covered) = $vsth->fetchrow_array();
        $vsth->finish();

        if (($hours_covered || 0) >= 12 && $vol_24h > 0) {
            my $hourly_avg = $vol_24h / $hours_covered;
            if ($hourly_avg > 0 && $vol_1h >= $spike_mult * $hourly_avg && $vol_1h >= 500) {
                push @alerts, {
                    type     => 'VOLUME_SPIKE',
                    severity => 'warning',
                    message  => sprintf("%s: 1h volume \$%.0f is %.1fx the 24h hourly average (\$%.0f). Consider widening spreads while it lasts.",
                        $exchange, $vol_1h, $vol_1h / $hourly_avg, $hourly_avg),
                    fields   => [
                        { name => '1h Volume', value => sprintf("\$%.0f", $vol_1h), inline => 'true' },
                        { name => 'Hourly Avg (24h)', value => sprintf("\$%.0f", $hourly_avg), inline => 'true' },
                        { name => 'Multiple', value => sprintf("%.1fx", $vol_1h / $hourly_avg), inline => 'true' }
                    ]
                };
            }
        }
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

    # Fetch and store user balance and orders if API keys available
    my $user_orders;
    if ($API_KEYS{MEXC_ACCESS_KEY}) {
        print "  Fetching MEXC user data...\n";
        my $balances = fetch_mexc_balance($ua);
        store_user_balance($dbh, 'MEXC', $balances, $price_data->{price}) if $balances;

        $user_orders = fetch_mexc_open_orders($ua);
        if ($user_orders) {
            store_user_orders($dbh, 'MEXC', $user_orders);
            store_user_depth($dbh, 'MEXC', $user_orders, $mid_price, \%depth_data);
        }

        my $transfers = fetch_mexc_transfers($ua);
        if ($transfers) {
            { local $dbh->{PrintError} = 0; eval { store_user_transfers($dbh, 'MEXC', $transfers) }; }
            warn "Could not store MEXC transfers (has sql/add_flow_tables.sql been applied?): $@" if $@;
        }
    }

    # Calculate metrics
    calculate_and_store_metrics($dbh, 'MEXC');

    # Analyze and generate alerts
    my $alerts = analyze_and_recommend($dbh, $config, 'MEXC', $price_data, \%depth_data, $user_orders);

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
        price_change_24h         => ($ticker->{changePrice} || 0) + 0,
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

    # Fetch and store user balance and orders if API keys available
    my $user_orders;
    if ($API_KEYS{KUCOIN_KEY}) {
        print "  Fetching KuCoin user data...\n";
        my $balances = fetch_kucoin_balance($ua);
        store_user_balance($dbh, 'KUCOIN', $balances, $price_data->{price}) if $balances;

        $user_orders = fetch_kucoin_open_orders($ua);
        if ($user_orders) {
            store_user_orders($dbh, 'KUCOIN', $user_orders);
            store_user_depth($dbh, 'KUCOIN', $user_orders, $mid_price, \%depth_data);
        }

        my $transfers = fetch_kucoin_transfers($ua);
        if ($transfers) {
            { local $dbh->{PrintError} = 0; eval { store_user_transfers($dbh, 'KUCOIN', $transfers) }; }
            warn "Could not store KuCoin transfers (has sql/add_flow_tables.sql been applied?): $@" if $@;
        }
    }

    # Calculate metrics
    calculate_and_store_metrics($dbh, 'KUCOIN');

    # Analyze and generate alerts
    my $alerts = analyze_and_recommend($dbh, $config, 'KUCOIN', $price_data, \%depth_data, $user_orders);

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

    # Skip this run if the previous one is still going (cron can fire every minute)
    my $lock_fh;
    if (open $lock_fh, '>>', $LOCK_FILE) {
        unless (flock($lock_fh, LOCK_EX | LOCK_NB)) {
            print "Previous monitor run is still in progress - skipping this run.\n";
            return;
        }
    } else {
        warn "Could not open lock file $LOCK_FILE: $! (continuing without lock)\n";
    }

    # Load API keys from config file
    load_api_keys();

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
        if ($mexc_alerts) {
            $_->{exchange} //= 'MEXC' for @$mexc_alerts;
            push @all_alerts, @$mexc_alerts;
        }
    }

    # Process KuCoin
    if ($config->{kucoin_enabled}) {
        my $kucoin_alerts = process_kucoin($dbh, $ua, $config);
        if ($kucoin_alerts) {
            $_->{exchange} //= 'KUCOIN' for @$kucoin_alerts;
            push @all_alerts, @$kucoin_alerts;
        }
    }

    # On-chain ERG flows in/out of each exchange. Runs after the market data is
    # stored so a slow explorer can never delay price/depth collection.
    if (!defined $config->{flow_tracking_enabled} || $config->{flow_tracking_enabled}) {
        my $explorer_ua = create_http_client(($config->{ergo_explorer_timeout} || 20) + 0);
        foreach my $exchange ('MEXC', 'KUCOIN') {
            next unless $config->{lc($exchange) . '_enabled'};
            my @addresses = parse_address_list($config->{lc($exchange) . '_erg_addresses'});
            unless (@addresses) {
                print "No $exchange wallet addresses configured - skipping on-chain flow tracking (set them in Settings).\n";
                next;
            }
            my $price = get_latest_price($dbh, $exchange);
            my $new_flows = do {
                local $dbh->{PrintError} = 0;   # a missing table is reported below with a hint, no need for DBI's own line
                eval { process_exchange_flows($dbh, $explorer_ua, $config, $exchange, \@addresses, $price) };
            };
            if ($@) {
                warn "Flow tracking for $exchange failed (has sql/add_flow_tables.sql been applied?): $@";
                next;
            }
            my $flow_alerts = analyze_flows($dbh, $config, $exchange, $new_flows, $price);
            push @all_alerts, @$flow_alerts;
        }
    }

    # Send alerts
    my $cooldown = $config->{alert_cooldown_minutes} || 30;
    my $webhook_url = $config->{discord_webhook};

    foreach my $alert (@all_alerts) {
        if (check_alert_cooldown($dbh, $alert->{type}, $cooldown, $alert->{exchange})) {
            my $sent = 0;
            if ($webhook_url) {
                $sent = send_discord_alert(
                    $webhook_url,
                    "ERGO MM Alert: " . $alert->{type},
                    $alert->{message},
                    $alert->{severity},
                    $alert->{fields},
                    $alert->{exchange}
                );
            }
            log_alert($dbh, $alert->{type}, $alert->{severity}, $alert->{exchange}, $alert->{message}, $alert->{fields}, $sent);
            print "ALERT [$alert->{severity}]: $alert->{message}\n";
        } else {
            print "SKIPPED (cooldown): $alert->{type}" . ($alert->{exchange} ? " ($alert->{exchange})" : '') . "\n";
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

# Run the main function (skipped when the file is require'd by a test harness)
main() unless caller;

1;

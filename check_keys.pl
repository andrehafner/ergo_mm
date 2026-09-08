#!/usr/bin/perl
# ============================================================
# ERGO MM - exchange API key check
#
# Reads api_keys.conf exactly like monitor.pl does and tries each
# authenticated endpoint the monitor uses, printing the raw reply
# on failure. Run it on the server after editing api_keys.conf:
#
#   perl check_keys.pl
# ============================================================

use strict;
use warnings;
use FindBin;

require "$FindBin::Bin/monitor.pl";   # main() is skipped when require'd
our %API_KEYS;                          # filled by load_api_keys() in monitor.pl

my %MEXC_HINTS = (
    10072  => "MEXC does not recognise this key. Common causes: a key created WITHOUT an IP whitelist expires 90 days after creation;\n" .
              "           the key was deleted/regenerated on mexc.com; or a stray character in api_keys.conf. Create a new key, bind it to\n" .
              "           this server's IP (shown above) so it never expires, and paste it in.",
    700002 => "Signature rejected: MEXC_SECRET_KEY does not match MEXC_ACCESS_KEY.",
    700003 => "Timestamp outside recvWindow: this server's clock is off. Run: timedatectl set-ntp true",
    700007 => "This key lacks the permission for that endpoint. Enable 'Account: read' (spot) on the key.",
    10007  => "Symbol/permission issue: enable spot account read permission on the key.",
);
my %KUCOIN_HINTS = (
    400003 => "KC-API-KEY not found: the key was deleted, regenerated, or mistyped.",
    400004 => "KC-API-PASSPHRASE wrong: it is the passphrase you typed when creating the key, not your login password.",
    400005 => "Signature error: KUCOIN_SECRET does not match the key.",
    400006 => "This server's IP is not on the key's IP whitelist (or the key's whitelist blocks it).",
    400007 => "Access denied: the key lacks the 'General' permission needed to read balances and transfers.",
    400100 => "Parameter error from KuCoin - report the raw message below.",
);

my @captured;
local $SIG{__WARN__} = sub { push @captured, $_[0]; };

sub raw_error {
    my $text = join('', @captured);
    @captured = ();
    $text =~ s/\s+$//;
    return $text;
}

sub explain {
    my ($raw, $hints) = @_;
    return '' unless length $raw;
    my ($code) = $raw =~ /"code"\s*:\s*"?(\d+)"?/;
    my $hint = $code && $hints->{$code} ? "\n    hint:  $hints->{$code}" : '';
    return "\n    reply: $raw$hint";
}

print "=" x 60, "\n", "ERGO MM - API key check\n", "=" x 60, "\n";
load_api_keys();
print raw_error(), "\n";

my $ua = create_http_client(20);

my $ip = $ua->get('https://api.ipify.org');
print "Public IPv4 of this server (for exchange IP whitelists): ",
      ($ip->is_success ? $ip->decoded_content : "unknown (" . $ip->status_line . ")"), "\n\n";

# ---------------- MEXC
if ($API_KEYS{MEXC_ACCESS_KEY} && $API_KEYS{MEXC_SECRET_KEY}) {
    printf "MEXC key %s... (%d chars), secret %d chars\n",
        substr($API_KEYS{MEXC_ACCESS_KEY}, 0, 6), length($API_KEYS{MEXC_ACCESS_KEY}), length($API_KEYS{MEXC_SECRET_KEY});

    my $balances = fetch_mexc_balance($ua);
    if ($balances) {
        printf "  account (balances / open orders) ... OK   ERG %.2f, USDT %.2f\n",
            $balances->{ERG}{total} // 0, $balances->{USDT}{total} // 0;
    } else {
        print "  account (balances / open orders) ... FAILED", explain(raw_error(), \%MEXC_HINTS), "\n";
    }

    foreach my $currency ('ERG', 'USDT') {
        my $transfers = fetch_mexc_transfers($ua, $currency);
        if ($transfers) {
            printf "  %-4s deposit/withdrawal history ..... OK   %d in the last 7 days\n", $currency, scalar(@$transfers);
        } else {
            print "  $currency deposit/withdrawal history ..... FAILED", explain(raw_error(), \%MEXC_HINTS), "\n";
        }
    }
} else {
    print "MEXC: no key configured (MEXC_ACCESS_KEY / MEXC_SECRET_KEY)\n";
}
print "\n";

# ---------------- KuCoin
if ($API_KEYS{KUCOIN_KEY} && $API_KEYS{KUCOIN_SECRET} && $API_KEYS{KUCOIN_PASSPHRASE}) {
    printf "KuCoin key %s... (%d chars), secret %d chars, passphrase %d chars\n",
        substr($API_KEYS{KUCOIN_KEY}, 0, 6), length($API_KEYS{KUCOIN_KEY}), length($API_KEYS{KUCOIN_SECRET}), length($API_KEYS{KUCOIN_PASSPHRASE});

    my $balances = fetch_kucoin_balance($ua);
    if ($balances) {
        printf "  account (balances / open orders) ... OK   ERG %.2f, USDT %.2f\n",
            $balances->{ERG}{total} // 0, $balances->{USDT}{total} // 0;
    } else {
        print "  account (balances / open orders) ... FAILED", explain(raw_error(), \%KUCOIN_HINTS), "\n";
    }

    foreach my $currency ('ERG', 'USDT') {
        my $transfers = fetch_kucoin_transfers($ua, $currency);
        if ($transfers) {
            printf "  %-4s deposit/withdrawal history ..... OK   %d in the last 7 days\n", $currency, scalar(@$transfers);
        } else {
            print "  $currency deposit/withdrawal history ..... FAILED", explain(raw_error(), \%KUCOIN_HINTS), "\n";
        }
    }
} else {
    print "KuCoin: no key configured (KUCOIN_KEY / KUCOIN_SECRET / KUCOIN_PASSPHRASE)\n";
}

print "\nDone. Fix anything marked FAILED, re-run this script, then run: perl monitor.pl\n";

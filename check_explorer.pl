#!/usr/bin/perl
# ============================================================
# ERGO MM - explorer check
#
# Shows exactly what the Ergo explorer returns for one address
# and how monitor.pl would classify each transaction. Use it when
# the Flows tab stays empty for an address that clearly has
# activity, or to confirm an address before adding it in Settings.
#
#   perl check_explorer.pl <ergo-address> [explorer-url]
# ============================================================

use strict;
use warnings;
use FindBin;
use JSON;

require "$FindBin::Bin/monitor.pl";   # main() is skipped when require'd

my $address  = shift or die "usage: perl check_explorer.pl <ergo-address> [explorer-url]\n";
my $base_url = shift || 'https://api.ergoplatform.com';
$base_url =~ s{/+$}{};

my ($clean) = parse_address_list($address);
die "'$address' is not a base58 string, so it cannot be an Ergo address\n" unless $clean;

my $ua   = create_http_client(30);
my $json = JSON->new->pretty->canonical;

print "Explorer: $base_url\nAddress:  $address\n\n";

my ($balance, $status) = fetch_address_balance_erg($ua, $base_url, $address);
print "GET /addresses/<addr>/balance/confirmed  ->  HTTP ", ($status // '?'), ", ",
      (defined $balance ? sprintf("%.4f ERG", $balance) : 'no balance in reply'), "\n";
print "  HTTP 400 means the explorer does not consider this a valid address.\n" if ($status // 0) == 400;

my ($data, $status2) = explorer_get($ua, $base_url, "/api/v1/addresses/$address/transactions?offset=0&limit=5");
print "GET /addresses/<addr>/transactions?limit=5  ->  HTTP ", ($status2 // '?'), "\n";

unless ($data && ref $data eq 'HASH') {
    print "  no JSON object in the reply\n";
    exit 1;
}

print "  top-level keys: ", join(', ', sort keys %$data), "\n";
print "  total: ", ($data->{total} // 'n/a'), "\n";
my $items = ref $data->{items} eq 'ARRAY' ? $data->{items} : [];
print "  items: ", scalar(@$items), "\n";

if (@$items) {
    my $first = $items->[0];
    print "  item keys:         ", join(', ', sort keys %$first), "\n";
    print "  first input keys:  ", join(', ', sort keys %{ (ref $first->{inputs} eq 'ARRAY' && $first->{inputs}[0]) || {} }), "\n";
    print "  first output keys: ", join(', ', sort keys %{ (ref $first->{outputs} eq 'ARRAY' && $first->{outputs}[0]) || {} }), "\n\n";

    my %set = ($address => 1);
    print "How monitor.pl reads them (this address as the only tracked wallet):\n";
    foreach my $tx (@$items) {
        my $flow = classify_exchange_tx($tx, \%set);
        printf "  %-14s height=%-8s confirmations=%-6s timestamp=%-14s -> %-3s %12.4f ERG  from/to %s\n",
            substr(($tx->{id} // $tx->{txId} // '?'), 0, 12) . '..',
            $tx->{inclusionHeight} // $tx->{height} // '?',
            $tx->{numConfirmations} // '?',
            $tx->{timestamp} // '?',
            uc($flow->{direction}), $flow->{amount_erg},
            defined $flow->{counterparty} ? substr($flow->{counterparty}, 0, 12) . '..' : '-';
    }

    my $raw = $json->encode($first);
    $raw = substr($raw, 0, 3000) . "\n... (truncated)\n" if length $raw > 3000;
    print "\nRaw first item:\n$raw\n";
} else {
    print "  The explorer lists no transactions for this address.\n";
}

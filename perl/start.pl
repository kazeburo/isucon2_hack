#!/usr/bin/perl

use strict;
use warnings;
use Test::TCP;
use Proclet::Declare;
use Proc::Guard;
use DBIx::Sunny;
use JSON 'decode_json';
use FindBin;
use Cache::Memcached::Fast;

my $port = empty_port();

my $root_dir = $FindBin::Bin;
my $config = do {
    my $env = $ENV{ISUCON_ENV} || 'local';
    open(my $fh, '<', $root_dir . "/../config/hosts.${env}.json") or die $!;
    my $json = do { local $/; <$fh> };
    close($fh);
    decode_json($json);
};

my $memd = proc_guard('memcached/bin/memcached', '-p', $port, '-U', '0', '-m','256','-C','-B','ascii');
sleep 2;

my $host = $config->{servers}{database}[0] || '127.0.0.1';
my $dbname = $config->{servers}{dbname} || 'isucon2';
my $dbh = DBIx::Sunny->connect("dbi:mysql:${dbname};host=${host}", 'isucon2app', 'isunageruna');
my $memcached = Cache::Memcached::Fast->new({
    servers => [ { address => 'localhost:'.$port, noreply => 1} ],
});

my $stocks = $dbh->select_all('SELECT seat_id, rid FROM stock');
for my $stock ( @$stocks ) {
    $memcached->set('rid:'.$stock->{rid}, $stock->{seat_id});
}

my $count_stocks = $dbh->select_all(
    'SELECT variation_id, MAX(order_id) as order_id, COUNT(*) as count FROM stock GROUP BY variation_id');
for my $stock ( @$count_stocks ) {
    $memcached->set('max_id:'.$stock->{variation_id}, $stock->{count});
    my $vari_id = $stock->{order_id} - $stock->{variation_id} * 100_000;
    $vari_id = 0 if $vari_id < 0;
    $memcached->set('vari_id:'.$stock->{variation_id}, $vari_id);
}

open(my $fh, "buy.lua.tx");
open(my $lua, ">","buy.lua");
while (<$fh> ) {
    s/<MEMCACHED_PORT>/$port/;
    print $lua $_
}

warn "finish initialize";

env(
    PLACK_ENV => 'production',
    LM_COLOR => 1,
    MEMCACHED_PORT => $port,
);

service('nginx','ngx/nginx/sbin/nginx');
service('web', 'plackup', '-s', 'Starman', '--workers=50', '--max-requests=5000', '--preload-app', '-a', 'app.psgi', '-e', 'enable AxsLog, response_time =>1');
service('worker', $^X, 'worker.pl');

run();



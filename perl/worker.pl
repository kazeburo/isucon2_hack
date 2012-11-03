#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use Kossy;

use DBIx::Sunny;
use JSON 'decode_json';
use FindBin;
use Text::Xslate;
use File::Copy;
use IO::Compress::Gzip qw/gzip/;
use Cache::Memcached::Fast;
use Time::HiRes;
use File::Temp;

my $root_dir = $FindBin::Bin;
my $config = do {
    my $env = $ENV{ISUCON_ENV} || 'local';
    open(my $fh, '<', $root_dir . "/../config/hosts.${env}.json") or die $!;
    my $json = do { local $/; <$fh> };
    close($fh);
    decode_json($json);
};

my $recent_sold;
my $tx = Text::Xslate->new(
    path => $root_dir . '/views',
    cache_dir => File::Temp::tempdir( CLEANUP => 1 ),
);
sub render {
    my ($path,$template,$data) = @_;
    $data->{c}->{stash} = {
        recent_sold => $recent_sold,
    };
    my $html = $tx->render($template, $data);
    $html = Encode::encode_utf8($html);
    my $filename = $root_dir . '/pages' . $path;
    my $filename_gz = $root_dir . '/pages' . $path . '.gz';
    my $tmpfilename = $filename .'.'. int(rand(100));
    my $tmpfilename_gz = $tmpfilename .'.gz';
    mkdir "$root_dir/pages";
    mkdir "$root_dir/pages/ticket";
    mkdir "$root_dir/pages/artist";
    open my $fh , '>', $tmpfilename;
    print $fh $html;
    close $fh;
    gzip \$html, $tmpfilename_gz;
    move($tmpfilename, $filename);
    move($tmpfilename_gz, $filename_gz);
#    warn "$path = $template";
}


my $host = $config->{servers}{database}[0] || '127.0.0.1';
my $dbname = $config->{servers}{dbname} || 'isucon2';

my $dbh = DBIx::Sunny->connect("dbi:mysql:${dbname};host=${host}", 'isucon2app', 'isunageruna');
my $memcached = Cache::Memcached::Fast->new({
    servers => ['localhost:'.$ENV{MEMCACHED_PORT}],
});



while ( 1 ) {
    my $start_time = Time::HiRes::time();
    eval {
        $dbh->select_one('SELECT GET_LOCK("initdb",60)');
        my $variations = $dbh->select_all('SELECT id FROM variation');
        foreach my $variation ( @$variations ) {
            my $rid = $memcached->get('vari_id:'.$variation->{id});
            
            $dbh->query('UPDATE stock SET order_id = rid WHERE rid <= ? AND variation_id = ? AND order_id = 0', 
                        $variation->{id} * 100_000 + $rid , $variation->{id});
        }
        $dbh->select_one('SELECT RELEASE_LOCK("initdb")');

        my $variation_all = $dbh->select_all(
            'SELECT variation.id as id, variation.name AS v_name, ticket.name AS t_name, artist.name AS a_name FROM variation
               JOIN ticket ON variation.ticket_id = ticket.id
               JOIN artist ON ticket.artist_id = artist.id'
        );
        my %variation_tbl = map {
            $_->{id} => $_
        } @$variation_all;

        my $recent_sold_min = $dbh->select_all('SELECT seat_id, variation_id FROM stock WHERE order_id > 0 ORDER BY order_id DESC LIMIT 5');
        $recent_sold = [ map {
            {
                %$_,
                %{$variation_tbl{$_->{variation_id}}}
            }
        } @$recent_sold_min ];

        # /
        my $artists = $dbh->select_all(
            'SELECT * FROM artist ORDER BY id',
        );
        {
            render('/index.html','index.tx', { artists => $artists });
        }

        # /artist/%d
        my $tickets = $dbh->select_all(
            'SELECT t.*, a.name AS artist_name FROM ticket t INNER JOIN artist a ON t.artist_id = a.id',
        );

        for my $artist ( @$artists ) {
            my @tickets = grep { $_->{artist_id} == $artist->{id} } @$tickets;
            for my $ticket (@tickets) {
                my $count = $dbh->select_one(
                    'SELECT COUNT(*) FROM variation
                         INNER JOIN stock ON stock.variation_id = variation.id
                         WHERE variation.ticket_id = ? AND stock.order_id = 0',
                    $ticket->{id},
                );
                $ticket->{count} = $count;
            }
            render('/artist/'.$artist->{id},'artist.tx', {
                artist  => $artist,
                tickets => \@tickets,
            });
        }

        # /ticket/%d
        for my $ticket ( @$tickets ) {
            my $variations = $dbh->select_all(
                'SELECT id, name FROM variation WHERE ticket_id = ? ORDER BY id',
                $ticket->{id},
            );
            for my $variation (@$variations) {
                $variation->{vacancy} = $dbh->select_one('SELECT COUNT(*) FROM stock WHERE variation_id = ? AND order_id = 0', $variation->{id});
                $variation->{vacancy} = 0 if $variation->{vacancy} < 0;
                my %seats;
                if ( $variation->{vacancy} > 0 ) {
                    my $seats = $dbh->selectall_arrayref(
                        'SELECT seat_id FROM stock WHERE variation_id = ? AND order_id > 0',
                        { Slice => [0] },
                        $variation->{id},
                    );
                    %seats = map { $_->[0] => 1 } @$seats;
                }
                my $tbl = '';
                for my $row ( 0..63 ) {
                    $tbl .= "<tr>\n";
                    for my $col ( 0..63 ) {
                        my $key = sprintf '%02d-%02d', $row, $col;
                        my $avail = ($variation->{vacancy} == 0 || exists $seats{$key}) ? 'unavailable' : 'available';
                        $tbl .= qq!<td id="$key" class="$avail"></td>\n!;
                    }
                    $tbl .= "</tr>\n";
                }
                $variation->{tblhtml} = $tbl;
            }
            render('/ticket/'.$ticket->{id},'ticket.tx', {
                ticket     => $ticket,
                variations => $variations,
            });
        }        
    }; #eval
    warn $@ if $@;
#    warn "========= finish  === " . localtime();
    my $end_time = Time::HiRes::time();
    my $ela = $end_time - $start_time;
    warn sprintf('elaplsed %s, [%s]', $ela, scalar localtime()) if $ela > 0.7;
    select undef, undef, undef, 0.2;
} #while

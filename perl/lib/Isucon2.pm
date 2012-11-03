package Isucon2;
use strict;
use warnings;
use utf8;

use Kossy;

use DBIx::Sunny;
use JSON 'decode_json';
use List::Util qw/shuffle/;
use Cache::Memcached::Fast;

sub load_config {
    my $self = shift;
    $self->{_config} ||= do {
        my $env = $ENV{ISUCON_ENV} || 'local';
        open(my $fh, '<', $self->root_dir . "/../config/hosts.${env}.json") or die $!;
        my $json = do { local $/; <$fh> };
        close($fh);
        decode_json($json);
    };
}

sub memcached {
    my ($self) = @_;
    $self->{_memcached} ||= do {
        Cache::Memcached::Fast->new({
            servers => [ { address => 'localhost:'.$ENV{MEMCACHED_PORT}, noreply => 1} ],
        });
    };
}

sub dbh {
    my ($self) = @_;
    $self->{_dbh} ||= do {
        my $config = $self->load_config;
        my $host = $config->{servers}{database}[0] || '127.0.0.1';
        my $dbname = $config->{servers}{dbname} || 'isucon2';
        DBIx::Sunny->connect(
            "dbi:mysql:${dbname};host=${host}", 'isucon2app', 'isunageruna', {
                RaiseError => 1,
                PrintError => 0,
                ShowErrorStatement  => 1,
                AutoInactiveDestroy => 1,
                mysql_enable_utf8   => 1,
            },
        );
    };
}

filter 'recent_sold' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        $c->stash->{recent_sold} = $self->dbh->select_all(
            'SELECT stock.seat_id, variation.name AS v_name, ticket.name AS t_name, artist.name AS a_name FROM stock
               JOIN variation ON stock.variation_id = variation.id
               JOIN ticket ON variation.ticket_id = ticket.id
               JOIN artist ON ticket.artist_id = artist.id
             WHERE order_id IS NOT NULL
             ORDER BY order_id DESC LIMIT 10',
        );
        $app->($self, $c);
    }
};

get '/' => [qw(recent_sold)] => sub {
    my ($self, $c) = @_;
    my $rows = $self->dbh->select_all(
        'SELECT * FROM artist ORDER BY id',
    );
    $c->render('index.tx', { artists => $rows });
};

get '/artist/:artistid' => [qw(recent_sold)] => sub {
    my ($self, $c) = @_;
    my $dbh = $self->dbh;
    my $artist = $dbh->select_row(
        'SELECT id, name FROM artist WHERE id = ? LIMIT 1',
        $c->args->{artistid},
    );
    my $tickets = $dbh->select_all(
        'SELECT id, name FROM ticket WHERE artist_id = ? ORDER BY id',
        $artist->{id},
    );
    for my $ticket (@$tickets) {
        my $count = $dbh->select_one(
            'SELECT COUNT(*) FROM variation
             INNER JOIN stock ON stock.variation_id = variation.id
             WHERE variation.ticket_id = ? AND stock.order_id IS NULL',
            $ticket->{id},
        );
        $ticket->{count} = $count;
    }
    $c->render('artist.tx', {
        artist  => $artist,
        tickets => $tickets,
    });
};

get '/ticket/:ticketid' => [qw(recent_sold)] => sub {
    my ($self, $c) = @_;
    my $dbh = $self->dbh;
    my $ticket = $dbh->select_row(
        'SELECT t.*, a.name AS artist_name FROM ticket t INNER JOIN artist a ON t.artist_id = a.id WHERE t.id = ? LIMIT 1',
        $c->args->{ticketid},
    );
    my $variations = $dbh->select_all(
        'SELECT id, name FROM variation WHERE ticket_id = ? ORDER BY id',
        $ticket->{id},
    );
    for my $variation (@$variations) {
        $variation->{stock} = $dbh->selectall_hashref(
            'SELECT seat_id, order_id FROM stock WHERE variation_id = ?',
            'seat_id',
            {},
            $variation->{id},
        );
        $variation->{vacancy} = $dbh->select_one(
            'SELECT COUNT(*) FROM stock WHERE variation_id = ? AND order_id IS NULL',
            $variation->{id},
        );
    }
    $c->render('ticket.tx', {
        ticket     => $ticket,
        variations => $variations,
    });
};

my %max_ids;
post '/buy' => sub {
    my ($self, $c) = @_;
    my $variation_id = $c->req->param('variation_id');
    my $member_id = $c->req->param('member_id');

    my $memcached = $self->memcached;

    $max_ids{$variation_id} ||= $memcached->get('max_id:'.$variation_id);

    my $rid = $memcached->incr('vari_id:'.$variation_id);
    if ( $rid > $max_ids{$variation_id} ) {
        return $c->render('soldout.tx');
    }

    $rid = $variation_id * 100_000 + $rid;

    my $seat_id = $self->memcached->get('rid:'.$rid);
    $c->render('complete.tx', { seat_id => $seat_id, member_id => $member_id });
};

# admin

get '/admin' => sub {
    my ($self, $c) = @_;
    $c->render('admin.tx')
};

get '/admin/order.csv' => sub {
    my ($self, $c) = @_;
    $c->res->content_type('text/csv');
    my $orders = $self->dbh->select_all(
        'SELECT order_request.*, stock.seat_id, stock.variation_id, stock.updated_at
         FROM order_request JOIN stock ON order_request.id = stock.order_id
         ORDER BY order_request.id ASC',
    );
    my $body = '';
    for my $order (@$orders) {
        $body .= join ',', @{$order}{qw( id member_id seat_id variation_id updated_at )};
        $body .= "\n";
    }
    $c->res->body($body);
    $c->res;
};


post '/admin' => sub {
    my ($self, $c) = @_;
    my $dbh = $self->dbh;
    my $memcached = $self->memcached;
    $dbh->select_one('SELECT GET_LOCK("initdb",60)');
    for (qw/artist idpot order_request stock ticket variation/) {
        $dbh->query('TRUNCATE TABLE '.$_);
    }
    open(my $fh, '<', $self->root_dir . '/mydata.sql') or die $!;
    for my $sql (<$fh>) {
        chomp $sql;
        $dbh->query($sql) if $sql;
    }

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

    $dbh->select_one('SELECT RELEASE_LOCK("initdb")');

=pod
    open(my $fh, '<', $self->root_dir . '/../config/database/initial_data.sql') or die $!;
    for my $sql (<$fh>) {
        chomp $sql;
        $self->dbh->query($sql) if $sql;
    }
    $self->dbh->select_one('SELECT GET_LOCK("idpot_lock",60)');
    $self->dbh->query('TRUNCATE TABLE idpot');
    my $variations = $self->dbh->select_all(
        'SELECT id, name FROM variation ORDER BY id',
    );
    for my $variation (@$variations) {
        my $stock_count = $self->dbh->select_one('SELECT COUNT(*) FROM stock WHERE variation_id = ?',$variation->{id});
        $self->dbh->query('INSERT INTO idpot (variation_id, id, max_id) VALUES (?,?,?)', $variation->{id}, 0, $stock_count);
        my @rid = shuffle( 1..$stock_count );
        my $rows = $self->dbh->select_all('SELECT id FROM stock WHERE variation_id = ?', $variation->{id});
        for my $row ( @$rows ) {
            my $rid = shift @rid;
            $rid = $variation->{id} * 100_000 + $rid;
            $self->dbh->query('UPDATE stock SET rid = ? WHERE id=?', 
                              $rid, $row->{id});
        }
    }
    $self->dbh->query('UPDATE stock SET order_id = 0');
    $self->dbh->select_one('SELECT RELEASE_LOCK("idpot_lock")');
    close($fh);
=cut

    sleep 3;
    $c->redirect('/admin')
};

1;

package Zonemaster::Distributed::QHandler;

use 5.14.2;
use warnings;

use Moose;
use Store::CouchDB;
use Sys::Hostname;
use List::Util qw[shuffle];
use Time::HiRes qw[time sleep];
use Net::LibIDN qw[idn_to_ascii];
use Log::Log4perl qw[:easy];
use IO::Async::Loop;
use Zonemaster::Distributed::Child

has 'dbhost'   => ( is => 'ro', isa => 'Str',             required   => 1 );
has 'dbname'   => ( is => 'ro', isa => 'Str',             required   => 1 );
has 'dbuser'   => ( is => 'ro', isa => 'Str',             required   => 0 );
has 'dbpass'   => ( is => 'ro', isa => 'Str',             required   => 0 );
has 'limit'    => ( is => 'ro', isa => 'Int',             default    => 10 );
has 'db'       => ( is => 'ro', isa => 'Store::CouchDB',  lazy_build => 1 );
has 'nodename' => ( is => 'ro', isa => 'Str',             default    => sub { hostname() } );
has 'entries'  => ( is => 'ro', isa => 'HashRef',         default    => sub { {} } );
has 'loop'     => ( is => 'ro', isa => 'IO::Async::Loop', default    => sub { IO::Async::Loop->new });
has 'running'  => ( is => 'rw', isa => 'Bool',            default => 1);

###
### Builders
###

sub _build_db {
    my ( $self ) = @_;

    my %args;
    $args{host} = $self->dbhost;
    $args{db}   = $self->dbname;
    $args{user} = $self->dbuser if $self->dbuser;
    $args{pass} = $self->dbpass if $self->dbuser;

    my $db = Store::CouchDB->new( %args );

    return $db;
}

###
### Instance methods
###

# Fetch an unclaimed entry from the database
sub get_new_entry {
    my ( $self ) = @_;

    my @rows = shuffle $self->db->get_view_array( { view => 'dispatch/unclaimed', opts => { limit => 10 } } );
    if ( @rows > 0 ) {
        my $id  = $rows[0]{id};
        my $doc = $self->db->get_doc( $id );

        return $doc;
    }
    else {
        return;
    }
}

# Claim an entry
sub claim_entry {
    my ( $self, $entry ) = @_;

    my %r;
    $r{nodename}   = $self->nodename;
    $r{ulabel}     = $entry->{name};
    $r{alabel}     = idn_to_ascii( $r{ulabel}, 'UTF-8' );
    $r{start_time} = time();

    push @{ $entry->{results} }, \%r;
    $self->db->update_doc( { doc => $entry } );
    $self->start_running_entry( $entry );
    INFO $entry->{name} . " started.";

    return;
}

sub start_running_entry {
    my ( $self, $entry ) = @_;

    my $new_pid = $self->loop->spawn_child(
        code => sub {
            Zonemaster::Distributed::Child->new($entry, $self->db);
        },
        on_exit => sub {
            my ( $exit_pid, $exit_code ) = @_;

            if ($exit_code == 0) {
                INFO "Child with PID $exit_pid exited normally.";
            } else {
                WARN "Child with PID $exit_pid exited with return code $exit_code.";
            }

            delete $self->entries->{$exit_pid};
        }
    );
    $self->entries->{$new_pid} = $entry;
    INFO "Spawned child with PID $new_pid.";
}

sub check_for_conflicts {
    my ( $self ) = @_;

    foreach my $pid ( keys %{ $self->entries } ) {
        my $name = $self->entries->{$pid}{name};
        my $doc  = $self->db->get_doc( $self->entries->{$pid}{_id} );
        if ( defined($doc->{results}[0]{nodename}) and $doc->{results}[0]{nodename} ne $self->nodename ) {
            INFO "Conflict for $name ($pid), killing it.";
            kill 'TERM', $pid;
        }
    }

    return;
}

sub run_loop {
    my ( $self ) = @_;

    INFO "Looping.";
    while ( $self->running ) {
        $self->loop->loop_once(0.1);
        $self->check_for_conflicts();
        sleep(0.1);
        if (scalar(keys %{$self->entries}) < $self->limit) {
            my $new = $self->get_new_entry();
            if ($new) {
                $self->claim_entry($new);
            }
        }
    }
}

1;

package Zonemaster::Distributed::Child;

use 5.14.2;
use warnings;

use Log::Log4perl qw[:easy];
use Zonemaster;
use Zonemaster::Translator;
use Time::HiRes qw[time];

my $trans = Zonemaster::Translator->new;
my $zonemaster = Zonemaster->new;
my @locales = qw[sv_SE.UTF-8 en_US.UTF-8 fr_FR.UTF-8];

sub translate {
    my ( $entry ) = @_;
    my %res;

    foreach my $locale (@locales) {
        $trans->locale($locale);
        $res{$locale} = $trans->translate_tag($entry);
    }

    return \%res;
}

sub log_message {
    my ( $msg, $doc, $db ) = @_;

    if ($msg->numeric_level < 0) {
        return;
    }

    my %h = (
        timestamp => $msg->timestamp,
        tag => $msg->tag,
        module => $msg->module,
        level => $msg->level,
        numeric_level => $msg->numeric_level,
        args => $msg->args,
        translations => translate($msg),
    );
    $doc->{results}[0]{scanner_pid} = $$;
    push @{ $doc->{results}[0]{messages} }, \%h;
    $db->update_doc({ doc => $doc });

    return;
}

sub new {
    my ( $class, $entry, $db ) = @_;
    my $name = $entry->{results}[0]{alabel};

    Zonemaster->logger->callback(sub {
        my ($e) = @_;
        log_message($e, $entry, $db);
    });

    my $r = $entry->{request};
    if ( exists $r->{ds} ) {
        INFO "Adding fake DS for " . $name;
        Zonemaster->add_fake_ds( $name, $r->{ds} );
    }
    if ( exists $r->{ns} ) {
        INFO "Adding fake delegation for " . $name;
        Zonemaster->add_fake_delegation( $name, $r->{ns} );
    }
    if ( exists $r->{ipv4} ) {
        INFO "Setting IPv4 flag for " . $name;
        Zonemaster->config->ipv4_ok( $r->{ipv4} );
    }
    if ( exists $r->{ipv6} ) {
        INFO "Setting IPv6 flag for " . $name;
        Zonemaster->config->ipv6_ok( $r->{ipv6} );
    }

    Zonemaster->test_zone($entry->{results}[0]{alabel});

    $entry->{results}[0]{end_time} = time();
    $db->update_doc({ doc => $entry });

    exit(0);
}

1;
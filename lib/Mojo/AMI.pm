package Mojo::AMI;

use strict;
use warnings;

use Mojo::Base 'Mojo::EventEmitter';

use Data::Dumper;
use Mojo::IOLoop;
use Scalar::Util ();

our $VERSION = '0.2';

my $EOL   = "\015\012";
my $BLANK = $EOL x 2;

has host    => '127.0.0.1:5038';
has user    => 'admin';
has secret  => 'redhat';
has timeout => '0';

sub new {
    my $self = shift->SUPER::new(@_);

    $self->{'ActionID'}       = '1';
    $self->{'expected'}       = undef;
    $self->{'responsebuffer'} = undef;
    $self;
}

sub _error {
    my ($self, $c, $err) = @_;
    my $waiting = $c->{waiting} || $c->{queue};
 
    return if $self->{destroy};
    return $self->_requeue($c)->_connect($c) unless defined $err;
    return $self->$_($err, undef) for grep {$_} map { $_->[0] } @$waiting;
}

sub DESTROY { $_[0]->{destroy} = 1; }

sub _requeue {
  my ($self, $c) = @_;
 
  unshift @{$c->{queue}}, grep { $_->[0] } @{delete $c->{waiting} || []};
  return $self;
}

sub _connect {
    my ( $self, $c ) = @_;

    my $port;
    my $address;
    if  ( $self->host =~ m{^([^:]+)(:(\d+))?} ) {
        $address = $1;
        $port    = $3 || 5038;
    }

    Scalar::Util::weaken $self;
    $self->{id} = $self->_loop()->client(
        {   address => $address,
            port    => $port
        },
        sub {
            my ( $loop, $err, $stream ) = @_;
            if ($err) {
                $self->error($err);
                return;
            }

            $stream->timeout(10);
            $stream->on(
                read => sub {
                    my ( $stream, $chunk ) = @_;
                    $self->_handle_packet( $c, $chunk );
                }
            );
            $stream->on(
                close => sub {
                    $self->_error($c);
                }
            );
            $stream->on(
                error => sub {
                    $self->_error( $c, $_[1] );
                }
            );
            $self->_dequeue($c);
        }
    );
    return $self;
}

sub hash_to_buffer {
    my ( $self, $c ) = @_;

    my $array_ref = $c->{waiting}[-1];
    my $command   = $array_ref->[-1];

    my $action_id = $command->{'ActionID'} || $self->{ActionID}++;
    delete $self->{responsebuffer}->{$action_id};

    $self->{'expected'}->{$action_id} = '1';
    $self->{responsebuffer}->{$action_id}->{'ASYNC'} = $command->{'Async'} || '0';

    delete $command->{'ActionID'};

    my $message = "ActionID: $action_id$EOL";

    for my $key ( sort keys %$command ) {
        if ( ref $command->{$key} ) {
            $message .= "$key: $_$EOL" for @{ $command->{$key} };
        }
        else {
            $message .= "$key: $command->{$key}$EOL";
        }
    }
    $message .= $EOL;    # Message ends with blank line
}

sub _dequeue {
    my ( $self, $c ) = @_;

    my $loop   = $self->_loop();
    my $stream = $loop->stream( $self->{id} ) or return $self;    # stream is not yet connected
    my $queue  = $c->{queue};
    my $buf;

    if ( !$queue->[0] ) {
        return $self;
    }

    push @{ $c->{waiting} }, shift @$queue;
    $buf = $self->hash_to_buffer($c);
    $stream->write($buf);

    $self;
}

sub execute {
    my $cb = ref $_[-1] eq 'CODE' ? pop : undef;

    my ( $self, @cmd ) = @_;

    if ($cb) {
        my $c = $self->{connection} ||= {};
        push @{ $c->{queue} }, [ $cb, @cmd ];

        return $self->_connect($c) unless $c->{id};
        return $self->_dequeue($c);
    }
}

sub _loop {
    Mojo::IOLoop->singleton;
}


sub _handle_packet {
    my ( $self, $c, $buffer ) = @_;

    if ( $buffer =~ s#^(?:Asterisk|Aefirion) Call Manager(?: Proxy)?/(\d+\.\d+\w*)$EOL##is ) {
        return;
    }

    foreach my $packet ( split /\015\012\015\012/ox, $buffer ) {
        my %parsed;
        foreach my $line ( split /\015\012/ox, $packet ) {
            my ( $key, $value ) = split /:\ /x, $line, 2;
            $parsed{$key} = $value;
        }
        if ( exists $parsed{'ActionID'} ) {
            $self->_handle_action( \%parsed, $c );
        }
        elsif ( exists $parsed{'Event'} ) {
            eval $self->emit( $parsed{'Event'} => \%parsed );
        }
    }

    return 1;
}

sub _handle_action {
    my ( $self, $packet, $c ) = @_;

    my $actionid = $packet->{'ActionID'};
    return unless $self->{expected}->{$actionid};

    if (exists $packet->{'Response'} and $packet->{'Response'} eq 'Error') {
        delete $self->{responsebuffer}->{$actionid}->{'ASYNC'};
    }

    if ( exists $packet->{'Event'} ) {
        if ( $packet->{'Event'} =~ /[cC]omplete/ox ) {
            $self->{responsebuffer}->{$actionid}->{'COMPLETED'} = 1;
        }
        else {
            if (   $packet->{'Event'} eq 'DBGetResponse'
                || $packet->{'Event'} eq 'OriginateResponse' )
            {
                $self->{responsebuffer}->{$actionid}->{'COMPLETED'} = 1;
            }
            push( @{ $self->{responsebuffer}->{$actionid}->{'EVENTS'} }, $packet );
        }
    }
    elsif ( exists $packet->{'Response'} ) {

        #If No indication of future packets, mark as completed
        if ( $packet->{'Response'} ne 'Follows' or $packet->{'Response'}) {
            if ( !$self->{responsebuffer}->{$actionid}->{'ASYNC'}
                && ( !exists $packet->{'Message'} || $packet->{'Message'} !~ /[fF]ollow/ox ) )
            {
                $self->{responsebuffer}->{$actionid}->{'COMPLETED'} = 1;
            }
        }

        #Copy the response into the buffer
        foreach ( keys %{$packet} ) {
            if ( $_ =~ /^(?:Response|Message|ActionID|Privilege|CMD|COMPLETED)$/ox ) {
                $self->{responsebuffer}->{$actionid}->{$_} = $packet->{$_};
            }
            else {
                $self->{responsebuffer}->{$actionid}->{'PARSED'}->{$_} = $packet->{$_};
            }
        }
    }

    if ( $self->{responsebuffer}->{$actionid}->{'COMPLETED'} ) {

        #This aciton is finished do not accept any more packets for it
        delete $self->{expected}->{$actionid};

        #Determine goodness, do callback
        $self->_action_complete( $actionid, $c );
    }
}

sub _action_complete {
    my ( $self, $actionid, $c ) = @_;

    my $op = shift @{ $c->{waiting} || [] };
    my $cb = $op->[0];

    if ( ref $cb eq 'CODE' ) {
       
       if (defined $self->{responsebuffer}->{$actionid}->{'Response'}
           && $self->{responsebuffer}->{$actionid}->{'Response'} =~ /^(?:Success|Follows|Goodbye|Events Off|Pong)$/ox) {
           $self->{responsebuffer}->{$actionid}->{'GOOD'} = 1;
        }


        my $response = $self->{responsebuffer}->{$actionid};
        delete $self->{responsebuffer}->{$actionid};
        delete $response->{'ASYNC'};

        if (exists $response->{'GOOD'}) {
            $self->$cb( undef, $response );
        }
        else {
            $self->$cb( $response, undef );
        }
        $self->_dequeue($c);
    }
    return 1;
}

1;

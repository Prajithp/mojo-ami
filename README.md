## NAME
    Mojo::AMI - Pure-Perl non-blocking I/O Asterisk Manager Interface, Mojo version
 
### VERSION
    0.2

### DESCRIPTION
    This module provides a dependable, event-based interface to the asterisk manager interface. http://www.voip-info.org/wiki/view/Asterisk+manager+API
    This is done with Mojo::IoLoop

### TODO
   * Automatic login support whenever it connects to AMI
   * Update documentation.
   * Add support for blocking connections as well.
   * 

### SYNOPSIS
```perl
    my $ast = AMI->new(user => 'admin', secret => 'redhat');
    
    my $loop = Mojo::IOLoop->delay(
        sub {
          my $delay = shift;
          $ast->execute({ Action => 'Login', Username => $ast->user, Secret => $ast->secret }, 
          $delay->begin)->execute({ Action => 'QueueStatus', 'Async' => '1'}, $delay->begin);
        },
        sub {
            my ($delay, $err, $response, $err2, $response2) = @_;
            print Dumper $response2;
        }
    )->wait;
```
### Constructor
#### new
```perl
    my $astman = Mojo::AMI->new(
        host   => 'localhost',
        user   => 'username',
        secret => 'test',
    );
```
#### Supported args are:
```perl
    host       Asterisk host.  Defaults to '127.0.0.1'.
    user       Manager user.
    secret     Manager secret.
```
### Actions
#### execute
```perl
    $astman->execute({ Action => 'QueueStatus', 'Async' => '1'}, $delay->begin);
```
Sends a command to asterisk.

The command will wait for the specific response from asterisk (identified with an ActionID). Otherwise it returns immediately.
Returns a hash or hash-ref on success (depending on wantarray), undef on timeout.


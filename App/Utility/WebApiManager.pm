package Amiseq::App::Utility::WebApiManager;

use strict;
use warnings;
use Carp qw(croak);
use LWP::UserAgent;
use HTTP::Request;
use IO::Socket::SSL;
use SOAP::Lite ();

## retryable HTTP status codes
our %RETRYABLE_HTTP = map { $_ => 1 } (500, 502, 503, 504);

sub new {
    my ($class, $config) = @_;

    # config must be a HASHREF
    $config ||= {};

    my $self = {
        default_timeout => $config->{timeout}  // 10,
        default_retry   => $config->{retry}    // 3,
        default_backoff => $config->{backoff}  // 1,
        ssl_verify      => $config->{ssl_verify} // 1,
    };

    return bless $self, $class;
}

############################################
# UNIVERSAL REST HTTP REQUEST CALLER
############################################
sub rest_http_request {
    my ($self, %args) = @_;

    croak "url is required"    unless $args{url};
    croak "method is required" unless $args{method};

    my $url     = $args{url};
    my $method  = uc $args{method};
    my $headers = $args{headers} // {};
    my $body    = $args{body};

    my $timeout = $args{timeout} // $self->{default_timeout};
    my $retries = $args{retry}   // $self->{default_retry};
    my $backoff = $args{backoff} // $self->{default_backoff};

    my $ssl_mode = $self->{ssl_verify}
        ? IO::Socket::SSL::SSL_VERIFY_PEER()
        : IO::Socket::SSL::SSL_VERIFY_NONE();

    my $ua = LWP::UserAgent->new(
        timeout => $timeout,
        ssl_opts => {
            verify_hostname => $self->{ssl_verify},
            SSL_verify_mode => $ssl_mode,
        }
    );

    my $req = HTTP::Request->new($method => $url);

    for my $key (keys %$headers) {
        $req->header($key => $headers->{$key});
    }

    $req->content($body) if defined $body;

    for my $attempt (1 .. $retries) {

        my $res = $ua->request($req);
        my $code = $res->code;

        # 1) Success
        return $res if $res->is_success;

        # 2) Client error - DO NOT retry
        if ($code =~ /^(400|401|403|404|406|409|422)$/) {
            warn "[REST] Client error HTTP $code. Not retriable.\n";
            return $res;
        }

        # 3) Server transient error - RETRY
        if ($RETRYABLE_HTTP{$code}) {
            warn "[REST] Transient error HTTP $code. Retrying...\n";
            goto RETRY if $attempt < $retries;
            return $res;
        }

        # 4) Everything else - DO NOT retry
        warn "[REST] Non-transient error HTTP $code. Not retriable.\n";
        return $res;

        # Retry block
        RETRY:
        my $wait = $backoff + rand(0.3);
        warn "[REST] Retry attempt $attempt of $retries in $wait seconds...\n";
        sleep $wait;
        $backoff *= 2;
    }
}

############################################
# SOAP API CALLER (unchanged logic)
############################################
sub soap_http_request {
    my ($self, %args) = @_;

    croak "url is required"    unless $args{url};
    croak "method is required" unless $args{method};

    my $url       = $args{url};
    my $soap_func = $args{method};
    my $params    = $args{params} // [];

    my $timeout = $args{timeout} // $self->{default_timeout};
    my $retries = $args{retry}   // $self->{default_retry};
    my $backoff = $args{backoff} // $self->{default_backoff};
    my $use_jitter = exists $self->{jitter} ? $self->{jitter} : 1;

    my $ssl_mode = $self->{ssl_verify}
        ? IO::Socket::SSL::SSL_VERIFY_PEER()
        : IO::Socket::SSL::SSL_VERIFY_NONE();

    my $soap = SOAP::Lite
        ->proxy($url)
        ->readable(1);

    $soap->transport->timeout($timeout);
    $soap->transport->ssl_opts(
        verify_hostname => $self->{ssl_verify},
        SSL_verify_mode => $ssl_mode
    );

    for my $attempt (1 .. $retries) {

        my $response;
        eval {
            $response = $soap->$soap_func(@$params);
        };

        my $err = $@;

        if ($err) {
            warn "[SOAP] Internal error: $err\n";
            goto RETRY if $attempt < $retries;
            return { fault => 1, faultstring => $err };
        }

        my $http = $soap->transport->http_response;
        my $code = $http ? $http->code : 0;

        unless ($response) {
            warn "[SOAP] No response from server\n";
            goto RETRY if $attempt < $retries;
            return undef;
        }

        if (!$response->fault && ($code == 200)) {
            return $response;
        }

        if ($response->fault) {
            my $fault_code   = $response->faultcode  // "";
            my $fault_string = $response->faultstring // "Unknown SOAP fault";

            if ($fault_code =~ /(Client|Auth|Invalid|Unauthorized|Forbidden)/i) {
                warn "[SOAP] Client fault: $fault_string. Not retriable.\n";
                return $response;
            }

            if ($fault_code =~ /(Server|Unavailable|Timeout|Internal)/i) {
                goto RETRY if $attempt < $retries;
                return $response;
            }

            warn "[SOAP] Unknown fault type: $fault_string\n";
            return $response;
        }

        if ($RETRYABLE_HTTP{$code}) {
            warn "[SOAP] HTTP $code retryable\n";
            goto RETRY if $attempt < $retries;
            return $response;
        }

        return $response;

        RETRY:
        my $wait = $backoff;
        $wait += rand(0.3) if $use_jitter;
        warn "[SOAP] Retry $attempt in $wait seconds...\n";
        sleep $wait;
        $backoff *= 2;
    }

    return undef;
}

1;

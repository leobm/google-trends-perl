package Google::Trends;
use v5.24.1;
use strict;
use warnings;

use utf8;
use Carp;
use HTTP::Tiny;
use JSON::PP;
use HTTP::CookieJar;
use URI::Escape;
use Time::Piece;
use List::Util qw/reduce/;
use List::MoreUtils qw/firstidx firstres/;
use lib './lib';
use Google::Trends::Utils;

our $VERSION = "0.01";

use constant BASE_TRENDS_URL => 'https://trends.google.com/trends';
use constant GENERAL_URL => BASE_TRENDS_URL . '/api/explore';
use constant INTEREST_OVER_TIME_URL =>  BASE_TRENDS_URL. '/api/widgetdata/multiline';
use constant MULTIRANGE_INTEREST_OVER_TIME_URL => BASE_TRENDS_URL. '/api/widgetdata/multirange';
use constant INTEREST_BY_REGION_URL =>  BASE_TRENDS_URL. '/api/widgetdata/comparedgeo';
use constant RELATED_QUERIES_URL => BASE_TRENDS_URL. '/api/widgetdata/relatedsearches';
use constant TRENDING_SEARCHES_URL => BASE_TRENDS_URL. '/hottrends/visualize/internal/data';
use constant TOP_CHARTS_URL => BASE_TRENDS_URL. '/api/topcharts';
use constant SUGGESTIONS_URL => BASE_TRENDS_URL. '/api/autocomplete/';
use constant CATEGORIES_URL => BASE_TRENDS_URL. '/api/explore/pickers/category';
use constant TODAY_SEARCHES_URL => BASE_TRENDS_URL. '/api/dailytrends';
use constant REALTIME_TRENDING_SEARCHES_URL => BASE_TRENDS_URL. '/api/realtimetrends';

use constant ALLOWED_TIME_FRAMES => ('now 1-H', 'now 4-H', 'now 1-d', 'now 7-d', 'today 1-m', 'today 3-m','today 12-m','today 5-y');
use constant ALLOWED_GPROPS => ('', 'images', 'news', 'youtube', 'froogle');
use constant ERROR_CODES => [500, 502, 504, 429];
use constant GET_METHOD => 'get';
use constant POST_METHOD => 'post';

sub new {
    my ($class, %args) = @_;

    my $options = {
        hl => $args{hl} // 'en-US', 
        tz =>  $args{tz} // 360, 
        geo =>  $args{geo} // '', 
        timeout => $args{timeout} // 5, ## seconds
        proxies => $args{proxies} // [],
        retries => $args{retries} // 0, 
        backoff_factor => $args{backoff_factor} // 0, 
        requests_args => $args{requests_args} // {} 
    };
    
    my @not_in_options = _not_in_options($options, keys %args);
    if (@not_in_options) {
        croak "the constructor was called with an unknown option '".join("','", @not_in_options)."'!";
    }
   
    my $props  = {
        google_rl => 'You have reached your quota limit. Please try again later.',
        results => undef,
        proxy_index => 0,
        token_payload => {},
        interest_over_time_widget => {},
        interest_by_region_widget => {},
        related_topics_widget_list => [],
        related_queries_widget_list => [],
        headers => {'accept-language' =>  $options->{hl}},
        cookie_jar => HTTP::CookieJar->new,
    };
    ## TODO
    ##self.headers.update(self.requests_args.pop('headers', {}))

    my $self = bless {
        %$options, %$props 
    }, $class;

    ## initialize
    $self->get_google_cookie();
    $self;
}

sub build_payload {
    my ($self, %args) = @_;

    if  (_is_arg_not_of($args{timeframe}, ALLOWED_TIME_FRAMES)) {
        croak "timeframe arg '$args{timeframe}' is not valid!";
    }

    if (_is_arg_not_of($args{gprop}, ALLOWED_GPROPS)) {
        croak "gprop arg must be empty (to indicate web), images, news, youtube, or froogle";
    }

    my $options = {
        kw_list => $args{kw_list} // [], 
        cat => $args{cat} // 0, 
        timeframe => $args{timeframe} // 'today 5-y', 
        geo => $args{geo} // '',
        gprop => $args{gprop} // '',
        locale =>  $args{locale}
    };

    my @not_in_options = _not_in_options($options, keys %args);
    if (@not_in_options) {
        croak "the build_payload method was called with unknown options '".join("','", @not_in_options)."'!";
    }

    $self->{kw_list} = $options->{kw_list};
    $self->{geo} ||= $options->{geo};
    $self->{token_payload} = {
        hl => $self->{hl},
        tz => $self->{tz},
        req =>  {
            comparisonItem => [], 
            category => $options->{cat},
            property => $options->{gprop}
        }
    };

    if (ref $self->{geo} ne 'ARRAY') {
        $self->{geo} = [$self->{geo}];
    }

    # Check if timeframe is a list
    if (ref $self->{timeframe} eq 'ARRAY') {
        my $index = 0;
        for my $kw (@{$self->{kw_list}}) {
            for my $geo (@{$self->{geo}}) {
                my $keyword_payload = {
                  keyword => $kw,
                  time => $options->{timeframe}->[$index],
                  geo =>  $geo
                };
                my $ref_comparison_item = $self->{token_payload}->{req}->{comparisonItem}; 
                push @{$ref_comparison_item}, $keyword_payload; 
                $index++;
            }
        }
    } else {
        # build out json for each keyword with
        for my $kw (@{$self->{kw_list}}) {
            for my $geo (@{$self->{geo}}) {
                my $keyword_payload = {
                  keyword => $kw,
                  time => $options->{timeframe},
                  geo =>  $geo
                };
                my $ref_comparison_item = $self->{token_payload}->{req}->{comparisonItem}; 
                push @{$ref_comparison_item}, $keyword_payload;             
            }
        }
    }
    # requests will mangle this if it is not a string
    $self->{token_payload}->{req} = encode_json($self->{token_payload}->{req});
    # get tokens
    $self->_tokens();
}

## Request data from Google's Interest Over Time section and return a table array
sub interest_over_time {
    my $self = shift;

    my $over_time_payload = {
        # convert to string as requests will mangle
        req => encode_json($self->{interest_over_time_widget}->{request}),
        token  => $self->{interest_over_time_widget}->{token},
        tz => $self->{tz}
    };

    # do the GET request
    my $json_data = $self->_get_data(
        url => INTEREST_OVER_TIME_URL,
        method => GET_METHOD,
        trim_chars => 5,
        params => $over_time_payload
    );

    ## build a simple data table 
    my @rows = ();
    push @rows, [['date_time']->@*, $self->{kw_list}->@*];
    my $timeline_data = $json_data->{default}->{timelineData};
    for my $data_at (@$timeline_data) {
        my $row = [localtime($data_at->{time})->strftime('%F %T')];
        push @$row, $data_at->{value}->@*;
        push @rows, $row;
    }
    return @rows;
}

# "Request data from Google's Interest by Region section and return a table array
sub interest_by_region {
    my ($self, %args) = @_;

    my $options = {
        resolution => $args{resolution} // 'COUNTRY',
        inc_low_vol => $args{inc_low_vol} // 0, 
        inc_geo_code => $args{inc_geo_code} // 0, 
        sort_by_kw_val =>  $args{sort_by_kw_val} // $self->{kw_list}->[0], 
    };

    my $interest_by_region_req = $self->{interest_by_region_widget}->{request};

    # build the request payload
    my $region_payload = {};

    if ($self->{geo} eq ''){
        $interest_by_region_req->{resolution} = $options->{resolution};
    
    } elsif ($self->{geo} eq 'US' && grep { $options->{resolution} eq $_ } qw/DMA CITY REGION/) {
        $interest_by_region_req->{resolution} = $options->{resolution};
    }

    $interest_by_region_req->{includeLowSearchVolumeGeos} = $options->{inc_low_vol};

    # convert to string as requests will mangle
    $region_payload->{req} = encode_json($interest_by_region_req);
    $region_payload->{token} = $self->{interest_by_region_widget}->{token};
    $region_payload->{tz} = $self->{tz};

    # do the GET request
    my $json_data = $self->_get_data(
        url => INTEREST_BY_REGION_URL,
        method => GET_METHOD,
        trim_chars => 5,
        params => $region_payload
    );

    # build a simple data table 
    my @rows = ();
    my $geo_map_data = $json_data->{default}->{geoMapData};
    for my $data_geo (@$geo_map_data) {
        my $row = [$data_geo->{geoName}, $data_geo->{geoCode}];
        push @$row, $data_geo->{value}->@*;
        push @rows, $row;
    }

    # find keyword index
    my $kw_index = firstidx { $options->{sort_by_kw_val} eq $_} $self->{kw_list}->@*;
    # add 2, because geo_name and geo_code cols
    $kw_index += 2; 
    # sort rows by selected keyword value
    @rows = sort {$b->[$kw_index] <=> $a->[$kw_index]} @rows;
    # add headline to rows
    unshift @rows, [['geo_name', 'geo_code']->@*, $self->{kw_list}->@*];

    return @rows;
}

## Request data from Google's Related Topics section and return a hash_ref of data tables
## If no top and/or rising related topics are found, the value for the key "top" and/or "rising" will be undef
sub related_topics {
    my ($self, %args) = @_;

    # make the request
    my $href_related_payload = {};
    my $href_result = {};
print Data::Dumper::Dumper($self->{related_topics_widget_list});

    for my $request_json ($self->{related_topics_widget_list}->@*){

        # ensure we know which keyword we are looking at rather than relying on order
        my $kw = $request_json->{request}->{restriction}->{complexKeywordsRestriction}->[0]->{value};
        $kw = '' if (!defined $kw);

        # convert to string as requests will mangle
        $href_related_payload->{req} = encode_json($request_json->{request});
        $href_related_payload->{token} = $request_json->{token};
        $href_related_payload->{tz} = $self->{tz};

        # do request parse the returned json
        my $json_data = $self->_get_data(
            url => RELATED_QUERIES_URL,
            method => GET_METHOD,
            trim_chars => 5,
            params => $href_related_payload,
        );

        # top topics
        my $df_top = undef;
        my $top_list = $json_data->{default}->{rankedList}->[0]->{rankedKeyword};
        if (defined $top_list) {
            $df_top = json_normalize($top_list, sep => '_');
        }

        # rising topics
        my $df_rising = undef;
        my $rising_list =  $json_data->{default}->{rankedList}->[1]->{rankedKeyword};
        if (defined $rising_list) {
            $df_rising = json_normalize( $rising_list, sep => '_');
        }

        $href_result->{kw} = {rising =>  $df_rising, top => $df_top};
    }
    return $href_result;
}

## Request data from Google's Related Queries section and return a hash_ref of data data tables
## If no top and/or rising related queries are found, the value for the key "top" and/or "rising" will be undef
sub related_queries {
    my ($self, %args) = @_;

    # make the request
    my $href_related_payload = {};
    my $href_result = {};
   
    for my $request_json ($self->{related_queries_widget_list}->@*){

        # ensure we know which keyword we are looking at rather than relying on order
        my $kw = $request_json->{request}->{restriction}->{complexKeywordsRestriction}->{keyword}->[0]->{value};
        $kw = '' if (!defined $kw);

        # convert to string as requests will mangle
        $href_related_payload->{req} = encode_json($request_json->{request});
        $href_related_payload->{token} = $request_json->{token};
        $href_related_payload->{tz} = $self->{tz};
    
        # do request parse the returned json
        my $json_data = $self->_get_data(
            url => RELATED_QUERIES_URL,
            method => GET_METHOD,
            trim_chars => 5,
            params => $href_related_payload,
        );

        # top queries
        my $top_list = $json_data->{default}->{rankedList}->[0]->{rankedKeyword};

        if (defined $top_list) {
            $top_list = [ map { +{ query => $_->{query}, value => $_->{value}}} @$top_list];
        }

        # rising queries
        my $rising_list = $json_data->{default}->{rankedList}->[1]->{rankedKeyword};
        if (defined $rising_list) {
            $rising_list = [ map { +{ query => $_->{query}, value => $_->{value}}} @$rising_list];
        }
        $href_result->{$kw} = {'top' =>  $top_list, 'rising' => $rising_list};
    }
    return $href_result;
}

## Request data from Google's Keyword Suggestion dropdown and return a hash_ref
sub suggestions {

    my ($self, $keyword, %args) = @_; 

    my $options = {
        hl => $args{hl} // $self->{hl}
    };

    my $json_data = $self->_get_data(
        url => SUGGESTIONS_URL .  uri_escape($keyword),
        params => $options,
        method => GET_METHOD,
        trim_chars => 5
    );
    return $json_data->{default}->{topics};
}

## Request available categories data from Google's API and return a hash_ref
sub categories {

    my ($self, %args) = @_; 

    my $options = {
        hl => $args{hl} // $self->{hl}, 
    };

    my $json_data = $self->_get_data(
        url => CATEGORIES_URL,
        params => $options ,
        method => GET_METHOD,
        trim_chars => 5
    );
    return $json_data;
}

## Gets google cookie (used for each and every proxy; once on init otherwise)
## Removes proxy from the list on proxy error
sub get_google_cookie {
    my ($self) = @_;

    my $url = BASE_TRENDS_URL .'/explore?geo='. substr($self->{hl},-2);
    my $jar = $self->{cookie_jar};
    my $response = HTTP::Tiny->new(cookie_jar => $jar)->get($url);
    return $jar;
}

## Makes request to Google to get API tokens for interest over time, 
## interest by region and related queries
sub _tokens {
    my $self = shift;

    my $data = $self->_get_data(
        url => GENERAL_URL,
        method => POST_METHOD,
        params => $self->{token_payload},
        trim_chars => 4
    );
    my $widgets = $data->{widgets};
    
    # order of the json matters...
    my $first_region_token = 1;

    # clear self.related_queries_widget_list and self.related_topics_widget_list
    # of old keywords'widgets
    $self->{related_queries_widget_list} = [];
    $self->{related_topics_widget_list} = [];

    for my $widget (@$widgets) {
        if ($widget->{id} eq 'TIMESERIES') {
            $self->{interest_over_time_widget} = $widget;
        }
        if ($widget->{id} eq 'GEO_MAP' && $first_region_token) {
             $self->{interest_by_region_widget} = $widget;
                $first_region_token = 0;
        }
        # response for each term, put into a list
        if ($widget->{id} =~ /RELATED_TOPICS/) {
            push $self->{related_topics_widget_list}->@*,$widget; 
        }
        if ($widget->{id} =~ /RELATED_QUERIES/) {
            push $self->{related_queries_widget_list}->@*,$widget; 
        }
    }
}

## Send a request to Google and return the JSON response as a perl hash_ref
## :param url: the url to which the request will be sent
## :param method: the HTTP method ('get' or 'post')
## :param trim_chars: how many characters should be trimmed off the beginning of the content of the response
##  before this is passed to the JSON parser
## :param params: any extra key arguments passed to the request builder (usually query parameters or data)
sub _get_data {

    my ($self, %args) = @_;
    my $url = $args{url};
    my $method = $args{method} // GET_METHOD;
    my $trim_chars = $args{trim_chars} // 0;
    my $params = $args{params};
    ## params

    my $client = HTTP::Tiny->new(
        cookie_jar => $self->{cookie_jar},
        timeout => $self->{timeout}
    );

    my $params_encoded = $client->www_form_urlencode($args{params});

    my $response = undef;
    if ($method eq POST_METHOD) {
        $response = $client->post($url.'?'.$params_encoded);
        # DO NOT USE retries or backoff_factor here
    } else {
        $response = $client->get($url.'?'.$params_encoded);
        # DO NOT USE retries or backoff_factor here
    }

    # check if the response contains json and throw an exception otherwise
    # Google mostly sends 'application/json' in the Content-Type header,
    # but occasionally it sends 'application/javascript
    # and sometimes even 'text/javascript
    my $content_type = $response->{headers}->{'content-type'};
    if ($response->{status} eq '200' 
        && ($content_type =~ /application\/json;/
        || $content_type =~ /application\/javascript;/
        || $content_type =~ /text\/javascript;/)) {
        # trim initial characters
        # some responses start with garbage characters, like ")]}',"
        # these have to be cleaned before being passed to the json parser
        my $json_content = substr($response->{content}, $trim_chars );
        return decode_json($json_content);
    } else {
        ## TODO Error
    }
}



sub _is_arg_not_of {
    my $arg = shift;
    my @of = @_;
    if (defined $arg) { 
        return !firstres {$arg eq $_} @of;
    }
    return 0;
}

sub _not_in_options {
    my $options_hash = shift;
    my @keys = @_;
    my $aref_not_in = reduce { !$options_hash->{$b} ? [@$a, $b] : $a } [], @keys;
    return @$aref_not_in;
}

1;
__END__

=encoding utf-8

=head1 NAME

Google::Trends - It's new $module

=head1 SYNOPSIS

    use Google::Trends;

=head1 DESCRIPTION

Google::Trends is ...

=head1 LICENSE

Copyright (C) Jan-Felix Wittmann.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Jan-Felix Wittmann E<lt>jfwittmann@posteo.netE<gt>

=cut


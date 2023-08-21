#!/usr/bin/env perl

use Data::Dumper;
use Text::ASCIITable;
use utf8;  
use open ':std', ':encoding(UTF-8)'; # Terminal provides/expects UTF-8
use FindBin;
use lib "$FindBin::Bin/../lib";
use Google::Trends;

my $trends = Google::Trends->new(hl =>'de', tz => '-120');
##print Data::Dumper::Dumper($trends->categories());

$trends->build_payload(
    geo => 'DE',
    cat => 31, ## Programming, see categories method
    kw_list=>['python', 'perl', 'ruby'], 
    timeframe => 'today 12-m');

#my @over_time = $trends->interest_over_time();

#print Text::ASCIITable->new({ chaining => 1 })
#    ->setCols(shift @over_time)
#    ->addRow(\@over_time)
#    ->draw();


my @by_region = $trends->interest_by_region(
    resolution => 'REGION',
    sort_by_kw_val => 'python'
);

my $ascii_table = Text::ASCIITable->new({ chaining => 1 })
    ->setCols(shift @by_region)
    ->addRow(\@by_region)
    ->draw();

print $ascii_table; 
#print Data::Dumper::Dumper(\@by_region);


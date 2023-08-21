package Google::Trends::Utils;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT = qw(json_normalize);

## :para data hash_ref ^ array_ref of hash_ref
## see https://pandas.pydata.org/docs/reference/api/pandas.json_normalize.html

sub json_normalize {
    my ($data, %args) = @_;

    my $options = {
        max_level => $args{max_level},
        sep =>  $args{sep} // '.',
        when_undef =>  $args{when_undef} // '-'

        ## TODO following options are currently not implemented

        #record_path => $args{record_path},
        #meta => $args{meta},
        #meta_prefix => $args{meta_prefix},
        #record_prefix => $args{record_prefix},
        #errors =>  $args{errors},
    };

    my $visited_paths = {};
    my @paths = ();
    my @rows = ();

    local *loop = sub  {
        my $outer_data = shift;
        my $cur_keypath = shift // [];
        my $cur_depth = shift // 0;

        if (ref($outer_data) eq 'ARRAY') {

            for my $inner_data (@$outer_data) {
                if (ref($inner_data) eq 'HASH' || ref($inner_data) eq 'ARRAY') {
                    push @rows, loop($inner_data, $cur_keypath, $cur_depth+1);
                }
            }
        } elsif (ref($outer_data) eq 'HASH') {
            my $row = {};
            for my $key (keys %$outer_data) {
                my $value = $outer_data->{$key};

                my $next_keypath = (@$cur_keypath) ? [@$cur_keypath, $key] : [$key];

                if (ref($value) eq 'ARRAY' || ref($value) eq 'HASH') {

                    if (!defined $options->{max_level} || $options->{max_level} >= $cur_depth) {
                        $row = {%$row, loop($value, $next_keypath, $cur_depth+1)->%*};
                    } else {
                        my $path = join('.', @$next_keypath);
                        unless (defined $visited_paths->{$path}) {
                            $visited_paths->{$path} = 1;
                            push @paths, $path;
                        }
                        $row->{$path} = $value;
                    }
                } else {
                    my $path = join($options->{sep}, @$next_keypath);
                    unless (defined $visited_paths->{$path}) {
                        $visited_paths->{$path} = 1;
                        push @paths, $path;
                    }
                    $row->{$path} = $value;
                }
            }
            return $row;
        } 
    };
    loop($data);

    my @sorted_path = sort(@paths);
    my @result_rows = ();
    push @result_rows, [@sorted_path];  
    for my $row (@rows) {
        my @tmp_row = map { $row->{$_} // $options->{when_undef} } @sorted_path;
        push @result_rows, \@tmp_row;
    }
    return @result_rows;
}
1;
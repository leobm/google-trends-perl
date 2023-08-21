use strict;
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Google::Trends::Utils qw/json_normalize/;
use Text::ASCIITable;
use JSON::PP;

my $data1 = [
    {
        "id" => 1,
        "candidate" =>  "Roberto mathews",
        "health_index" =>  {"bmi" =>  22, "blood_pressure" => 130},
    },
    {"candidate" =>  "Shane wade", "health_index" =>  {"bmi" =>  28, "blood_pressure" =>  160}},
    {
        "id" =>  2,
        "candidate" =>  "Bruce tommy",
        "health_index" =>  {"bmi" =>  31, "blood_pressure" => 190},
    },
];

my @normalized = json_normalize($data1, max_level => 1);

my $table = Text::ASCIITable->new();
$table->setCols(shift @normalized );
for my $row (@normalized) {
    $table->addRow([map {
        (ref($_) eq 'ARRAY' || ref($_) eq 'HASH') 
            ? encode_json($_) : $_;
    } @$row]);
};
print $table->draw();
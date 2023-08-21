requires 'perl'   => '5.010001';
requires 'HTTP::Tinyish', '0.088';
requires 'HTTP::CookieJar', '0.014';
requires 'List::MoreUtils', '0.430';
requires 'Text::ASCIITable', '0.22';

on 'test' => sub {
    requires 'Test::More', '0.98';
};


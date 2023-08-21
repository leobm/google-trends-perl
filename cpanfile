requires 'perl'   => '5.024_001';
requires 'HTTP::Tinyish', '0.088';
requires 'HTTP::CookieJar', '0.014';
requires 'IO::Socket::SSL', '2.083';
requires 'URI', '5.19';
requires 'List::MoreUtils', '0.430';
requires 'Text::ASCIITable', '0.22';

on 'test' => sub {
    requires 'Test::More', '0.98';
};


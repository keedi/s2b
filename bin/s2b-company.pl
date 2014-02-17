#!/usr/bin/env perl

use v5.18;
use utf8;
use strict;
use warnings;

use Encode qw( decode );
use Path::Tiny;
use Text::CSV;

use S2B;

binmode STDERR, ':encoding(UTF-8)';

my $company = shift;
my $query   = shift;
my $delay   = shift // 1;
die "Usage: $0 <company> <query> [ <delay> ]\n" unless $company && $query;;
map { $_ = decode('utf-8', $_) } $company, $query;

my $s2b = S2B->new;

say STDERR "searching company($company), query($query)...";

my @codes = $s2b->search_company( $company, $query, $delay );
my %info;
for my $code (@codes) {
    say   STDERR "  code: $code";
    print STDERR "    fetching from the web...";

    my $product = $s2b->get_product($code);
    if ($product) {
        $info{$code} = $product;
        say STDERR '[SUCCESS]';

        my $target_dir = join( q{/}, $s2b->filter_path($company), $s2b->filter_path($query) );

        write_csv( $s2b, $info{$code}, $target_dir );
        save_images( $s2b, $info{$code}, $target_dir, $code ) if 0;

        sleep $delay;
    }
    else {
        say STDERR '[FAIL]';
    }
}

sub write_csv {
    my ( $s2b, $i, $target_dir ) = @_;

    my $csv = Text::CSV->new({
        binary => 1,
        eol    => "\n",
    });

    say STDERR "    write csv...";
    my $csv_fh      = path( "$target_dir/list.csv" )->touchpath->opena_utf8;
    my @csv_columns = qw(
        code
        serial1
        serial2
        c1
        c2
        c3
        c1_str
        c2_str
        c3_str
        name
        model
        price
        manufactory
        made_in
        manufactured_date
        spec
        tax
        url
    );
    $csv->print( $csv_fh, [ @{$i}{@csv_columns} ] );
    close $csv_fh;
}

sub save_images {
    my ( $s2b, $i, $target_dir, $code ) = @_;

    say STDERR "    saving images...";
    $s2b->save_images(
        $target_dir,
        $s2b->filter_path($code),
        $i->{images},
    );
}

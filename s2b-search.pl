#!/usr/bin/env perl

use v5.18;
use utf8;
use strict;
use warnings;

use Path::Tiny;
use Text::CSV;

use S2B;

my $model = shift;
my $count = shift || 10;
die "Usage: $0 <model> [ <count> ]\n" unless $model;

my $s2b = S2B->new;

warn "searching $count items of model($model)...\n";

my @codes = $s2b->search_product( $model, $count );
my %info;
for my $code (@codes) {
    say   STDERR "  code: $code";
    print STDERR "    fetching from the web...";

    my $product = $s2b->get_product($code);
    if ($product) {
        $info{$code} = $product;
        say STDERR '[SUCCESS]';
    }
    else {
        say STDERR '[FAIL]';
    }
}

say STDERR "sorting via price...";
my @sorted_codes = sort { $info{$a}{price} <=> $info{$b}{price} } keys %info;

for my $code (@sorted_codes) {
    say STDERR "  code: $code";

    my $i = $info{$code};

    #
    # save images
    #
    say STDERR "    saving images...";
    $s2b->save_images( $model, $code, $i->{images} );

    #
    # save csv
    #
    my $csv = Text::CSV->new({
        binary => 1,
        eol    => "\n",
    });

    warn "    write csv...\n";
    my $csv_fh      = path("$model/list.csv")->opena_utf8;
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

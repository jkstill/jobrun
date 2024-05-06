#!/usr/bin/env perl

use warnings;
use strict;
use Data::Dumper;

my %a = (
	a => '0',
	b => '1',
	c => '2',
);

%a=( d =>  '3' );

print '%a: ' . Dumper(\%a);

#print keys %a;

my @c = (keys %a);

print 'last el: ' . $#c . "\n";





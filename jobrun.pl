#!/usr/bin/env perl

######################################################
# Jared Still
# 2024-05-19
# jkstill@gmail.com
#
# use to fork a process to run a job
# jobrun.pl is the front end
######################################################

=head1 jobrun.pl

Use jobrun.pl to run jobs in parallel

=cut

use strict;
use warnings;
use IO::File;
use Data::Dumper;
use lib './lib';
use Jobrun;

my @programPath = split(/\//,$0);
my $programName = $programPath[$#programPath];

print "$programName\n";

my $configFile='jobrun.conf';
my $jobFile='jobs.conf';


my %jobsToRun=();
my %jobs=();
my %config=();
my $verbose=1;

# get options here

-r $configFile || die "could not read $configFile - $!\n";
-r $jobFile || die "could not read $jobFile - $!\n";

getKV($configFile,\%config);
getKV($jobFile,\%jobsToRun);

my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);

my $logFile="$config{logdir}/$config{logfile}-${year}-${mon}-${mday}_${hour}-${min}-${sec}.$config{'logfile-suffix'}";
my $logFileFH = IO::File->new($logFile,'w') or die "cannot open $logFile for write - $!\n";;
$|=1; # no buffer on output
$logFileFH->print("==============================================================\n");

my @jobQueue = keys %jobsToRun;
my $numberJobsToRun = $#jobQueue + 1;

logger('%config: ' . Dumper(\%config));

logger( '%config: ' . Dumper(\%config));
logger( '%jobsToRun: ' . Dumper(\%jobsToRun));
logger( '@jobQueue: ' . Dumper(\@jobQueue));

logger( "count: $numberJobsToRun\n");

$SIG{INT} = sub{ warn "\n\nKill with Signal!\n\n"; sleep 1; };
$SIG{QUIT} = sub{ Jobrun::cleanup(); exit; };
$SIG{TERM} = sub{ Jobrun::cleanup(); exit; };

#exit;

while(1) {
	
	#last if $i++ > 10;
	logger( "main loop\n");

	if ( Jobrun->getChildrenCount() < $config{maxjobs} and $numberJobsToRun > 0) {
		$numberJobsToRun--;
		logger( "Number of jobs left to run: $numberJobsToRun\n");
		my $currJobName = shift @jobQueue;
		logger( "sending job: $jobsToRun{$currJobName}\n");
		$jobs{$currJobName} = Jobrun->new(
			JOBNAME => $currJobName, 
			CMD => "$jobsToRun{$currJobName}",
			LOGGER => \&logger
		);
		print "JOB: $currJobName: $jobsToRun{$currJobName}\n";
		$jobs{$currJobName}->child();
		#next;
		Jobrun::incrementChildren();	
		next;
	}

	logger( "  main: number of jobs to run: $numberJobsToRun\n");
	logger( "  main: child count " . Jobrun::getChildrenCount() . "\n");
	last if $numberJobsToRun < 1;
	
	sleep $config{'iteration-seconds'};
}

# wait for jobs to finish
while ( Jobrun::getChildrenCount() > 0 ) {
	logger( "main: waiting for children to complete\n");
	sleep $config{'iteration-seconds'};
}

Jobrun::cleanup(); # Note: This will remove the semaphore. Only call this when absolutely necessary.

exit;

########################################
## END OF MAIN
########################################

sub getKV {
	my ($configFile,$configRef) = @_;
	open CFG, '<', $configFile || die "getKV() - could not open $configFile - $!\n";
	while (<CFG>) {
		chomp;
		next if /^#/;
		next if /^\s*$/;

		my ($key,$value) = split(/\s*:\s*/);
		$configRef->{$key} = $value;
	}
	return;
}

sub logger {
	while (@_) {
		my $line = shift @_;
		$logFileFH->print($line);
		print "$line" if $verbose;
	}
}



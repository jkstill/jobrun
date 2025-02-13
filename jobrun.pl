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
use Getopt::Long qw(:config pass_through) ;
use lib './lib';
use Jobrun qw(logger %allJobs);
use sigtrap 'handler', sub{ cleanup(); exit; }, qw(QUIT TERM);
use IPC::Shareable;

$Data::Dumper::Terse = 1; # to Eval whole thing as a hash
$Data::Dumper::Indent = 1; # Looks better, just a preference
$Data::Dumper::Sortkeys = 1; # To keep changes minimal in source control

# seem comments later about using signals to run code
# does not seem to work in a useful manner
# I think what happens is the current call gets interrupted by the signal,
# and the return is to whatever the following line of code is.
#use sigtrap 'handler', \&reloadConfig, qw(USR1); ## kill -10
#use sigtrap 'handler', \&Jobrun::status, qw(USR2); ## kill -12

 # CTL-C will not work - use CTL-\
$SIG{'INT'} = 'IGNORE'; 

my @programPath = split(/\//,$0);
my $programName = $programPath[$#programPath];

print "$programName\n";

my $configFile='jobrun.conf';
my $jobFile='jobs.conf';

my %jobsToRun=();
my %jobs=();
my %config=();
my $verbose;
my $debug;
my %optctl;
my $help=0;
my $maxjobs;
my $exitNow=0;
my $reloadConfigFile=0;
my $getStatus=0;
my $resumable;
my $iterationSeconds;
my $logfileBase;
my $logfileSuffix;
my $logdir;

GetOptions(
	\%optctl,
	"config-file=s" => \$configFile,
	"job-config-file=s" => \$jobFile ,
	"resumable!"	=> \$resumable,
	"help!" => \$help
);

usage(0) if $help;

# assumed filename is name.extension
my $resumableFile = (split(/[.]/,$jobFile))[0] . '.resume';

if ( -f $resumableFile ) { $jobFile = $resumableFile; };

-r $configFile || die "could not read $configFile - $!\n";
-r $jobFile || die "could not read $jobFile - $!\n";

getKV($configFile,\%config);
banner('#',80,"\%config - $configFile");
showKV(\%config);
getKV($jobFile,\%jobsToRun);
banner('#',80,"\%jobsToRun - $jobFile");
showKV(\%jobsToRun);

%Jobrun::allJobs = %jobsToRun;

banner('#',80,'%Jobrun::allJobs');
#showKV(\%Jobrun::allJobs);
Jobrun::showAllJobs();
#exit;

#"reload-config!" => \$reloadConfigFile,

GetOptions(
\%optctl,
	"iteration-seconds=i"	=> \$iterationSeconds,
	"maxjobs=i"					=> \$maxjobs,
	"logfile-base=s"			=> \$logfileBase,
	"logfile-suffix=s"		=> \$logfileSuffix,
	"logdir=s"					=> \$logdir,
	"verbose!"		=> \$verbose,
	"status!"		=> \$getStatus,
	"debug!"			=> \$debug,
	"kill!"			=> \$exitNow,
	"z!"				=> \$help,
	"h!"				=> \$help,
)  or  usage(1);


# manual check for unknown arguments due to use of pass_through
#print '@ARGV ' . Dumper(\@ARGV);
#print "#ARGV: $#ARGV\n";
usage(1) if $#ARGV > -1;
#exit;


# trapping signals to run the status and reload config causes the 
# main script to add more jobs
# same if just --status is passed
# leave here for future use
#=head1 non-working code

if ( $reloadConfigFile ) {
	warn "Reloading the config file not currently supported";
	return;
	# send HUP to pid of main process
	my $mainPID = getMainPid();
	kill 'USR1', $mainPID;
	exit 0;
}

#=cut

if ( $getStatus ) {
	# send HUP to pid of main process
	Jobrun::status();
	exit 0;
}


if ( $exitNow ) {
	# send HUP to pid of main process
	my $mainPID = getMainPid();
	my $childrenHash = Jobrun::getJobPids();
	my @childPids = map { (split(/:/,$childrenHash->{$_}))[0] }  keys %{$childrenHash};
	print 'ChildPIDs: ' . Dumper(\@childPids);
	kill '-QUIT', @childPids;
	kill '-QUIT', $mainPID;
	unlink 'jobrun.pid';
	exit 0;
}

use Fcntl qw(:flock);
open our $file, '<', $0 or die $!;
flock $file, LOCK_EX|LOCK_NB or die "Only 1 jobrun can be executing in the current dirctory-$!\n";

createPidFile();

# load from config
foreach my $configWord ( qw[ debug verbose resumable maxjobs logdir logfile-base logfile-suffix iteration-seconds ] ) {
	$config{$configWord} = $optctl{$configWord} if exists $optctl{$configWord};
}
# config overrides from cmd line
$config{'debug'} = $debug if defined($debug);
$config{'verbose'} = $verbose if defined($verbose);
$config{'maxjobs'} = $maxjobs if defined($maxjobs);
$config{'logdir'} = $logdir if defined($logdir);
$config{'logfile-base'} = $logfileBase if defined($logfileBase);
$config{'logfile-suffix'} = $logfileSuffix if defined($logfileSuffix);
$config{'iteration-seconds'} = $iterationSeconds if defined($iterationSeconds);

my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);

my $logFile="$config{'logdir'}/$config{'logfile-base'}-${year}-${mon}-${mday}_${hour}-${min}-${sec}.$config{'logfile-suffix'}";
my $logFileFH = IO::File->new($logFile,'w') or die "cannot open $logFile for write - $!\n";;
$|=1; # no buffer on output
autoflush STDOUT 1;

logger($logFileFH,$config{verbose},"==============================================================\n");

my @jobQueue = keys %jobsToRun;
my $numberJobsToRun = $#jobQueue + 1;

if ($debug) {
	logger($logFileFH,$config{verbose},"parent:$$ " . '%config: ' . Dumper(\%config));
	logger($logFileFH,$config{verbose},"parent:$$ " .  '%config: ' . Dumper(\%config));
	logger($logFileFH,$config{verbose},"parent:$$ " .  '%jobsToRun: ' . Dumper(\%jobsToRun));
	logger($logFileFH,$config{verbose},"parent:$$ " .  '@jobQueue: ' . Dumper(\@jobQueue));
	logger($logFileFH,$config{verbose},"parent:$$ " .  "concurrent jobs $numberJobsToRun\n");
}

logger($logFileFH,$config{verbose}, "parent pid: $$\n:");
#my $dummy=<STDIN>;
#exit;

while(1) {
	
	#last if $i++ > 10;
	logger($logFileFH,$config{verbose},"parent:$$ main loop\n");

	if ( Jobrun->getChildrenCount() < $config{maxjobs} and $numberJobsToRun > 0) {
		$numberJobsToRun--;
		logger($logFileFH,$config{verbose},"parent:$$ Number of jobs left to run: $numberJobsToRun\n");
		my $currJobName = shift @jobQueue;
		logger($logFileFH,$config{verbose},"parent:$$ sending job: $jobsToRun{$currJobName}\n");
		$jobs{$currJobName} = Jobrun->new(
			JOBNAME => $currJobName, 
			CMD => "$jobsToRun{$currJobName}",
			LOGFH => $logFileFH,
			VERBOSE => $config{verbose}
		);
		logger($logFileFH,$config{verbose}, "JOB: $currJobName: $jobsToRun{$currJobName}\n");
		$jobs{$currJobName}->child();
		#next;
		Jobrun::incrementChildren();	
		next;
	}

	logger($logFileFH,$config{verbose},"parent:$$ number of jobs to run: $numberJobsToRun\n");
	logger($logFileFH,$config{verbose},"parent:$$ child count " . Jobrun::getChildrenCount() . "\n");
	last if $numberJobsToRun < 1;

	logger($logFileFH,$config{verbose}, '%pidTree: ' . Dumper(\%Jobrun::pidTree));
	
	sleep $config{'iteration-seconds'};
}

banner('#',80,"\%config - $configFile");
showKV(\%config);
banner('#',80,"\%jobsToRun - $jobFile");
showKV(\%jobsToRun);


cleanup();
exit;

########################################
## END OF MAIN
########################################
#

sub cleanup {
	# wait for jobs to finish
	print "Current Children: " . Jobrun::getChildrenCount() . "\n";
	logger($logFileFH,$config{verbose},"parent:$$ Current Children: " . Jobrun::getChildrenCount() . "\n");
	while ( Jobrun::getChildrenCount() > 0 ) {
		logger($logFileFH,$config{verbose},"parent:$$ " . "main: waiting for children to complete\n");
		sleep $config{'iteration-seconds'};
	}
	print "Current Children: " . Jobrun::getChildrenCount() . "\n";
	logger($logFileFH,$config{verbose},"parent:$$ Current Children after wait: " . Jobrun::getChildrenCount() . "\n");

	logger($logFileFH,$config{verbose},"parent:$$\n" . '%pidTree cleanup before: ' . Dumper(\%Jobrun::pidTree));
	print '%pidTree cleanup before: ' . Dumper(\%Jobrun::pidTree);

	logger($logFileFH,$config{verbose},"All Jobs:\n" .  Dumper(\%Jobrun::allJobs));
	logger($logFileFH,$config{verbose},"Completed Jobs:\n" .  Dumper(\%Jobrun::completedJobs));
	logger($logFileFH,$config{verbose},"Jobs Status:\n" .  Dumper(\%Jobrun::jobPids));


	Jobrun::createResumableFile($resumableFile) if $resumable;
	# remove resumable file if it exists and is 0 bytes
	Jobrun::cleanupResumableFile($resumableFile);
	Jobrun::cleanup(); # Note: This will remove the semaphore. Only call this when absolutely necessary.

	logger($logFileFH,$config{verbose},"parent:$$\n" . '%pidTree cleanup after ' . Dumper(\%Jobrun::pidTree));
	print '%pidTree cleanup after ' . Dumper(\%Jobrun::pidTree);

	if ( -w 'jobrun.pid' ) {
		unlink 'jobrun.pid;'
	}

}

sub createPidFile {
	open PIDFILE, '>', 'jobrun.pid' or die "could not create jobrun.pid - $!\n";
	print PIDFILE "$$";
	close PIDFILE;
}

sub getMainPid {
	open PIDFILE, '<', 'jobrun.pid' or die "could not read jobrun.pid - $!\n";
	my $pid  = <PIDFILE>;
	close PIDFILE;
	return $pid;
}

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

sub showKV {
	my($kvRef) = @_;
	foreach my $key ( sort keys %{$kvRef} ) {
		print "k: $key  v: $kvRef->{$key}\n";
	}
}

sub banner {
	my ($bannerChr, $bannerLen, $bannerMsg) = @_;
	print "\n" . $bannerChr x $bannerLen . "\n";
	print $bannerChr x 2 . " $bannerMsg\n";
	print $bannerChr x $bannerLen . "\n\n";
}

sub reloadConfig {
	#$SIG{'HUP'} = 'IGNORE';
	logger($logFileFH,$config{verbose},"parent:$$ reloading \%config\n");
	getKV($configFile,\%config);
	#$SIG{HUP} = \&reloadConfig; # kill -1
	return;
}

sub usage {
   my $exitVal = shift;
   $exitVal = 0 unless defined $exitVal;
   use File::Basename;
   my $basename = basename($0);
   print qq/

usage: $basename
/;

print q{

  The default values are found in jobrun.conf, and can be changed.

  --config-file        jobrun config file. default: jobrun.conf
  --job-config-file    jobs config file. default: jobs.conf
  --iteration-seconds  seconds between checks to run more jobs. default: 10
  --maxjobs            number of jobs to run concurrently. default: 9
  --logfile-base       logfile basename. default: jobrun-sem
  --status             show status of currently running child jobs

  --resumable          if the script is terminated with -TERM or -INT (CTL-C for instance)
                       a temporary job configuration file is created for jobs not completed
                       this file will be used to restart if --resumable is again used

  --kill               kill the current child jobs and parent
  --logfile-suffix     logfile suffix. default: log
  --reload-config      reload the config file
  --verbose            print more messages: default: 1 or on
  --debug              print debug messages: default: 1 or on
  --help               show this help.

Example:

  ./jobrun.pl --logfile-suffix=load-log --job-config-file dbjobs.conf --maxjobs 1 --nodebug --noverbose

  ./jobrun.pl --verbose --resumable --iteration-seconds 2 --config-file perl-run.conf --job-config-file perl-jobs.conf

 When jobrun.pl starts, it will create a file 'jobrun.pid' in the current directory.

 There are traps on the INT, TERM and QUIT signals.

 Pressing CTL-C will not stop jobrun, but it will print a status message.

 Pressing CTL-\ will kill the program and cleanup semaphores

 The config file can be reloaded by sending the HUP signal to the current jobrun.pl parent process.

 Or just run './jobrun.pl' --reload-config.

 Say you have started jobrun with the --noverbose and --nodebug flags, but would now like to change
 that so that more info appears on screen.

 The following command will do that:

 $ kill -1 $(cat jobrun.pid) 

 jobrun can also be stopped with QUIT or TERM (see kill -l)

 QUIT
 $ kill -3 $(cat jobrun.pid) 

 TERM
 $ kill -15 $(cat jobrun.pid) 


 It may take a few moments for the chilren to die.

 The fastest method to stop jobrun is CTL-\

}  or  usage(1);

	exit $exitVal;

};



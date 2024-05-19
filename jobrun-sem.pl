#!/usr/bin/env perl
#
#
use strict;
use warnings;
use IPC::Semaphore;
use IPC::SysV qw(SEM_UNDO IPC_CREAT S_IRUSR S_IWUSR);
#use POSIX qw( ENOTCONN ECONNREFUSED ECONNRESET EINPROGRESS EWOULDBLOCK EAGAIN WNOHANG );
use IO::File;
use Data::Dumper;
use IPC::Shareable;

my @programPath = split(/\//,$0);
my $programName = $programPath[$#programPath];

print "$programName\n";

my $configFile='jobrun.conf';
-r $configFile || die "could not read $configFile - $!\n";

my $jobFile='jobs.conf';
-r $jobFile || die "could not read $jobFile - $!\n";

my %jobsToRun=();
my %jobs=();
my %config=();
my $verbose=1;

getKV($configFile,\%config);
getKV($jobFile,\%jobsToRun);

my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);

my $logFile="$config{logdir}/$config{logfile}-${year}-${mon}-${mday}_${hour}-${min}-${sec}.$config{'logfile-suffix'}";
my $logFileFH = IO::File->new($logFile,'w') or die "cannot open $logFile for write - $!\n";;
$|=1; # no buffer on output
$logFileFH->print("==============================================================\n");

my @jobQueue = keys %jobsToRun;
my $numberJobsToRun = $#jobQueue + 1;

my %shmOptions = (
   create    => 1,
   exclusive => 0,
   mode      => 0644,
   destroy   => 1
);


my $jobPidsSHMKey = 'jobpid';
my %jobPids=();
tie %jobPids, 'IPC::Shareable', $jobPidsSHMKey, { %shmOptions } or die "tie failed jobPids - $!\n";

logger('%config: ' . Dumper(\%config));

logger( '%config: ' . Dumper(\%config));
logger( '%jobsToRun: ' . Dumper(\%jobsToRun));
logger( '@jobQueue: ' . Dumper(\@jobQueue));

logger( "count: $numberJobsToRun\n");

use constant {
    SEM_CHILD_COUNT => 0, # Index for child count semaphore
    SEM_LOCK => 1,        # Index for lock semaphore
};


# Create semaphores
my $sem_key = 'JOBRUN'; # Private key for IPC
my $sem = IPC::Semaphore->new($sem_key, 2, S_IRUSR | S_IWUSR | IPC_CREAT) or die "Unable to create semaphore: $!";

# Initialize semaphore values
$sem->setval(SEM_CHILD_COUNT, 0);
$sem->setval(SEM_LOCK, 1); # 1 indicates that the lock is available

#my $i=0;
#
$SIG{INT} = sub{ warn "\n\nKill with Signal!\n\n"; sleep 1; };
$SIG{QUIT} = sub{ cleanup(); exit; };
$SIG{TERM} = sub{ cleanup(); exit; };

while(1) {
	
	#last if $i++ > 10;
	logger( "main loop\n");

	if ( getChildrenCount() < $config{maxjobs} and $numberJobsToRun > 0) {
		$numberJobsToRun--;
		logger( "Number of jobs left to run: $numberJobsToRun\n");
		my $currJobName = shift @jobQueue;
		logger( "sending job: $jobsToRun{$currJobName}\n");
		child($currJobName, $jobsToRun{$currJobName});
		#next;
		incrementChildren();	
		next;
	}

	logger( "  main: number of jobs to run: $numberJobsToRun\n");
	logger( "  main: child count " . getChildrenCount() . "\n");
	last if $numberJobsToRun < 1;
	
	sleep $config{'iteration-seconds'};
}

# wait for jobs to finish
while ( getChildrenCount() > 0 ) {
	logger( "main: waiting for children to complete\n");
	sleep $config{'iteration-seconds'};
}

cleanup(); # Note: This will remove the semaphore. Only call this when absolutely necessary.

sub childCleanup {
	my ($pid) = @_;
	# see cleanup in jobrun.pl
	# also loop through %jobPids and check for those
}

sub lock {
    # Wait for lock to become available and decrement it
    $sem->op(SEM_LOCK, -1, SEM_UNDO);
}

sub unlock {
    # Increment the lock semaphore to release it
    $sem->op(SEM_LOCK, 1, SEM_UNDO);
}

sub incrementChildren {
    lock();
    # Perform safe increment
    my $current_value = $sem->getval(SEM_CHILD_COUNT);
    $sem->setval(SEM_CHILD_COUNT, $current_value + 1);
    unlock();
}

sub decrementChildren {
    lock();
    # Perform safe decrement
    my $current_value = $sem->getval(SEM_CHILD_COUNT);
	 if ($current_value) {
    	$sem->setval(SEM_CHILD_COUNT, $current_value - 1);
	}
    unlock();
}

sub getChildrenCount {
    # Return current child count
    return $sem->getval(SEM_CHILD_COUNT);
}

sub cleanup {
    # This should be called to cleanup semaphores, typically on program exit
    # or when the job engine dies unexpectedly.
    lock();
    $sem->setval(SEM_CHILD_COUNT, 0);
    $sem->setval(SEM_LOCK, 1);
    unlock();
    $sem->remove();
}

sub child {
	my ($jobName,$cmd) = @_;

	my $child = fork();
	#die("Can't fork: $!") unless defined ($child = fork());
	die("Can't fork #1: $!") unless defined($child);

	if ($child) {
		logger( "child - parent: name: $cmd\n");

	} else {

		my $grandChild = fork();	
		die("Can't fork #2: $!") unless defined($grandChild);

		if ($grandChild == 0 ) {
			# use system() here
			#qx/$cmd/;
			my $pid=$$;
			$jobPids{$jobName} = $pid;

			logger( "grandChild PID: $pid\n");

			logger ( "grancChild $pid running job $jobName\n");
			system($cmd);
			my $rc = $?;
	
			decrementChildren();
			exit $rc;
		} else {
			exit 0;
		}

	};

	waitpid($child,0);
	return;
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

sub logger {
	while (@_) {
		my $line = shift @_;
		$logFileFH->print($line);
		print "$line" if $verbose;
	}
}



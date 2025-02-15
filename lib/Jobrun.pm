#
# Jared Still
# 2024-05-21
# jkstill@gmail.com
#
# use to fork a process to run a job
# jobrun.pl is the front end
######################################################

=head1 Jobrun.pm

TODO

Sometimes the IPC cleanup leaves behind a semaphore array and maybe a tied hash in memory
This does not happen consistently, and I do not yet know why it happens at all

=cut


package Jobrun;

use warnings;
use strict;
use IPC::SysV qw(IPC_PRIVATE SEM_UNDO IPC_CREAT S_IRUSR S_IWUSR);
use IPC::Semaphore;
use Data::Dumper;
use File::Temp qw/ :seekable tmpnam/;
#use Time::HiRes qw( usleep );
use IPC::Shareable;
use DBI;
use IO::File;
use lib '.';

require Exporter;
our @ISA= qw(Exporter);
our @EXPORT_OK = qw(logger %allJobs);
our @EXPORT = qw();
our $VERSION = '0.01';

#use POSIX qw( ENOTCONN ECONNREFUSED ECONNRESET EINPROGRESS EWOULDBLOCK EAGAIN WNOHANG );

# 'exclusive => 0' allows using 'jobrun.pl --kill'
my %shmOptions = (
   create    => 1,
   exclusive => 0,
   mode      => 0644,
   destroy   => 1
);

my $tieType='IPC::Shareable';

$shmOptions{key}='jobpid';
our %jobPids=();
tie %jobPids, $tieType, \%shmOptions or die "tie failed jobPids - $!\n";

our %completedJobs=();
$shmOptions{key}='completed-id';
tie %completedJobs, $tieType, \%shmOptions or die "tie failed %completedJobs= - $!\n";

# %allJobs used when creating resumable file
our %allJobs;

use constant {
    SEM_CHILD_COUNT => 0, # Index for child count semaphore
    SEM_LOCK => 1,        # Index for lock semaphore
};

## transition from tied hash to CSV file and SQL
our $controlTable = 'jobrun_control';

our $dbh = DBI->connect ("dbi:CSV:", undef, undef, {
	f_ext      => ".csv/r",
	RaiseError => 1,
}) or die "Cannot connect: $DBI::errstr";

# Create the table
eval {
	local $dbh->{RaiseError} = 1;
	local $dbh->{PrintError} = 0;

	$dbh->do ("DROP TABLE $controlTable");
	die "Cannot drop table: $DBI::errstr" if $DBI::err;
};

if ($@) {
	#print "Error!: $@\n";
	#print "Table most likely does not exist\n";
	print "Creating table\n";
} else {
	print "Table dropped\n";
}

$dbh->do (
qq{CREATE TABLE $controlTable (
	name CHAR(50)
	, pid CHAR(12)
	, cmd CHAR(200)
	, status CHAR(20)
	, exit_code CHAR(10))
}
);


# Create semaphores
#my $semKey = IPC_PRIVATE; # Private key for IPC
# sem key must be numeric
my $semKey = 51853289;
my $sem = IPC::Semaphore->new($semKey, 2, S_IRUSR | S_IWUSR | IPC_CREAT | SEM_UNDO) or die "Unable to create semaphore: $!";

# Initialize semaphore values
$sem->setval(SEM_CHILD_COUNT, 0);
$sem->setval(SEM_LOCK, 1); # 1 indicates that the lock is available

sub logger {
	my $fh = shift @_;
	my $verbose = shift @_;
	while (@_) {
		my $line = shift @_;
		$fh->print($line);
		print "$line" if $verbose;
	}
	return;
}

sub new {
   my $pkg = shift;
   my $class = ref($pkg) || $pkg;
   #print "Class: $class\n";
   my (%args) = @_;

   my $retval = bless \%args, $class;
   #print 'Sqlrun::new retval: ' . Dumper($retval);
   return $retval;
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
	warn "Jobrun::cleanup() running\n";
	lock();
	$sem->setval(SEM_CHILD_COUNT, 0);
	$sem->setval(SEM_LOCK, 1);
	unlock();
	$sem->remove();

	(tied %completedJobs)->remove();
	(tied %jobPids)->remove();
	IPC::Shareable->clean_up_all();
	return;
}

sub status {
	print "=== STATUS ===\n";
	foreach my $key ( sort keys %jobPids ) {
		print "job: $key status: $jobPids{$key}\n";
	}
	print "====================================\n";
	return;
}

sub showCompletedJobs {

	print "===  COMPLETED ===\n";
	foreach my $key ( sort keys %completedJobs ) {
		print "job: $key status: $completedJobs{$key}\n";
	}
	print "====================================\n";
	return;

}

sub showAllJobs {
	foreach my $key ( sort keys %allJobs ) {
		#$fh->print("$key:$allJobs{$key}\n") unless exists($completedJobs{$key});
		print "$key:$allJobs{$key}\n";
	}
	return;
}

sub createResumableFile {
	my ($resumableFileName) = @_;

	my $fh = new IO::File;
	$fh->open($resumableFileName, '>') or die "could not create resumable file - $resumableFileName: $!\n";

	foreach my $key ( sort keys %allJobs ) {
		$fh->print("$key:$allJobs{$key}\n") unless exists($completedJobs{$key});
		#$fh->print("$key:$allJobs{$key}\n");
	}
	return;
}

# remove the file if empty
sub cleanupResumableFile {
	my ($resumableFileName) = @_;
	-z $resumableFileName && unlink $resumableFileName;
	return;
}

sub getJobPids {
	return \%jobPids;
}

sub child {
	my $self = shift;
	my ($jobName,$cmd) = @_;

	#print 'SELF: ' . Dumper($self);
	my $grantParentPID=$$;

	my $child = fork();
	#die("Can't fork: $!") unless defined ($child = fork());
	die("Can't fork #1: $!") unless defined($child);

	if ($child) {
		logger($self->{LOGFH},$self->{VERBOSE},"child:$$  cmd:$self->{CMD}\n");

	} else {
		my $parentPID=$$;
		my $grandChild = fork();	
		die("Can't fork #2: $!") unless defined($grandChild);

		if ($grandChild == 0 ) {
			# use system() here
			#qx/$cmd/;
			my $pid=$$;

			$jobPids{$self->{JOBNAME}} = "$pid:running";

			logger($self->{LOGFH},$self->{VERBOSE}, "grandChild:$pid:running\n");
			#
			logger($self->{LOGFH} ,$self->{VERBOSE}, "grancChild:$pid running job $self->{JOBNAME}\n");
			system($self->{CMD});
			my $rc = $?;

			if ( $rc != 0 ) {
				logger($self->{LOGFH},$self->{VERBOSE}, "#######################################\n");
				logger($self->{LOGFH},$self->{VERBOSE}, "## error with $self->{JOBNAME}\n");
				logger($self->{LOGFH},$self->{VERBOSE}, "## CMD: $self->{CMD}\n");
				logger($self->{LOGFH},$self->{VERBOSE}, "#######################################\n");
			}

			my $jobStatus = 'complete';
			if ($rc == -1) {
				$jobStatus = 'failed';
				logger($self->{LOGFH},$self->{VERBOSE}, "!!failed to execute: $!\n");
			}
			elsif ($rc & 127) {
				$jobStatus = 'error';
				logger($self->{LOGFH},$self->{VERBOSE}, sprintf "!!child $pid died with signal %d, %s coredump\n",
					($rc & 127),  ($rc & 128) ? 'with' : 'without');
			}
			else {
				logger($self->{LOGFH},$self->{VERBOSE}, sprintf "!!child $pid exited with value %d\n", $? >> 8);
			}
	
			# there seems to be a race condition here
			# jobrun.pl will check for children, and if none are found, it does cleanup
			# however, the child may not have had time to update the semaphore and the status
			# so the driver (jobrun.pl) will create the 'resumable' file, even though the completed
			# fix this by putting the decrement call after the status update
			$jobPids{$self->{JOBNAME}} = "$pid:$jobStatus";
			logger($self->{LOGFH},$self->{VERBOSE}, "just updated jobPids{$self->{JOBNAME}} = $pid:$jobStatus\n");
			$completedJobs{$self->{JOBNAME}} = $self->{CMD};
			logger($self->{LOGFH},$self->{VERBOSE}, "just updated completedJobs{$self->{JOBNAME}} = $self->{CMD}\n");
			decrementChildren();
			exit $rc;
		} else {
			exit 0;
		}

	};

	waitpid($child,0);
	return;
}



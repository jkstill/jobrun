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

=cut


package Jobrun;

use warnings;
use strict;
use Data::Dumper;
use File::Temp qw/ :seekable tmpnam/;
#use Time::HiRes qw( usleep );
use DBI;
use IO::File;
use lib '.';

require Exporter;
our @ISA= qw(Exporter);
our @EXPORT_OK = qw(logger %allJobs);
our @EXPORT = qw();
our $VERSION = '0.01';

our %completedJobs=();

# %allJobs used when creating resumable file
our %allJobs;

our $tableDir = './tables';
mkdir $tableDir unless -d $tableDir;
-d $tableDir or die "table directory $tableDir not created: $!\n";

our $controlTable = 'jobrun_control';

# call this just once from the driver script jobrun.pl
our $utilDBH;
sub init {
	$utilDBH = createDbConnection();
	createTable();
	truncateTable();
}

sub createDbConnection {
	my $dbh = DBI->connect ("dbi:CSV:", undef, undef, 
		{
			f_ext      => ".csv",
			f_dir      => $tableDir,
			flock      => 2,
			RaiseError => 1,
		}
	) or die "Cannot connect: $DBI::errstr";

	return $dbh;
}

sub createTable {
	# create table if it does not exist
	eval {
		local $utilDBH->{RaiseError} = 1;
		local $utilDBH->{PrintError} = 0;

		$utilDBH->do (
			qq{CREATE TABLE $controlTable (
				name CHAR(50)
				, pid CHAR(12)
				, cmd CHAR(200)
				, status CHAR(20)
				, exit_code CHAR(10))
			}
		);
	
	};

	#if ($@) {
	#print "Error: $@\n";
	#print "Table most likely already exists\n";
	#}

	return;
}

sub truncateTable {
	$utilDBH = createDbConnection();
	$utilDBH->do("DELETE FROM $controlTable");
	return;
}

sub insertTable {
	my $self = shift;
	print 'insertTable SELF: ' . Dumper($self);
	my $dbh = $self->{dbh};
	my ($name,$pid,$cmd,$status,$exit_code) = @_;
	my $sth = $dbh->prepare("INSERT INTO $controlTable (name,pid,cmd,status,exit_code) VALUES (?,?,?,?,?)");
	$sth->execute($name,$pid,$cmd,$status,$exit_code);
	# DBD::CSV always autocommits
	# this is here in the event that we use a different DBD
	#$dbh->commit();
}

sub deleteTable {
	my $self = shift;
	my $dbh = $self->{dbh};
	my ($name) = @_;
	my $sth = $dbh->prepare("DELETE FROM $controlTable WHERE name = ?");
	$sth->execute($name);
	#$dbh->commit();
}

sub selectTable {
	my $self = shift;
	my $dbh = $self->{dbh};
	my ($name) = @_;
	my $sth = $dbh->prepare("SELECT * FROM $controlTable WHERE name = ?");
	$sth->execute($name);
	my $row = $sth->fetchrow_hashref;
	return $row;
}

# only updates status and exit_code
sub updateTable {
	my $self = shift;
	my $dbh = $self->{dbh};
	my ($name,$status,$exit_code) = @_;
	my $sth = $dbh->prepare("UPDATE $controlTable SET status = ?, exit_code = ? WHERE name = ?");
	$sth->execute($status,$exit_code,$name);
	#$dbh->commit();
}

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
	
	$args{dbh} = createDbConnection();
	
	$args{insert} = \&insertTable;
	$args{update} = \&updateTable;
	$args{delete} = \&deleteTable;
	$args{select} = \&selectTable;

	# name,pid,cmd,status,exit_code) VALUES (?,?,?,?,?)");
	
	$args{columnNamesByName} = { name => 0, pid => 1, cmd => 2,  status => 3, exit_code => 4};
	$args{columnNamesByIndex} = { 0 => 'name', 1 => 'pid', 2 => 'cmd', 3 => 'status', 4 => 'exit_code'};
	$args{columnValues} = [qw/undef undef undef undef undef/];

	my ($user,$passwd,$uid,$gid,$quota,$comment,$gcos,$dir,$shell,$expire)
   	= getpwuid($<) or die "getpwuid: $!";
	print "User: $user, UID: $uid\n";

   my $retval = bless \%args, $class;

	$retval->{insert}($retval,$retval->{JOBNAME},$$,$retval->{CMD},'running','NA');
   return $retval;
}

sub getChildrenCount {
	# Return current child count
	my $sth = $utilDBH->prepare("SELECT count(*) child_count FROM $controlTable WHERE status = 'running'");
	$sth->execute();
	my $row = $sth->fetchrow_hashref;
	return $row->{child_count} ? $row->{child_count} : 0;
}

sub status {
	my (%config) = @_;
	my $dbh = createDbConnection();
	my $sth = $dbh->prepare("SELECT * FROM $controlTable");
	$sth->execute();
	printf "%-$config{colLenNAME}s %-$config{colLenPID}s %-$config{colLenCMD}s %-$config{colLenSTATUS}s %-$config{colLenEXIT_CODE}s\n", 'name', 'pid', 'cmd', 'status', 'exit_code';
	printf "%-$config{colLenNAME}s %-$config{colLenPID}s %-$config{colLenCMD}s %-$config{colLenSTATUS}s %-$config{colLenEXIT_CODE}s\n", 
		'-' x $config{colLenNAME}, '-' x $config{colLenPID}, '-' x $config{colLenCMD}, '-' x $config{colLenSTATUS}, '-' x $config{colLenEXIT_CODE};
	while (my $row = $sth->fetchrow_hashref) {
		printf "%-$config{colLenNAME}s %-$config{colLenPID}s %-$config{colLenCMD}s %-$config{colLenSTATUS}s %-$config{colLenEXIT_CODE}s\n",
			$row->{name}, $row->{pid}, $row->{cmd}, $row->{status}, $row->{exit_code};
	}
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

# this may be called with --kill, so we need to create a connection
sub getRunningJobPids {
	my $dbh = createDbConnection();
	my $sth = $dbh->prepare("SELECT pid FROM $controlTable WHERE status = 'running'");
	$sth->execute();
	my @jobPids;
	while (my $row = $sth->fetchrow_hashref) {
		push @jobPids, $row->{pid};
	}
	return @jobPids;
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
			logger($self->{LOGFH},$self->{VERBOSE}, "#######################################\n");
			logger($self->{LOGFH},$self->{VERBOSE}, "## job name: $self->{JOBNAME} child pid: $pid\n");
			logger($self->{LOGFH},$self->{VERBOSE}, "#######################################\n");
			my $dbh = $self->{dbh};
			my $sth = $dbh->prepare("UPDATE $controlTable SET pid = ? WHERE name = ?");
			$sth->execute($pid,$self->{JOBNAME});
			#$dbh->commit();

			#$jobPids{$self->{JOBNAME}} = "$pid:running";

			#logger($self->{LOGFH},$self->{VERBOSE}, "grandChild:$pid:running\n");
			##
			#logger($self->{LOGFH} ,$self->{VERBOSE}, "grancChild:$pid running job $self->{JOBNAME}\n");
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
	
			$completedJobs{$self->{JOBNAME}} = $self->{CMD};
			# it should not be necessary to pass $self here, not sure yet why it is necessary
			$self->{update}($self,$self->{JOBNAME},$jobStatus,$rc);
			logger($self->{LOGFH},$self->{VERBOSE}, "just updated completedJobs{$self->{JOBNAME}} = $self->{CMD}\n");
			#decrementChildren();
			exit $rc;
		} else {
			exit 0;
		}

	};

	waitpid($child,0);
	return;
}

1;


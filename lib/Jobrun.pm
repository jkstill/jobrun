# Jared Still 2024-05-21 <jkstill\@gmail.com>
# Refactored to use Moo without changing functionality

package Jobrun;

use Moo;
use warnings;
use strict;
use Data::Dumper;
use File::Temp qw/:seekable tmpnam/;
use DBI;
use Carp;
use IO::File;
use POSIX qw(strftime);
use Time::HiRes qw(time usleep);
use Exporter qw(import);

# Exportable functions
our @EXPORT_OK = qw(
  logger
  childSanityCheck
  createResumableFile
  cleanupResumableFile
  getRunningJobPids
  microSleep
  getTimeStamp
  getTableTimeStamp
  status
  getChildrenCount
  setControlTable
  getControlTable
  init
);

our $VERSION = '0.01';

# directory for CSV control tables
my $tableDir = './tables';
mkdir $tableDir unless -d $tableDir;
-d $tableDir or croak "table directory $tableDir not created: $!\n";

# global control table name and utilDBH
my $controlTable;
my $utilDBH;

# functional interface to set/get control table
sub setControlTable {
    $controlTable = shift;
}

sub getControlTable {
    return $controlTable;
}

# functional init: prepare CSV table
sub init {
    $utilDBH = createDbConnection();
    createTable();
    truncateTable();
}

# create DBI connection for CSV
sub createDbConnection {
    my $dbh = DBI->connect(
        "dbi:CSV:",
        undef,
        undef,
        { f_ext => ".csv", f_dir => $tableDir, flock => 2, RaiseError => 1 }
    ) or croak "Cannot connect: $DBI::errstr";
    return $dbh;
}

# create control table if it does not exist
sub createTable {
    eval {
        local $utilDBH->{RaiseError} = 1;
        local $utilDBH->{PrintError} = 0;
        $utilDBH->do(qq{
            CREATE TABLE $controlTable (
                name CHAR(50),
                pid CHAR(12),
                status CHAR(20),
                start_time CHAR(30),
                end_time CHAR(30),
                elapsed_time CHAR(20),
                exit_code CHAR(10),
                cmd CHAR(200)
            )
        });
    };
}

# clear any existing rows
sub truncateTable {
    $utilDBH = createDbConnection();
    $utilDBH->do("DELETE FROM $controlTable");
}

# Moo attributes for OO interface
has 'dbh' => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_dbh',
);

sub _build_dbh {
    return createDbConnection();
}

has 'JOBNAME' => (
    is       => 'ro',
    required => 1,
);

has 'CMD' => (
    is       => 'ro',
    required => 1,
);

has 'LOGFH' => (
    is      => 'ro',
    default => sub { *STDOUT },
);

has 'VERBOSE' => (
    is      => 'ro',
    default => sub { 0 },
);

# called after object construction
sub BUILD {
    my ($self, $args) = @_;
    my ($user, undef, $uid) = getpwuid($<) or croak "getpwuid: $!";
    print "User: $user, UID: $uid\n";
    # initial insert into control table
    $self->insert(
        $self->JOBNAME,
        $$,
        'running',  # status
        'NA',       # exit_code (note: original ordering)
        '',         # start_time
        '',         # end_time
        '',         # elapsed_time
        $self->CMD  # cmd
    );
}

# OO methods mirror original subs
sub insert {
    my ($self, $name, $pid, $status, $exit_code, $startTime, $endTime, $elapsedTime, $cmd) = @_;
    my $sth = $self->dbh->prepare(
        "INSERT INTO $controlTable (name,pid,status,start_time,end_time,elapsed_time,exit_code,cmd) VALUES (?,?,?,?,?,?,?,?)"
    );
    $sth->execute($name, $pid, $status, $startTime, $endTime, $elapsedTime, $exit_code, $cmd);
}

sub delete {
    my ($self, $name) = @_;
    my $sth = $self->dbh->prepare("DELETE FROM $controlTable WHERE name = ?");
    $sth->execute($name);
}

sub select {
    my ($self, $column, $value) = @_;
    my $sth = $self->dbh->prepare("SELECT * FROM $controlTable WHERE ? = ?");
    $sth->execute($column, $value);
    return $sth->fetchall_hashref;
}

sub updateStatus {
    my ($self, $name, $status, $exit_code, $startTime, $endTime, $elapsedTime) = @_;
    my $sth = $self->dbh->prepare(
        "UPDATE $controlTable SET status = ?, exit_code = ?, start_time = ?, end_time = ?, elapsed_time = ? WHERE name = ?"
    );
    $sth->execute($status, $exit_code, $startTime, $endTime, $elapsedTime, $name);
}

# functional subs that do not require object
sub childSanityCheck {
    my ($logFileFH, $verbose) = @_;
    logger($logFileFH, $verbose, "childSanityCheck()\n");
    my $sth = $utilDBH->prepare("SELECT pid FROM $controlTable WHERE status = ?");
    $sth->execute('running');
    while (my $row = $sth->fetchrow_hashref) {
        my $pid = $row->{pid};
        logger($logFileFH, $verbose, " pid: $pid\n");
        my $rc = kill 0, $pid;
        logger($logFileFH, $verbose, " rc: $rc\n");
        if ($rc == 0) {
            my $dbh = createDbConnection();
            my $sth2 = $dbh->prepare("UPDATE $controlTable SET status = ?, exit_code = ? WHERE pid = ?");
            $sth2->execute('failed', -1, $pid);
        }
    }
}

sub logger {
    my ($fh, $verbose, @msg) = @_;
    for my $line (@msg) {
        $fh->print($line);
        print $line if $verbose;
    }
}

sub getChildrenCount {
    my $sth = $utilDBH->prepare("SELECT count(*) child_count FROM $controlTable WHERE status = 'running'");
    $sth->execute();
    my $row = $sth->fetchrow_hashref;
    return $row->{child_count} ? $row->{child_count} : 0;
}

sub status {
    my ($controlTableName, $statusType, %config) = @_;
    my $dbh = createDbConnection();
    my $sql;
    -r "$tableDir/${controlTableName}.csv" or croak "table $tableDir/$controlTableName.csv does not exist: $!\n";
    if ($statusType eq 'all') {
        $sql = "SELECT * FROM $controlTableName order by start_time asc";
    } else {
        $sql = "SELECT * FROM $controlTableName WHERE status = '$statusType' order by start_time asc";
    }
    print "table: $controlTableName\n";
    my $sth = $dbh->prepare($sql);
    $sth->execute();
    # header
    printf "%-$config{colLenNAME}s %-$config{colLenPID}s %-$config{colLenSTATUS}s %-$config{colLenEXIT_CODE}s %-$config{colLenSTART_TIME}s %-$config{colLenEND_TIME}s %-$config{colLenELAPSED_TIME}s %-$config{colLenCMD}s\n",
        'name','pid','status','exit_code','start_time','end_time','elapsed','cmd';
    printf "%-$config{colLenNAME}s %-$config{colLenPID}s %-$config{colLenSTATUS}s %-$config{colLenEXIT_CODE}s %-$config{colLenSTART_TIME}s %-$config{colLenEND_TIME}s %-$config{colLenELAPSED_TIME}s %-$config{colLenCMD}s\n",
        '-' x $config{colLenNAME}, '-' x $config{colLenPID}, '-' x $config{colLenSTATUS}, '-' x $config{colLenEXIT_CODE}, '-' x $config{colLenSTART_TIME}, '-' x $config{colLenEND_TIME}, '-' x $config{colLenELAPSED_TIME}, '-' x $config{colLenCMD};
    while (my $row = $sth->fetchrow_hashref) {
        printf "%-$config{colLenNAME}s %-$config{colLenPID}s %-$config{colLenSTATUS}s %-$config{colLenEXIT_CODE}s %-$config{colLenSTART_TIME}s %-$config{colLenEND_TIME}s %$config{colLenELAPSED_TIME}s %-$config{colLenCMD}s\n",
            $row->{name}, $row->{pid}, $row->{status}, $row->{exit_code}, $row->{start_time}, $row->{end_time}, sprintf('%6.6f', $row->{elapsed_time} ? $row->{elapsed_time} : 0),
            substr($row->{cmd}, defined $config{colCmdStartPos} ? $config{colCmdStartPos} : 0, defined $config{colCmdEndPos} ? $config{colCmdEndPos} : (length $row->{cmd} -1));
    }
}

sub createResumableFile {
    my ($resumableFileName, $jobsHashRef) = @_;
    my $fh = IO::File->new();
    $fh->open($resumableFileName, '>') or croak "could not create resumable file - $resumableFileName: $!\n";
    my $dbh = createDbConnection();
    my $sql = "SELECT name,status FROM $controlTable WHERE status NOT IN ('complete')";
    my $sth = $dbh->prepare($sql);
    $sth->execute();
    while (my @row = $sth->fetchrow_array) {
        $fh->print("$row[0]:$jobsHashRef->{$row[0]}\n");
    }
}

sub cleanupResumableFile {
    my ($resumableFileName) = @_;
    -z $resumableFileName && unlink $resumableFileName;
}

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

sub microSleep {
    my $microseconds = shift;
    usleep(($microseconds / 1_000_000) * 1_000_000);
}

sub getTimeStamp {
    my @t = [Time::HiRes::gettimeofday]->@*;
    return strftime("%Y-%m-%d %H:%M:%S", localtime $t[0]) . "." . $t[1];
}

sub getTableTimeStamp {
    my @t = [Time::HiRes::gettimeofday]->@*;
    return strftime("%Y_%m_%d_%H_%M_%S", localtime $t[0]);
}

sub child {
    my ($self, $jobName, $cmd) = @_;
    my $grantParentPID = $$;
    my $child = fork();
    croak("Can't fork #1: $!\n") unless defined $child;
    if ($child) {
        logger($self->LOGFH, $self->VERBOSE, "child:$$ cmd:$self->CMD\n");
    } else {
        my $parentPID = $$;
        my $grandChild = fork();
        croak("Can't fork #2: $!\n") unless defined $grandChild;
        if ($grandChild == 0) {
            # update pid in table
            my $pid = $$;
            logger($self->LOGFH, $self->VERBOSE, "#######################################\n");
            logger($self->LOGFH, $self->VERBOSE, "## job name: $self->JOBNAME child pid: $pid\n");
            logger($self->LOGFH, $self->VERBOSE, "#######################################\n");
            my $dbh = $self->dbh;
            my $sth = $dbh->prepare("UPDATE $controlTable SET pid = ? WHERE name = ?");
            $sth->execute($pid, $self->JOBNAME);
            # run the command
            my $startTime = getTimeStamp();
            my @t0 = [Time::HiRes::gettimeofday]->@*;
            $self->updateStatus($self->JOBNAME, 'running', '', $startTime, '', '');
            system($self->CMD);
            my $rc = $? >> 8;
            my @t1 = [Time::HiRes::gettimeofday]->@*;
            my $endTime = getTimeStamp();
            my $elapsedTime = sprintf("%.6f", Time::HiRes::tv_interval(\@t0, \@t1));
            if ($rc != 0) {
                logger($self->LOGFH, $self->VERBOSE, "Error with $self->JOBNAME RC=$rc\n");
            }
            my $jobStatus = $rc == 0 ? 'complete' : 'failed';
            $self->updateStatus($self->JOBNAME, $jobStatus, $rc, $startTime, $endTime, $elapsedTime);
            exit $rc;
        } else {
            exit 0;
        }
    }
    waitpid($child, 0);
}

1;

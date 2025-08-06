#!/usr/bin/env bash

# args are jobname and seconds to sleep
set -o pipefail

jobName="$1"
sleepSeconds="$2"

logDir='joblogs';

mkdir -p $logDir

#logFile=$logDir/$jobName-$(date +%Y-%m-%d_%H-%M-%S).log
logFile="$logDir/$jobName.log"

# Redirect stdout ( > ) into a named pipe ( >() ) running "tee"
# process substitution
# clear/recreate the logfile
> $logFile
# using this method for logging is cool
# but it causes problems when killing processes with jobrun.pl --kill or CTL-\ (SIGQUIT) 
# scripts get a sigpipe error and dump core
#exec 1> >(tee -ia $logFile)
#exec 2> >(tee -ia $logFile >&2)

echo "job: $jobName" | tee -a $logFile
echo "my pid: $$" | tee -a $logFile

sleep $sleepSeconds
echo "exiting job: $jobName" | tee -a $logFile

exit 2


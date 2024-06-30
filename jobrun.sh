#!/usr/bin/env bash


# does not work in Bash 3
# does work in Bash 4.2, possibly earlier

# always returns the location of the current script
scriptHome=$(dirname -- "$( readlink -f -- "$0"; )")

cd $scriptHome || { echo "could not cd $scriptHome"; exit 1; }


help () {
	echo
	echo $0
	cat <<-EOF


  -f  timestamp format - default %Y-%m-%d %H-%M-%S
  -i  interval seconds - default 10
  -j  jobs config file - default jobs.conf
  -r  jobrun config file - default jobrun.conf
  -m  max concurrent jobs - default 5
  -s  log directory  - default logs
  -t  log file base name - default jobrun-sh
  -u  log file suffix - default log
  -d  debug on - output is to STDERR
  -n  debug off - overrides config file
  -y  dry run - read arguments, config file, show variables and exit
  -h  help

EOF
}

declare timestampFormat=''
declare logDir=''
declare logFileSuffix=''
declare logFileName=''
declare intervalSeconds=''
declare maxConcurrentJobs=''
declare jobrunConfigFile=jobrun.conf
declare jobsConfigFile=jobs.conf
declare DEBUG=''
declare dryRun='N'

while getopts f:s:t:u:i:m:j:r:hzdny arg
do
	case $arg in
		f) timestampFormat="$OPTARG";;
		i) intervalSeconds=$OPTARG;;
		s) logDir=$OPTARG;;
		t) logFileName=$OPTARG;;
		u) logFileSuffix=$OPTARG;;
		m) maxConcurrentJobs=$OPTARG;;
		d) DEBUG='Y';;
		n) DEBUG='N';;  # override config file
		j) jobsConfigFile=$OPTARG;;
		r) jobrunConfigFile=$OPTARG;;
		y) dryRun='Y';;
		hz) help; exit 0;;
		*) help; exit 1;;
	esac
done

echo "interval seconds: $intervalSeconds"

fileIsReadable () {
	if [[ -r "$1" ]]; then
		return 0
	else
		return 1
	fi
}

getTimestamp () {
	date "+$timestampFormat"
}

banner () {
	echo
	echo '############################################################'
	echo "## $@ "
	echo '############################################################'
	echo
	return 0
}

subBanner () {
	echo '==============================='
	echo "=== $@ ==="
	return 0
}

debugBanner () {
	[[ $DEBUG == 'Y' ]] && { echo '%% ' $(getTimestamp) ": $@"; }
	return 0
}

stdoutBanner () {
	echo $(getTimestamp) ":$@"
}

# return array of key value pairs
getKV () {
	local arrayName="$1"
	local fileName="$2"

	fileIsReadable $fileName
	RC=$?
	if [[ $RC -eq 0 ]]; then
		while IFS=: read key value
		do
			debugBanner "getKV - key: $key  value: $value"
			debugBanner "$arrayName['$key']"="'$value'"
			eval "$arrayName['$key']"="'$value'"
		done < <(grep -Ev '^\s*$|^\s*#' $fileName) 
	else
		stdoutBanner "cannot read file $fileName"
		exit 1
	fi
}

showKV () {
	# works directly with Hash Array in Bash 4.3+
	#local -n arrayName="$1" #[@];shift
	# value required in older versions

	local bannerPrefix=''
	[[ $DEBUG == 'Y' ]] && { bannerPrefix='%%'; }
	local arrayName="$1"

	local -a keys
	declare keyString='${!'$arrayName'[@]}'

	declare -a keys
	eval keys="$keyString"

	for key in ${keys[@]}
	do
		eval 'val=${'$arrayName'['$key']}'
		echo "$bannerPrefix key: $key  val: $val"
	done

	return 0
}

declare -A jobsConf
declare -A jobrunConf

banner "getKV $jobrunConfigFile"
getKV jobrunConf $jobrunConfigFile
showKV jobrunConf

banner "getKV $jobsConfigFile"
getKV jobsConf $jobsConfigFile
showKV jobsConf


# set config values from jobrun.conf
if [[ ${jobrunConf['debug']} ]]; then
	[ ${jobrunConf['debug']} == '1' -a -z "$DEBUG" ] && { DEBUG='Y'; }
else
	DEBUG='N'
fi

echo "time format $timestampFormat|"

if [[ -z $timestampFormat ]]; then
	if [[ -n ${jobrunConf['timestamp-format']} ]]; then
		timestampFormat=${jobrunConf['timestamp-format']}
	else
		timestampFormat='%Y-%m-%d %H:%M:%S'
	fi
fi

if [[ -z $maxConcurrentJobs ]]; then
	if [[ -n ${jobrunConf['maxjobs']} ]]; then
		maxConcurrentJobs=${jobrunConf['maxjobs']}
	else
		maxConcurrentJobs=5
	fi
fi

if [[ -z $intervalSeconds ]]; then
	if [[ -n ${jobrunConf['iteration-seconds']} ]]; then
		{ intervalSeconds=${jobrunConf['iteration-seconds']}; }
	else
		intervalSeconds=10
	fi
fi

if [[ -z $logDir ]]; then
	if [[ -n "${jobrunConf['logdir']}" ]]; then
		logDir=${jobrunConf['logdir']}
	else
		logDir='logs';
	fi
fi

if [[ -z $logFileName ]]; then
	if [[ -n ${jobrunConf['logfile']} ]]; then
		logFileName=${jobrunConf['logfile']}
	else
		logFileName='jobrun-sh'
	fi
fi

if [[ -z $logFileSuffix ]]; then
	if [[ -n "${jobrunConf['logfile-suffix']}" ]]; then
		logFileSuffix=${jobrunConf['logfile-suffix']}
	else
		logFileSuffix='log'
	fi
fi

mkdir -p $logDir
logFile=$logDir/$logFileName-$(date +%Y-%m-%d_%H-%M-%S).$logFileSuffix

cat <<-EOF

  timestampFormat: $timestampFormat
           logDir: $logDir
    logFileSuffix: $logFileSuffix
      logFileName: $logFileName
  intervalSeconds: $intervalSeconds
          logFile: $logFile
maxConcurrentJobs: $maxConcurrentJobs
 jobrunConfigFile: $jobrunConfigFile
   jobsConfigFile: $jobsConfigFile
            debug: $DEBUG

EOF

[[ $dryRun == 'Y' ]] && { exit; }

# Redirect stdout ( > ) into a named pipe ( >() ) running "tee"
# process substitution
# clear/recreate the logfile
> $logFile
exec 1> >(tee -ia $logFile)
tee01PID=$!
exec 2> >(tee -ia $logFile >&2)
tee02PID=$!

set -u

declare PGID=$$

declare -A runningJobs=()
declare -A runningPIDS
declare -A completedJobs

declare numberJobsRunning
declare pidFileDir=pidfiles

onTerm () {
	echo
	stdoutBanner "TERM: Cleaning up"
	ps -o pgid,pid,ppid,cmd | grep "^$PGID"
	kill -KILL -- -$PGID
	echo
	exit
}

trap onTerm SEGV TERM INT

declare -a jobKeys ##="${!jobsConf[@]}"
for v in ${!jobsConf[@]}
do
	jobKeys+=($v)
done

numberJobsRunning=0
userName=$(id -un)

pidCleanup () {

	local -a pidsToRemove=()

	debugBanner 'runningPIDs'
	[[ $DEBUG == 'Y' ]] && { showKV runningPIDS; }

	for runPID in ${!runningPIDS[@]} 
	do
		debugBanner "chk runPID: $runPID"
		psOUT=$(ps --no-headers -p $runPID -o user,pid | grep "^$userName")
		declare RC=$?

		debugBanner "RC: $RC"
		debugBanner "psOUT: $psOUT"
		debugBanner "runPID: $runPID"

		timestamp="$(getTimestamp)"

		if [[ $RC -eq 0 ]]; then
			stdoutBanner "PID Job still running: ${runningPIDS[$runPID]}"
			stdoutBanner "$timestamp - still running "  >> $pidFileDir/${runPID}.pid 
		else
			stdoutBanner "$timestamp - finished "  >> $pidFileDir/${runPID}.pid 
			declare currJob=${runningPIDS[$runPID]}
			unset runningJobs[$currJob]
			pidsToRemove+=($runPID)
			(( numberJobsRunning-- ))
		fi
	done

	# clean up runningPIDS after loop
	debugBanner "=====>>>> pidsToRemove:"
	for pid in ${pidsToRemove[@]}
	do
		debugBanner "=====>>>> remove runningPID: $pid"
		unset runningPIDS[$pid]
	done

	return
}

mkdir -p $pidFileDir

while :
do

	if [[ ${#runningJobs[@]} -lt $maxConcurrentJobs ]]; then

		stdoutBanner "jobKeys count: ${#jobKeys[@]}"

		[[ ${#jobKeys[@]} -lt 1 ]] && { break; }
		jobKey="${jobKeys[0]}"

		stdoutBanner jobkey: $jobKey
		stdoutBanner "jobsConf count: ${#jobsConf[@]}"

		jobKeys=(${jobKeys[@]:1}) # shift array
		(( numberJobsRunning++ ))
		runningJobs[$jobKey]=${jobsConf[$jobKey]}

		stdoutBanner "run: ${jobsConf[$jobKey]}"
		exec ${jobsConf[$jobKey]} &
		childPID=$!
		runningPIDS[$childPID]=$jobKey

		ps -p $childPID -o pid,ppid,cmd > $pidFileDir/${childPID}.pid
		unset jobsConf[$jobKey]
		stdoutBanner "Continuing"
		continue

	fi

	subBanner "Checking RunPIDS"
	pidCleanup

	#[[ ${#jobsConf[@]} -lt 0 ]] && { break; }

	stdoutBanner "sleep $intervalSeconds"
	sleep $intervalSeconds

done

# may still be jobs running
subBanner "check for any remaining jobs to complete"
while [[ ${#runningJobs[@]} -gt 0 ]]
do
	stdoutBanner "Calling PID Cleanup"
	pidCleanup
	sleep $intervalSeconds
done

kill $tee01PID $tee02PID

stdoutBanner
echo "There should be no output following here other than captions"
echo 

echo "runningJobs:"
showKV runningJobs

echo "jobsConf:"
showKV jobsConf

echo "jobKeys:"
showKV jobKeys



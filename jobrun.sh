#!/usr/bin/env bash


# does not work in Bash 3
# does work in Bash 4.2, possibly earlier

# always returns the location of the current script
scriptHome=$(dirname -- "$( readlink -f -- "$0"; )")

cd $scriptHome || { echo "could not cd $scriptHome"; exit 1; }

logDir='logs';

mkdir -p $logDir

logFile=$logDir/jobrun-sh-$(date +%Y-%m-%d_%H-%M-%S).log

# Redirect stdout ( > ) into a named pipe ( >() ) running "tee"
# process substitution
# clear/recreate the logfile
> $logFile
exec 1> >(tee -ia $logFile)
tee01PID=$!
exec 2> >(tee -ia $logFile >&2)
tee02PID=$!

help () {
	echo
	echo $0
	cat <<-EOF


  -j  jobs config file - default jobs.conf
  -r  jobrun config file - default jobrun.conf
  -m  max concurrent jobs - default 5
  -d  debug on
  -h  help

EOF
}

declare maxConcurrentJobs=5
declare jobrunConfigFile=jobrun.conf
declare jobsConfigfile=jobs.conf
declare DEBUG='N'

while getopts j:r:m:dhz arg
do
	case $arg in
		j) jobsConfigfile=$OPTARG;;
		r) jobrunConfigfile=$OPTARG;;
		m) maxConcurrentJobs=$OPTARG;;
		d) DEBUG='Y';;
		hz) help; exit 0;;
		*) help; exit 1;;

	esac
done

set -u

declare PGID=$$

declare -A runningJobs=()
declare -A runningPIDS
declare -A completedJobs
declare intervalSeconds=3

declare numberJobsRunning
declare pidFileDir=pidfiles

onTerm () {
	echo
	echo "TERM: Cleaning up"
	ps -o pgid,pid,ppid,cmd | grep "^$PGID"
	kill -KILL -- -$PGID
	echo
	exit
}

trap onTerm SIGV TERM INT

banner () {
	echo
	echo '############################################################'
	echo "## $@ "
	echo '############################################################'
	echo
}

subBanner () {
	echo
	echo '   ============================================================'
	echo "   == $@ "
	echo '   ============================================================'
	echo
}


fileIsReadable () {
	if [[ -r "$1" ]]; then
		return 0
	else
		return 1
	fi
}

getTimestamp () {
	date '+%Y-%m-%d %H:%M:%S'
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
			if [[ $DEBUG == 'Y' ]]; then
				echo "getKV - key: $key  value: $value" 1>&2
				echo "$arrayName['$key']"="'$value'"
			fi
			eval "$arrayName['$key']"="'$value'"
		done < <(grep -Ev '^\s*$|^\s*#' $fileName) 
	else
		echo "cannot read file $fileName"
		exit 1
	fi
}

showKV () {
	# works directly with Hash Array in Bash 4.3+
	#local -n arrayName="$1" #[@];shift
	# value required in older versions

	local arrayName="$1"

	local -a keys
	declare keyString='${!'$arrayName'[@]}'

	declare -a keys
	eval keys="$keyString"

	for key in ${keys[@]}
	do
		eval 'val=${'$arrayName'['$key']}'
		echo "key: $key  val: $val"
		#echo key: $key
	done

	return 0
}


declare -A jobsConf
declare -A jobrunConf

banner "getKV jobrun.conf"
getKV jobrunConf jobrun.conf
showKV jobrunConf

banner "getKV jobs.conf"
getKV jobsConf jobs.conf
showKV jobsConf

declare -a jobKeys ##="${!jobsConf[@]}"
for v in ${!jobsConf[@]}
do
	jobKeys+=($v)
done


#maxConcurrentJobs=5
numberJobsRunning=0
#runningJobs=()

userName=$(id -un)

pidCleanup () {

	local -a pidsToRemove

	[[ $DEBUG == 'Y' ]] && { showKV runningPIDS; }

	for runPID in ${!runningPIDS[@]} 
	do
		echo "chk runPID: $runPID"
		psOUT=$(ps --no-headers -p $runPID -o user,pid | grep "^$userName")
		declare RC=$?

		if [[ $DEBUG == 'Y' ]]; then
			echo "RC: $RC"
			echo "psOUT: $psOUT"
			echo "runPID: $runPID"
		fi

		timestamp="$(getTimestamp)"

		if [[ $RC -eq 0 ]]; then
			echo "running PID Job: ${runningPIDS[$runPID]}"
			echo "$timestamp - still running "  >> $pidFileDir/${runPID}.pid 
		else
			echo "$timestamp - finished "  >> $pidFileDir/${runPID}.pid 
			declare currJob=${runningPIDS[$runPID]}
			unset runningJobs[$currJob]
			(( numberJobsRunning-- ))
		fi
	done

	return
}

mkdir -p $pidFileDir

while :
do

	if [[ ${#runningJobs[@]} -lt $maxConcurrentJobs ]]; then

		echo "jobKeys count: ${#jobKeys[@]}"

		[[ ${#jobKeys[@]} -lt 1 ]] && { break; }
		jobKey="${jobKeys[0]}"

		echo jobkey: $jobKey
		echo "jobsConf count: ${#jobsConf[@]}"

		jobKeys=(${jobKeys[@]:1}) # shift array
		(( numberJobsRunning++ ))
		runningJobs[$jobKey]=${jobsConf[$jobKey]}

		echo "run: ${jobsConf[$jobKey]}"
		exec ${jobsConf[$jobKey]} &
		childPID=$!
		runningPIDS[$childPID]=$jobKey

		ps -p $childPID -o pid,ppid,cmd > $pidFileDir/${childPID}.pid
		unset jobsConf[$jobKey]
		echo "Continuing"
		continue

	fi

	echo "Checking RunPIDS"
	pidCleanup

	#[[ ${#jobsConf[@]} -lt 0 ]] && { break; }

	echo "sleep $intervalSeconds"
	sleep $intervalSeconds

done

# may still be jobs running
while [[ ${#runningJobs[@]} -gt 0 ]]
do
	echo "check for any remaining jobs to complete"
	pidCleanup
	sleep $intervalSeconds
done

kill $tee01PID $tee02PID

echo
echo "should be no output here other than captions"
echo 

echo "runningJobs:"
showKV runningJobs

echo "jobsConf:"
showKV jobsConf

echo "jobKeys:"
showKV jobKeys



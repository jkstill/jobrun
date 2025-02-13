#!/usr/bin/env bash

: ${DRYRUN:='N'}

# This script will clear all shared memory and semaphore owned by the current user
# That is rather dangerous, so use it with caution

USERID=$(id -un)

[[ $USERID =~ root|oracle|grid ]] && echo "You are not allowed to run this script as $USERID" && exit 1

[[ -z $(ipcs -m| grep ^0x| grep $USERID) ]] && [[ -z $(ipcs -s| grep ^0x| grep $USERID) ]] && echo "No shared memory or semaphore owned by $USERID" && exit 0

[[ $DRYRUN == 'Y' ]] && {

	ipcs -m| head -3
	ipcs -m| grep ^0x| grep $USERID

	ipcs -s| head -3
	ipcs -s| grep ^0x| grep $USERID

	exit 0
}

ipcs -m| grep ^0x| grep $USERID | awk '{ print $2 }'| xargs --no-run-if-empty -n 1 ipcrm -m
ipcs -s| grep ^0x| grep $USERID | awk '{ print $2 }'| xargs --no-run-if-empty -n 1 ipcrm -s


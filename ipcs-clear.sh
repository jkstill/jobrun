#!/usr/bin/env bash

ipcs -m| grep ^0x| awk '{ print $2 }'| xargs -n 1 ipcrm -m

ipcs -s| grep ^0x| awk '{ print $2 }'| xargs -n 1 ipcrm -s

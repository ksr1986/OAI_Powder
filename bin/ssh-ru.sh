#!/bin/bash
RU=$1
HOST_IP=10.10.0.1
RU_IP=10.10.0.100
NULL_IP=0.0.0.0

if [ -z $RU ]; then
  echo "Usage: $0 <ru>"
  exit 1
fi

if [ $RU == "1" ]; then
  sudo ifconfig eno12409 $HOST_IP
elif [ $RU == "2" ]; then
  sudo ifconfig eno12409 $NULL_IP
fi

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$RU_IP

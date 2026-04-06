#!/bin/bash
RU_IP=$1
TARGET_DIR=$2
FILES=(/etc/tdd.xml /etc/ru_config.cfg /etc/ru-bandwidth /etc/ru-center-frequency-mhz /usr/sbin/radio_setup_a.sh)
SCP_ARGS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

if [ $# -lt 2 ]; then
    echo "usage: pull-ru-config.sh <ru_ip> <target_dir>"
    exit 1
fi

if [ ! -d $TARGET_DIR ]; then
    echo "target directory $TARGET_DIR does not exist"
    mkdir -p $TARGET_DIR
fi

for file in ${FILES[@]}; do
    echo "pulling $file from $RU_IP to $TARGET_DIR"
    scp $SCP_ARGS root@$RU_IP:$file $TARGET_DIR
done

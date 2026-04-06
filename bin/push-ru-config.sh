#!/bin/bash
SOURCE_DIR=$1
RU_IP=$2
SCP_ARGS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

if [ $# -lt 2 ]; then
    echo "usage: push-ru-config.sh <source_dir> <ru_ip>"
    exit 1
fi

if [ ! -d $SOURCE_DIR ]; then
    echo "source directory $SOURCE_DIR does not exist"
    exit 1
fi

scp $SCP_ARGS $SOURCE_DIR/tdd.xml root@$RU_IP:/etc/tdd.xml
scp $SCP_ARGS $SOURCE_DIR/ru_config.cfg root@$RU_IP:/etc/ru_config.cfg
scp $SCP_ARGS $SOURCE_DIR/ru-bandwidth root@$RU_IP:/etc/ru-bandwidth
scp $SCP_ARGS $SOURCE_DIR/ru-center-frequency-mhz root@$RU_IP:/etc/ru-center-frequency-mhz
scp $SCP_ARGS $SOURCE_DIR/radio_setup_a.sh root@$RU_IP:/usr/sbin/radio_setup_a.sh

#!/bin/bash
set -ex

TMPDIR=/tmp
#
# Latest version of iperf fixes the server side hang problem.
#
wget -q --no-check-certificate https://www.emulab.net/downloads/iperf-3.15.tar.gz
if [ $? -ne 0 ]; then
    echo 'ERROR: Could not fetch iperf3 tarfile'
    exit 1
fi
tar -C $TMPDIR -zxf iperf-3.15.tar.gz
if [ $? -ne 0 ]; then
    echo 'ERROR: Could not unpack iperf3 tarfile'
    exit 1
fi
(cd $TMPDIR/iperf-3.15; ./configure; make)
if [ $? -ne 0 ]; then
    echo 'ERROR: Could not configure/build iperf3'
    exit 1
fi
(cd $TMPDIR/iperf-3.15; sudo make install)
if [ $? -ne 0 ]; then
    echo 'ERROR: Could not install iperf3'
    exit 1
fi

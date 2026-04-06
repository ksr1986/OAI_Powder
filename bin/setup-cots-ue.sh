#!/bin/bash
set -ex
BINDIR=`dirname $0`
source $BINDIR/common.sh

if [ $# -eq 0 ] || [ $# -gt 1 ]; then
    echo "usage: $0 [dnn]"
    exit 1
fi
DNN=$1

install_ue_deps () {
    sudo apt update && sudo apt install -y --no-install-recommends \
      iperf3 \
      python3-pip \
      python3-zmq
    sudo pip3 install -r $CFGDIR/requirements.txt
}

add_ue_app () {
    sudo cp $BINDIR/ue_app.py $SRCDIR
}

maybe_add_ue_metrics () {
    if ! test -f /etc/systemd/system/ue-metrics.service; then
        sudo cp $SERVICESDIR/ue-metrics.service /etc/systemd/system/ue-metrics.service
        sudo cp $BINDIR/ue_metrics.py $SRCDIR
    fi
}

maybe_add_quectel_control () {
    if ! test -f /etc/systemd/system/quectel-control.service; then
        sudo cp $SERVICESDIR/quectel-control.service /etc/systemd/system/quectel-control.service
        sudo cp $BINDIR/quectel_control.py $SRCDIR
        sudo systemctl daemon-reload
        sudo systemctl enable quectel-control
        sudo systemctl restart quectel-control
    fi
}

update_udhcpc_script () {
    sudo cp $BINDIR/default.script /etc/udhcpc/default.script
    sudo chmod +x /etc/udhcpc/default.script
}

maybe_add_quectel_cm () {
    if ! test -f /etc/systemd/system/quectel-cm.service; then
        echo "Configuring UE for DNN $DNN"
        sudo cp $SERVICESDIR/quectel-cm.service /etc/systemd/system/quectel-cm.service
        sudo sed -i "s/internet/$DNN/" /etc/systemd/system/quectel-cm.service
        update_udhcpc_script
        sudo systemctl daemon-reload
        sudo systemctl enable quectel-cm
        sudo systemctl restart quectel-cm
    fi
}

install_ue_deps
add_ue_app
maybe_add_ue_metrics
maybe_add_quectel_control
maybe_add_quectel_cm

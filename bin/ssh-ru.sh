#!/bin/bash
BINDIR=$(dirname "$0")
source "$BINDIR/common.sh"

RU=$1
FH_PARENT_IF=eno12409
HOST_IP=10.10.0.1
RU_IP=10.10.0.100

if [ -z "$RU" ]; then
  echo "Usage: $0 <ru>"
  exit 1
fi

if [ "$RU" == "1" ]; then
    # Detect the VLAN sub-interface created by Emulab/update-ru-vlan.sh
    FH_VLAN_IF=$(ip link show 2>/dev/null | grep -oP "${FH_PARENT_IF}\.\d+" | head -1)
    if [ -z "$FH_VLAN_IF" ]; then
        echo "ERROR: No VLAN sub-interface found on $FH_PARENT_IF. Has update-ru-vlan.sh run?"
        exit 1
    fi
    echo "Using fronthaul interface: $FH_VLAN_IF"
    # Assign host IP on VLAN sub-interface if not already set
    if ! ip addr show "$FH_VLAN_IF" | grep -q "$HOST_IP"; then
        sudo ip addr add ${HOST_IP}/24 dev "$FH_VLAN_IF" 2>/dev/null || true
        sudo ip link set "$FH_VLAN_IF" up
    fi
fi

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$RU_IP

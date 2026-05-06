#!/bin/bash

BINDIR=`dirname $0`
source $BINDIR/common.sh

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

# Physical function (PF) interface name for SR-IOV (U-plane port)
IF_NAME=eno12409
# VF interface names created by the kernel from the PF
IF_VF0=eno12409v0
IF_VF1=eno12409v1
# PCI bus addresses of the two VFs (verify with: dpdk-devbind.py -s after creating VFs)
U_PLANE_PCI_BUS_ADD=0000:43:09.0
C_PLANE_PCI_BUS_ADD=0000:43:09.1

MAX_RING_BUFFER_SIZE=$(ethtool -g $IF_NAME|grep "maxi" -A1|awk '/RX/{print $2}')
MTU=8192
DU_U_PLANE_MAC_ADD=30:3e:a7:1a:9f:49
DU_C_PLANE_MAC_ADD=30:3e:a7:1a:9f:49
DRIVER=vfio_pci

# Read fronthaul VLAN from manifest; fall back to DEFAULT_FH_VLAN from common.sh
echo "Reading fronthaul VLAN ID from manifest..."
VLAN=$(get_fh_vlan_from_manifest)
if [[ "$VLAN" =~ ^[0-9]+$ ]]; then
    echo "Using VLAN $VLAN from manifest."
else
    VLAN=$DEFAULT_FH_VLAN
    echo "Could not read VLAN from manifest. Using default: $VLAN"
fi

ethtool -G $IF_NAME rx $MAX_RING_BUFFER_SIZE tx $MAX_RING_BUFFER_SIZE
ip link set $IF_NAME mtu $MTU
modprobe iavf
echo 0 > /sys/class/net/$IF_NAME/device/sriov_numvfs
echo 2 > /sys/class/net/$IF_NAME/device/sriov_numvfs
sleep 1
ip a

ip link set $IF_NAME vf 0 mac $DU_U_PLANE_MAC_ADD vlan $VLAN mtu $MTU # set U-plane VF MAC/VLAN
ip link set $IF_NAME vf 0 spoofchk off
ip link set $IF_NAME vf 1 mac $DU_C_PLANE_MAC_ADD vlan $VLAN mtu $MTU # set C-plane VF MAC/VLAN
ip link set $IF_NAME vf 1 spoofchk off
sleep 1

ifconfig $IF_VF0 0
ifconfig $IF_VF1 0
dpdk-devbind.py --unbind $U_PLANE_PCI_BUS_ADD
dpdk-devbind.py --unbind $C_PLANE_PCI_BUS_ADD
modprobe $DRIVER
dpdk-devbind.py --bind vfio-pci $U_PLANE_PCI_BUS_ADD
dpdk-devbind.py --bind vfio-pci $C_PLANE_PCI_BUS_ADD
dpdk-devbind.py -s
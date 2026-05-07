#!/bin/bash
# SR-IOV setup for OAI gNB fronthaul (eCPRI over DPDK).
# Standalone: does not rely on common.sh.
# Must be run as root (sudo). Safe to re-run.

# ============================================================
# CONFIGURATION — edit these if hardware changes
# ============================================================
# Fronthaul VLAN (assigned by Emulab; 168 is the known value for this experiment)
DEFAULT_FH_VLAN=168

# SR-IOV physical function interface (eCPRI DPDK port)
IF_NAME=eno12409
# VF interface names created by the kernel from the PF
IF_VF0=eno12409v0
IF_VF1=eno12409v1

# PCI bus addresses of the two VFs (verify with: dpdk-devbind.py -s after creating VFs)
U_PLANE_PCI_BUS_ADD=0000:43:09.0
C_PLANE_PCI_BUS_ADD=0000:43:09.1

MTU=8192
DU_MAC_ADD=30:3e:a7:1a:9f:49
DRIVER=vfio_pci

# ============================================================
# Helper: read fronthaul VLAN ID from experiment manifest
# ============================================================
get_fh_vlan_from_manifest() {
    command -v geni-get &>/dev/null || return
    geni-get manifest 2>/dev/null | python3 - <<'PYEOF'
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.stdin).getroot()
    ns = root.tag.split('}')[0].lstrip('{') if '}' in root.tag else ''
    pfx = ('{%s}' % ns) if ns else ''
    for link in root.iter('%slink' % pfx):
        if link.get('client_id') == 'duru1t':
            vlan = link.get('vlantag', '').strip()
            if vlan:
                print(vlan)
            break
except Exception as e:
    sys.stderr.write("manifest parse error: %s\n" % e)
PYEOF
}

# ============================================================
# SANITY CHECK
# ============================================================
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

# ============================================================
# SR-IOV SETUP
# ============================================================
echo "Reading fronthaul VLAN ID from manifest..."
VLAN=$(get_fh_vlan_from_manifest)
if [[ "$VLAN" =~ ^[0-9]+$ ]]; then
    echo "Using VLAN $VLAN from manifest."
else
    VLAN=$DEFAULT_FH_VLAN
    echo "Could not read VLAN from manifest. Using default: $VLAN"
fi

MAX_RING_BUFFER_SIZE=$(ethtool -g $IF_NAME | grep "maxi" -A1 | awk '/RX/{print $2}')
ethtool -G $IF_NAME rx $MAX_RING_BUFFER_SIZE tx $MAX_RING_BUFFER_SIZE
ip link set $IF_NAME mtu $MTU
modprobe iavf
echo 0 > /sys/class/net/$IF_NAME/device/sriov_numvfs
echo 2 > /sys/class/net/$IF_NAME/device/sriov_numvfs
sleep 1
ip a

ip link set $IF_NAME vf 0 mac $DU_MAC_ADD vlan $VLAN mtu $MTU
ip link set $IF_NAME vf 0 spoofchk off
ip link set $IF_NAME vf 1 mac $DU_MAC_ADD vlan $VLAN mtu $MTU
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
echo "SR-IOV configured: VFs $IF_VF0 and $IF_VF1 bound to vfio-pci"
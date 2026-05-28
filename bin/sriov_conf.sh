#!/bin/bash
set -euo pipefail
# SR-IOV setup for OAI gNB fronthaul (eCPRI over DPDK).
# Standalone: does not rely on common.sh.
# Must be run as root (sudo). Safe to re-run.

# ============================================================
# CONFIGURATION — edit these if hardware changes
# ============================================================
# Fronthaul VLAN (decimal; must match RU config which stores it as hex)
DEFAULT_FH_VLAN=193

# SR-IOV physical function interface (eCPRI DPDK port)
IF_NAME=eno12409
# VF interface names created by the kernel from the PF
IF_VF0=eno12409v0
#IF_VF1=eno12409v1  # only 1 VF used

# PCI bus address — discovered dynamically from sysfs after VF creation (do not hardcode)
U_PLANE_PCI_BUS_ADD=""
#C_PLANE_PCI_BUS_ADD=""  # only 1 VF; same PCI address used for both planes

MTU=8192
# U-plane MAC assigned to VF0 (single VF handles both U and C plane)
DU_U_PLANE_MAC_ADD=30:3e:a7:1a:8e:49
#DU_C_PLANE_MAC_ADD=30:3e:a7:1a:8e:49  # only 1 VF; same MAC used for both planes
DRIVER=vfio_pci

# ============================================================
# Helper: read fronthaul VLAN ID from experiment manifest
# ============================================================
# get_fh_vlan_from_manifest() {
#     command -v geni-get &>/dev/null || return
#     geni-get manifest 2>/dev/null | python3 - <<'PYEOF'
# import sys, xml.etree.ElementTree as ET
# try:
#     root = ET.parse(sys.stdin).getroot()
#     ns = root.tag.split('}')[0].lstrip('{') if '}' in root.tag else ''
#     pfx = ('{%s}' % ns) if ns else ''
#     for link in root.iter('%slink' % pfx):
#         if link.get('client_id') == 'duru1t':
#             vlan = link.get('vlantag', '').strip()
#             if vlan:
#                 print(vlan)
#             break
# except Exception as e:
#     sys.stderr.write("manifest parse error: %s\n" % e)
# PYEOF
# }

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
# echo "Reading fronthaul VLAN ID from manifest..."
# VLAN=$(get_fh_vlan_from_manifest)
# if [[ "$VLAN" =~ ^[0-9]+$ ]]; then
#     echo "Using VLAN $VLAN from manifest."
# else
#     VLAN=$DEFAULT_FH_VLAN
#     echo "Could not read VLAN from manifest. Using default: $VLAN"
# fi
VLAN=193
echo "Using hardcoded VLAN $VLAN."

# ============================================================
# HUGEPAGES — allocate at runtime so DPDK can initialise
# without requiring a reboot after GRUB update.
# ============================================================
HUGEPAGE_1G=/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
if [ -f "$HUGEPAGE_1G" ]; then
    CURRENT_HP=$(cat "$HUGEPAGE_1G")
    if [ "$CURRENT_HP" -lt 20 ]; then
        echo "Allocating 20 x 1GB hugepages (currently $CURRENT_HP)..."
        echo 20 > "$HUGEPAGE_1G"
        ALLOCATED=$(cat "$HUGEPAGE_1G")
        if [ "$ALLOCATED" -lt 20 ]; then
            echo "WARNING: Only $ALLOCATED hugepages allocated (requested 20). System may not have enough contiguous memory."
        else
            echo "Hugepages OK: $ALLOCATED x 1GB allocated."
        fi
    else
        echo "Hugepages already allocated: $CURRENT_HP x 1GB."
    fi
else
    echo "WARNING: 1GB hugepage sysfs path not found. Ensure kernel supports 1G pages and GRUB is updated."
fi

MAX_RING_BUFFER_SIZE=$(ethtool -g $IF_NAME | grep "maxi" -A1 | awk '/RX/{print $2}')
ethtool -G $IF_NAME rx $MAX_RING_BUFFER_SIZE tx $MAX_RING_BUFFER_SIZE
ip link set $IF_NAME mtu $MTU
modprobe iavf
echo 0 > /sys/class/net/$IF_NAME/device/sriov_numvfs
echo 1 > /sys/class/net/$IF_NAME/device/sriov_numvfs
sleep 2

# Discover actual VF PCI address from sysfs
U_PLANE_PCI_BUS_ADD=$(basename "$(readlink /sys/class/net/$IF_NAME/device/virtfn0)")
#C_PLANE_PCI_BUS_ADD=$(basename "$(readlink /sys/class/net/$IF_NAME/device/virtfn1)")  # only 1 VF
if [[ -z "$U_PLANE_PCI_BUS_ADD" ]]; then
    echo "ERROR: Could not discover VF PCI address from /sys/class/net/$IF_NAME/device/virtfn0"
    exit 1
fi
echo "Discovered VF PCI address: VF0=$U_PLANE_PCI_BUS_ADD (used for both U and C plane)"

# Write PCI address to state file
SRIOV_STATE_FILE=/run/oai-sriov-pci.env
printf 'U_PLANE_PCI_BUS_ADD=%s\nC_PLANE_PCI_BUS_ADD=%s\n' \
    "$U_PLANE_PCI_BUS_ADD" "$U_PLANE_PCI_BUS_ADD" > "$SRIOV_STATE_FILE"
echo "PCI state written to $SRIOV_STATE_FILE"

# Patch dpdk_devices in the gNB conf — same PCI address for both U and C plane (1 VF)
GNB_CONF=/home/ubuntu/Desktop/Test_OAI/etc/oai/gnb.sa.band78.106prb.fhi72.4x2.DDDSU.RAN650.conf
if [ -f "$GNB_CONF" ]; then
    sed -i "s|dpdk_devices = (\"[^\"]*\", \"[^\"]*\")|dpdk_devices = (\"${U_PLANE_PCI_BUS_ADD}\", \"${U_PLANE_PCI_BUS_ADD}\")|" "$GNB_CONF"
    echo "Patched dpdk_devices in $GNB_CONF: (\"$U_PLANE_PCI_BUS_ADD\", \"$U_PLANE_PCI_BUS_ADD\")"
else
    echo "WARNING: gNB conf not found at $GNB_CONF — dpdk_devices not patched"
fi

ip a

ip link set $IF_NAME vf 0 mac $DU_U_PLANE_MAC_ADD vlan $VLAN mtu $MTU
ip link set $IF_NAME vf 0 spoofchk off
#ip link set $IF_NAME vf 1 mac $DU_C_PLANE_MAC_ADD vlan $VLAN mtu $MTU  # only 1 VF
#ip link set $IF_NAME vf 1 spoofchk off
sleep 1

ifconfig $IF_VF0 0
#ifconfig $IF_VF1 0  # only 1 VF
dpdk-devbind.py --unbind $U_PLANE_PCI_BUS_ADD
#dpdk-devbind.py --unbind $C_PLANE_PCI_BUS_ADD  # only 1 VF
modprobe vfio-pci || modprobe vfio_pci
dpdk-devbind.py --bind vfio-pci $U_PLANE_PCI_BUS_ADD
#dpdk-devbind.py --bind vfio-pci $C_PLANE_PCI_BUS_ADD  # only 1 VF
dpdk-devbind.py -s
echo "SR-IOV configured: 1 VF ($IF_VF0, $U_PLANE_PCI_BUS_ADD) bound to vfio-pci (used for both U and C plane)"

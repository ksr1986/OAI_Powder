#!/bin/bash
# Combined setup script: installs/builds OAI gNB, configures PTP, and sets up SR-IOV.
# Run order: packages → GRUB → PTP → DPDK → OAI build → libxran → SR-IOV
# Standalone: does not rely on common.sh
# Must be run as root (sudo).

# ============================================================
# CONFIGURATION — edit these if hardware changes
# ============================================================
BINDIR=/local/repository/bin
ETCDIR=/local/repository/etc
SRCDIR=/local/repository
# Build artifacts go here (outside git repo; survives Emulab re-clone on reboot)
BUILDDIR=/local

OAI_PROJECT_REPO="https://gitlab.eurecom.fr/oai/openairinterface5g"

# Fronthaul VLAN (assigned by Emulab; 168 is the known value for this experiment)
DEFAULT_FH_VLAN=168

# DU MAC address (cudu eth1 / cuduru1ofh interface MAC)
DU_U_PLANE_MAC_ADD=30:3e:a7:1a:9f:49
DU_C_PLANE_MAC_ADD=30:3e:a7:1a:9f:49

# RU MAC address (used in OAI gNB conf ru_addr)
RU_MAC=8c:1f:64:d1:15:0e

# SR-IOV physical function interface (eCPRI DPDK port)
IF_NAME=eno12409
IF_VF0=eno12409v0
IF_VF1=eno12409v1

# PCI bus addresses of the two VFs
U_PLANE_PCI_BUS_ADD=0000:43:09.0
C_PLANE_PCI_BUS_ADD=0000:43:09.1

MTU=8192
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
# SANITY CHECKS
# ============================================================
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

if [ -f /local/oai-setup-complete ]; then
    echo "setup already ran; not running again"
    exit 0
fi

# ============================================================
# 1. APT REPOSITORIES AND PACKAGES
# ============================================================
if ! grep -rq "repos.emulab.net/powder" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    while ! wget -qO - http://repos.emulab.net/emulab.key | apt-key add -; do
        echo "Failed to get emulab key, retrying"
    done
    while ! add-apt-repository -y http://repos.emulab.net/powder/ubuntu/; do
        echo "Failed to add emulab repo, retrying"
    done
    while ! apt-get update; do
        echo "Failed to update, retrying"
    done
else
    echo "Emulab repo already configured, skipping."
fi

REQUIRED_PKGS="cmake ninja-build meson make gcc g++ iperf3 pkg-config libfftw3-dev libmbedtls-dev libsctp-dev libyaml-cpp-dev libgtest-dev linuxptp ppp libxml-simple-perl wget xz-utils libnuma-dev"
MISSING_PKGS=()
for pkg in $REQUIRED_PKGS; do
    dpkg -s "$pkg" &>/dev/null || MISSING_PKGS+=("$pkg")
done
if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    apt update && apt install -y "${MISSING_PKGS[@]}"
else
    echo "All required packages already installed, skipping."
fi

# ============================================================
# 2. GRUB CPU ISOLATION (takes effect after reboot)
# ============================================================
# CPU allocation:
#   0,2,4            -> XRAN DPDK usage
#   6                -> OAI ru_thread
#   8                -> OAI L1_rx_thread
#   10               -> OAI L1_tx_thread
#   1,3,5,7,9,11,13  -> OAI nr-softmodem
#   12               -> ptp4l
#   14-15            -> kernel / kthreads
GRUB_PARAMS="systemd.unified_cgroup_hierarchy=false quiet splash intel_idle.max_cstate=0 mitigations=off usbcore.autosuspend=-1 intel_iommu=on iommu=pt selinux=0 enforcing=0 nmi_watchdog=0 softlockup_panic=0 audit=0 skew_tick=1 isolcpus=managed_irq,domain,0-13 nohz_full=0-13 rcu_nocbs=0-13 kthread_cpus=14-15 rcu_nocb_poll nosoftlockup default_hugepagesz=1GB hugepagesz=1G hugepages=20"
GRUB_FILE=/etc/default/grub
if grep -q "isolcpus" "$GRUB_FILE"; then
    echo "CPU isolation already set in GRUB, skipping."
else
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_PARAMS}\"|" "$GRUB_FILE"
    update-grub
    echo "GRUB updated for CPU isolation. A reboot is required for isolcpus to take effect."
fi

# ============================================================
# 3. PTP SETUP (start early so sync begins during builds)
# ============================================================
PROFILE="G8275-1"
PTPCONF=/etc/linuxptp/ptp4l.conf

IFACE=$($BINDIR/getptpiface)
if [ $? -ne 0 ] || [ -z "$IFACE" ]; then
    echo "WARNING: Cannot determine PTP interface. Skipping PTP setup."
else
    echo "Configuring ptp4l/phc2sys on $IFACE..."

    if [ ! -f "$PTPCONF" ] || ! cmp -s "$PTPCONF" "$ETCDIR/ptp4l/ptp4l-$PROFILE.conf"; then
        cp "$ETCDIR/ptp4l/ptp4l-$PROFILE.conf" "$PTPCONF"
    fi

    if ! cmp -s /lib/systemd/system/phc2sys@.service "$ETCDIR/services/phc2sys@.service"; then
        cp "$ETCDIR/services/phc2sys@.service" /lib/systemd/system/phc2sys@.service
    fi

    ifconfig $IFACE up

    if systemctl -q is-active ntp; then
        echo "Deactivating NTP..."
        systemctl stop ntp.service
        systemctl disable ntp.service
    fi

    if ! systemctl -q is-active ptp4l@$IFACE.service; then
        systemctl start ptp4l@$IFACE.service
        systemctl start phc2sys@$IFACE.service
        systemctl enable ptp4l@$IFACE.service
        systemctl enable phc2sys@$IFACE.service
    fi
    echo "PTP activated on $IFACE."
    echo "  Monitor: sudo journalctl -f -u ptp4l@$IFACE.service"
fi

# ============================================================
# 4. DPDK BUILD
# ============================================================
cd $BUILDDIR
if [ ! -d $BUILDDIR/dpdk-stable-20.11.9 ]; then
    [ ! -f $BUILDDIR/dpdk-20.11.9.tar.xz ] && wget -P $BUILDDIR http://fast.dpdk.org/rel/dpdk-20.11.9.tar.xz
    tar xvf $BUILDDIR/dpdk-20.11.9.tar.xz -C $BUILDDIR
fi

if ! pkg-config --exists libdpdk 2>/dev/null; then
    cd $BUILDDIR/dpdk-stable-20.11.9
    meson build
    ninja -C build
    ninja -C build install
    ldconfig
else
    echo "DPDK already installed, skipping build."
fi

# ============================================================
# 5. OAI AND PHY REPOS + BUILD
# ============================================================
if [ ! -d $BUILDDIR/openairinterface5g ]; then
    git clone $OAI_PROJECT_REPO $BUILDDIR/openairinterface5g
fi
cd $BUILDDIR/openairinterface5g
git checkout tags/v2.4.0

if [ ! -d $BUILDDIR/phy ]; then
    git clone https://gerrit.o-ran-sc.org/r/o-du/phy.git $BUILDDIR/phy
    cd $BUILDDIR/phy
    git checkout oran_f_release_v1.0
    git apply $BUILDDIR/openairinterface5g/cmake_targets/tools/oran_fhi_integration_patches/F/oaioran_F.patch
else
    echo "PHY repo already cloned, skipping."
fi

if [ ! -f $BUILDDIR/phy/fhi_lib/lib/build/libxran.so ]; then
    cd $BUILDDIR/phy/fhi_lib/lib
    make clean
    WIRELESS_SDK_TOOLCHAIN=gcc RTE_SDK=$BUILDDIR/dpdk-stable-20.11.9/ XRAN_DIR=$BUILDDIR/phy/fhi_lib make XRAN_LIB_SO=1
else
    echo "libxran.so already built, skipping."
fi

if [ ! -f $BUILDDIR/phy/fhi_lib/lib/build/libxran.so ]; then
    echo "ERROR: $BUILDDIR/phy/fhi_lib/lib/build/libxran.so not found. Build failed."
    exit 1
fi

if [ ! -f $BUILDDIR/openairinterface5g/cmake_targets/ran_build/build/liboran_fhlib_5g.so ]; then
    cd $BUILDDIR/openairinterface5g/cmake_targets
    export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/usr/local/lib64/pkgconfig/
    ./build_oai -I
    ./build_oai --gNB --ninja -t oran_fhlib_5g --cmake-opt -Dxran_LOCATION=$BUILDDIR/phy/fhi_lib/lib
else
    echo "OAI gNB already built, skipping."
fi

if ! ldd $BUILDDIR/openairinterface5g/cmake_targets/ran_build/build/liboran_fhlib_5g.so; then
    echo "ERROR: liboran_fhlib_5g.so failed ldd check; OAI build may be incomplete."
    exit 1
fi

# ============================================================
# 6. SR-IOV SETUP
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

ip link set $IF_NAME vf 0 mac $DU_U_PLANE_MAC_ADD vlan $VLAN mtu $MTU
ip link set $IF_NAME vf 0 spoofchk off
ip link set $IF_NAME vf 1 mac $DU_C_PLANE_MAC_ADD vlan $VLAN mtu $MTU
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
echo "SR-IOV configured: VFs $IF_VF0 (U-plane) and $IF_VF1 (C-plane) bound to vfio-pci"

# ============================================================
# DONE
# ============================================================
echo "OAI gNB conf: $ETCDIR/oai/gnb.sa.band78.106prb.fhi72.4x2.DDDSU.RAN650.conf"

# Install SR-IOV as a boot-time service so VF bindings survive reboots
cp $ETCDIR/services/oai-sriov.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable oai-sriov.service
echo "oai-sriov.service installed and enabled (runs sriov_conf.sh on every boot)."

touch /local/oai-setup-complete
echo "Setup complete: DPDK, PTP, libxran, OAI gNB, and SR-IOV are ready."
echo "NOTE: Reboot required for CPU isolation (isolcpus) to take effect."


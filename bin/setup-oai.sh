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
DEFAULT_FH_VLAN=193

# DU MAC address (cudu eth1 / cuduru1ofh interface MAC)
DU_U_PLANE_MAC_ADD=30:3e:a7:1a:8e:49
DU_C_PLANE_MAC_ADD=30:3e:a7:1a:8e:48

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
OAI_GNB_CONF=$ETCDIR/oai/gnb.sa.band78.106prb.fhi72.4x2.DDDSU.RAN650.conf

## ============================================================
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
# SANITY CHECKS
# ============================================================
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

#if [ -f /home/ubuntu/Desktop/Test_OAI/.oai-setup-complete ]; then
#    echo "setup already ran; not running again"
#    exit 0
#fi

if [ -f "$OAI_GNB_CONF" ]; then
    sed -i "s|^\([[:space:]]*GNB_IPV4_ADDRESS_FOR_NG_AMF[[:space:]]*=[[:space:]]*\)\"[0-9.]*\";|\1\"${OAI_GNB_IP}\";|" "$OAI_GNB_CONF"
    sed -i "s|^\([[:space:]]*GNB_IPV4_ADDRESS_FOR_NGU[[:space:]]*=[[:space:]]*\)\"[0-9.]*\";|\1\"${OAI_GNB_IP}\";|" "$OAI_GNB_CONF"
else
    echo "WARNING: OAI gNB conf not found at $OAI_GNB_CONF; skipping gNB IP update."
fi

# ============================================================
# 1. APT PACKAGES
# ============================================================
apt-get update

REQUIRED_PKGS="cmake ninja-build meson make gcc g++ iperf3 pkg-config libfftw3-dev libmbedtls-dev libsctp-dev libyaml-cpp-dev libgtest-dev linuxptp ppp libxml-simple-perl wget xz-utils libnuma-dev tuned tuna linux-image-realtime linux-headers-realtime linux-tools-realtime"
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
# 2. REALTIME KERNEL SELECTION
# ============================================================
# Switch default boot entry to the realtime kernel.
echo "Setting realtime kernel as default boot entry..."
sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
RT_ENTRY=$(egrep "^[[:space:]]?(submenu|menuentry)" /boot/grub/grub.cfg \
    | cut -d "'" -f2 | grep -i realtime | head -1)
if [ -n "$RT_ENTRY" ]; then
    grub-set-default "Advanced options for Ubuntu>$RT_ENTRY"
    echo "Realtime kernel set: $RT_ENTRY"
else
    echo "WARNING: Realtime kernel entry not found in grub.cfg. Install linux-image-realtime and rerun."
fi

# ============================================================
# 3. GRUB KERNEL PARAMETERS
# ============================================================
# CPU allocation:
#   0-12  -> OAI + PTP (isolated)
#   13-15 -> kernel / kthreads (housekeeping)
GRUB_PARAMS='intel_idle.max_cstate=0 mitigations=off usbcore.autosuspend=-1 intel_iommu=on iommu=pt selinux=0 enforcing=0 nmi_watchdog=0 softlockup_panic=0 nosoftlockup audit=0 nohz_full=0-12 rcu_nocbs=0-12 rcu_nocb_poll default_hugepagesz=1GB hugepagesz=1G hugepages=20 preempt=full skew_tick=1 tsc=reliable isolcpus=managed_irq,domain,0-12 intel_pstate=disable'
GRUB_FILE=/etc/default/grub
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_PARAMS}\"|" "$GRUB_FILE"
# Drop a grub.d snippet to add preempt=full (survives future grub updates)
mkdir -p /etc/default/grub.d
echo 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT preempt=full"' \
    > /etc/default/grub.d/99-lowlatency.cfg
update-grub
echo "GRUB updated. A reboot is required for kernel parameters to take effect."

# ============================================================
# 4. TUNED REALTIME PROFILE
# ============================================================
echo "Installing tuned realtime-oai profile..."
mkdir -p /etc/tuned/realtime-oai
cp "$ETCDIR/tuned/realtime-oai/tuned.conf" /etc/tuned/realtime-oai/tuned.conf
cp "$ETCDIR/tuned/realtime-variables.conf" /etc/tuned/realtime-variables.conf
tuned-adm profile realtime-oai
systemctl enable tuned
systemctl start tuned
echo "tuned realtime-oai profile active."

# ============================================================
# 5. PTP SETUP (start early so sync begins during builds)
# ============================================================
IFACE=$FH_PTP_IFACE
if ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "WARNING: PTP interface $IFACE does not exist. Skipping PTP setup."
else
    echo "Configuring ptp4l/phc2sys on $IFACE..."

    # Install ptp.conf
    cp "$ETCDIR/ptp4l/ptp.conf" /etc/ptp.conf

    # Install standalone ptp4l and phc2sys services
    cp "$ETCDIR/services/ptp4l.service"  /etc/systemd/system/ptp4l.service
    cp "$ETCDIR/services/phc2sys@.service" /lib/systemd/system/phc2sys@.service

    ip link set "$IFACE" up

    # Disable NTP if running
    if systemctl -q is-active ntp 2>/dev/null; then
        echo "Deactivating NTP..."
        systemctl stop ntp.service
        systemctl disable ntp.service
    fi

    systemctl daemon-reload
    systemctl enable ptp4l.service
    systemctl start ptp4l.service
    systemctl enable phc2sys@$IFACE.service
    systemctl start phc2sys@$IFACE.service
    echo "PTP activated. Monitor: sudo journalctl -f -u ptp4l.service"
fi

# ============================================================
# 6. DPDK BUILD
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
# 7. OAI AND PHY REPOS + BUILD
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
# 8. SR-IOV SETUP
# ============================================================
echo "Running SR-IOV setup via sriov_conf.sh..."
bash "$BINDIR/sriov_conf.sh"
if [ $? -ne 0 ]; then
    echo "ERROR: sriov_conf.sh failed. Aborting."
    exit 1
fi

# Read the VF PCI addresses discovered by sriov_conf.sh
SRIOV_STATE_FILE=/run/oai-sriov-pci.env
if [ -f "$SRIOV_STATE_FILE" ]; then
    source "$SRIOV_STATE_FILE"
    echo "Loaded VF PCI addresses: U-plane=$U_PLANE_PCI_BUS_ADD  C-plane=$C_PLANE_PCI_BUS_ADD"
else
    echo "ERROR: $SRIOV_STATE_FILE not found after sriov_conf.sh. Cannot patch gNB conf."
    exit 1
fi

# Patch dpdk_devices in OAI gNB conf with the real VF PCI addresses
echo "Patching dpdk_devices in $OAI_GNB_CONF..."
sed -i "s|dpdk_devices = (\"[^\"]*\", \"[^\"]*\")|dpdk_devices = (\"${U_PLANE_PCI_BUS_ADD}\", \"${C_PLANE_PCI_BUS_ADD}\")|" "$OAI_GNB_CONF"
echo "dpdk_devices patched: (\"$U_PLANE_PCI_BUS_ADD\", \"$C_PLANE_PCI_BUS_ADD\")"

# Expose VLAN value for step 7 (keep in sync with sriov_conf.sh)
VLAN=193

# ============================================================
# 9. INSTALL SYSTEMD SERVICES
# ============================================================
echo "Installing systemd services..."
cp $ETCDIR/services/phc2sys@.service /lib/systemd/system/phc2sys@.service
cp $ETCDIR/services/oai-sriov.service /etc/systemd/system/oai-sriov.service
cp $ETCDIR/services/oai-gnb.service /etc/systemd/system/oai-gnb.service
systemctl daemon-reload
systemctl enable oai-sriov.service
echo "oai-sriov.service installed and enabled (runs sriov_conf.sh on every boot)."
echo "oai-gnb.service installed (start manually: systemctl start oai-gnb)."

touch /home/ubuntu/Desktop/Test_OAI/.oai-setup-complete
echo "Setup complete: DPDK, PTP, libxran, OAI gNB, and SR-IOV are ready."
echo "NOTE: Reboot required for CPU isolation (isolcpus) to take effect."

#!/bin/bash
#COMMIT_HASH=$1
BINDIR=/local/repository/bin
ETCDIR=/local/repository/etc
SRCDIR=/local/repository

# Source common.sh if available for shared variables/functions; otherwise use defaults above
if [ -f "$BINDIR/common.sh" ]; then
    source "$BINDIR/common.sh"
fi

if [ -f $SRCDIR/oai-setup-complete ]; then
  echo "setup already ran; not running again"
  exit 0

fi

#Bring down the interfaces
#sudo ifconfig eno12408 down
#sudo ifconfig eno12409 down

 # Get the emulab repo -- what are these repos for? Do we need them for OAI?
if ! grep -rq "repos.emulab.net/powder" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
  while ! wget -qO - http://repos.emulab.net/emulab.key | sudo apt-key add -
  do
      echo Failed to get emulab key, retrying
  done

  while ! sudo add-apt-repository -y http://repos.emulab.net/powder/ubuntu/
  do
      echo Failed to get johnsond ppa, retrying
  done

  while ! sudo apt-get update
  do
      echo Failed to update, retrying
  done
else
  echo "Emulab repo already configured, skipping."
fi

#Do we need UHD Drives?
 # sudo apt-get install -y libuhd-dev uhd-host
 # sudo uhd_images_downloader -tb2

 #Install Packages needed for OAI gNB

REQUIRED_PKGS="cmake ninja-build meson make gcc g++ iperf3 pkg-config libfftw3-dev libmbedtls-dev libsctp-dev libyaml-cpp-dev libgtest-dev linuxptp ppp"
MISSING_PKGS=()
for pkg in $REQUIRED_PKGS; do
    dpkg -s "$pkg" &>/dev/null || MISSING_PKGS+=("$pkg")
done
if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    sudo apt update && sudo apt install -y "${MISSING_PKGS[@]}"
else
    echo "All required packages already installed, skipping."
fi


# Configure CPU isolation via GRUB for real-time OAI/XRAN performance on R760 (cudu node).
# CPU allocation:
#   0,2,4       -> XRAN DPDK usage
#   6           -> OAI ru_thread
#   8           -> OAI L1_rx_thread
#   10          -> OAI L1_tx_thread
#   1,3,5,7,9,11,13 -> OAI nr-softmodem
#   12          -> ptp4l
#   14-15       -> kernel / kthreads
# NOTE: These changes take effect after the next reboot.
GRUB_PARAMS="systemd.unified_cgroup_hierarchy=false quiet splash intel_idle.max_cstate=0 mitigations=off usbcore.autosuspend=-1 intel_iommu=on iommu=pt selinux=0 enforcing=0 nmi_watchdog=0 softlockup_panic=0 audit=0 skew_tick=1 isolcpus=managed_irq,domain,0-13 nohz_full=0-13 rcu_nocbs=0-13 kthread_cpus=14-15 rcu_nocb_poll nosoftlockup default_hugepagesz=1GB hugepagesz=1G hugepages=20"

GRUB_FILE=/etc/default/grub
if grep -q "isolcpus" "$GRUB_FILE"; then
  echo "CPU isolation already set in GRUB, skipping."
else
  sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_PARAMS}\"|" "$GRUB_FILE"
  sudo update-grub
  echo "GRUB updated for CPU isolation. A reboot is required for isolcpus to take effect."
fi


#Setup DPDK:

cd $SRCDIR
# Install DPDK build deps if not already present
DPDK_BUILD_PKGS="wget xz-utils libnuma-dev"
MISSING_DPDK_PKGS=()
for pkg in $DPDK_BUILD_PKGS; do
    dpkg -s "$pkg" &>/dev/null || MISSING_DPDK_PKGS+=("$pkg")
done
[ ${#MISSING_DPDK_PKGS[@]} -gt 0 ] && sudo apt install -y "${MISSING_DPDK_PKGS[@]}"

# Download and extract DPDK if not already present
if [ ! -d $SRCDIR/dpdk-stable-20.11.9 ]; then
    [ ! -f $SRCDIR/dpdk-20.11.9.tar.xz ] && wget http://fast.dpdk.org/rel/dpdk-20.11.9.tar.xz
    tar xvf dpdk-20.11.9.tar.xz
fi

# Build and install DPDK if not already installed
if ! pkg-config --exists libdpdk 2>/dev/null; then
    cd $SRCDIR/dpdk-stable-20.11.9
    meson build
    ninja -C build
    sudo ninja -C build install
    sudo ldconfig
else
    echo "DPDK already installed, skipping build."
fi


if [ ! -d $SRCDIR/openairinterface5g ]; then
    git clone $OAI_PROJECT_REPO $SRCDIR/openairinterface5g
fi
cd $SRCDIR/openairinterface5g
git checkout tags/v2.4.0

if [ ! -d $SRCDIR/phy ]; then
    git clone https://gerrit.o-ran-sc.org/r/o-du/phy.git $SRCDIR/phy
    cd $SRCDIR/phy
    git checkout oran_f_release_v1.0
    git apply $SRCDIR/openairinterface5g/cmake_targets/tools/oran_fhi_integration_patches/F/oaioran_F.patch
else
    echo "PHY repo already cloned, skipping."
fi

if [ ! -f $SRCDIR/phy/fhi_lib/lib/build/libxran.so ]; then
    cd $SRCDIR/phy/fhi_lib/lib
    make clean
    WIRELESS_SDK_TOOLCHAIN=gcc RTE_SDK=$SRCDIR/dpdk-stable-20.11.9/ XRAN_DIR=$SRCDIR/phy/fhi_lib make XRAN_LIB_SO=1
else
    echo "libxran.so already built, skipping."
fi

if [ ! -f $SRCDIR/phy/fhi_lib/lib/build/libxran.so ]; then
    echo "ERROR: The shared library object $SRCDIR/phy/fhi_lib/lib/build/libxran.so must be present before proceeding."
    exit 1
fi


#Build OAI gNB
if [ ! -f $SRCDIR/openairinterface5g/cmake_targets/ran_build/build/liboran_fhlib_5g.so ]; then
    cd $SRCDIR/openairinterface5g/cmake_targets
    export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/usr/local/lib64/pkgconfig/
    ./build_oai -I 
    ./build_oai --gNB --ninja -t oran_fhlib_5g --cmake-opt -Dxran_LOCATION=$SRCDIR/phy/fhi_lib/lib
else
    echo "OAI gNB already built, skipping."
fi

#Check to run if things are installed properly
if ! ldd $SRCDIR/openairinterface5g/cmake_targets/ran_build/build/liboran_fhlib_5g.so; then
    echo "ERROR: liboran_fhlib_5g.so failed ldd check; OAI build may be incomplete."
    exit 1
fi

# Configure SR-IOV and bind VFs to vfio-pci for DPDK
sudo $BINDIR/sriov_conf.sh
echo "SR-IOV configured: VFs eno12408v0 (U-plane) and eno12408v1 (C-plane) bound to vfio-pci"

# OAI gNB conf file is already at $CFGDIR/oai/ (/local/repository/etc/oai/)
echo "OAI gNB conf: $ETCDIR/oai/gnb.sa.band78.106prb.fhi72.4x2.DDDSU.RAN650.conf"

touch $ETCDIR/oai-setup-complete
echo "OAI gNB setup complete: DPDK, libxran, OAI gNB, and SR-IOV fronthaul interfaces are ready"

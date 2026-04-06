#COMMIT_HASH=$1
BINDIR=`dirname $0`
ETCDIR=/local/repository/etc
source $BINDIR/common.sh

if [ -f $SRCDIR/oai-setup-complete ]; then
  echo "setup already ran; not running again"
  exit 0

fi

#Bring down the interfaces
sudo ifconfig eno12408 down
sudo ifconfig eno12419 down

 # Get the emulab repo -- what are these repos for? Do we need them for OAI?
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

#Do we need UHD Drives?
 # sudo apt-get install -y libuhd-dev uhd-host
 # sudo uhd_images_downloader -tb2

 #Install Packages needed for OAI gNB

sudo apt update && sudo apt install -y \
  cmake \
  ninja-build \
  meson \
  make \
  gcc \
  g++ \
  iperf3 \
  pkg-config \
  libfftw3-dev \
  libmbedtls-dev \
  libsctp-dev \
  libyaml-cpp-dev \
  libgtest-dev \
  ppp


#Setup DPDK:

cd $SRCDIR
sudo apt install wget xz-utils libnuma-dev
wget http://fast.dpdk.org/rel/dpdk-20.11.9.tar.xz
tar xvf dpdk-20.11.9.tar.xz && cd dpdk-stable-20.11.9
meson build
ninja -C build
sudo ninja -C build install


git clone $OAI_PROJECT_REPO
cd openairinterface5g
git checkout tags/v2.4.0

cd $SRCDIR
git clone https://gerrit.o-ran-sc.org/r/o-du/phy.git 
cd phy
git checkout oran_f_release_v1.0
git apply $SRCDIR/openairinterface5g/cmake_targets/tools/oran_fhi_integration_patches/F/oaioran_F.patch

cd $SRCDIR/phy/fhi_lib/lib
make clean
WIRELESS_SDK_TOOLCHAIN=gcc RTE_SDK=$SRCDIR/dpdk-stable-20.11.9/ XRAN_DIR=$SRCDIR/phy/fhi_lib make XRAN_LIB_SO=1

if [ ! -f $SRCDIR/phy/fhi_lib/lib/build/libxran.so ]; then
    echo "ERROR: The shared library object $SRCDIR/phy/fhi_lib/lib/build/libxran.so must be present before proceeding."
    exit 1
fi


#Build OAI gNB
cd $SRCDIR/openairinterface5g/cmake_targets
export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/usr/local/lib64/pkgconfig/
./build_oai -I 
./build_oai --gNB --ninja -t oran_fhlib_5g --cmake-opt -Dxran_LOCATION=$SRCDIR/phy/fhi_lib/lib

#Check to run if things are installed properly
if ! ldd $SRCDIR/openairinterface5g/cmake_targets/ran_build/build/liboran_fhlib_5g.so; then
    echo "ERROR: liboran_fhlib_5g.so failed ldd check; OAI build may be incomplete."
    exit 1
fi

# Configure SR-IOV and bind VFs to vfio-pci for DPDK
sudo $BINDIR/sriov_conf.sh
echo "SR-IOV configured: VFs eno12408v0 (U-plane) and eno12408v1 (C-plane) bound to vfio-pci"

# Copy OAI gNB conf file to runtime location
sudo mkdir -p /var/tmp/etc/oai
sudo cp $CFGDIR/oai/gnb.sa.band78.106prb.fhi72.4x2.DDDSU.RAN650.conf /var/tmp/etc/oai/
echo "OAI gNB conf file deployed to /var/tmp/etc/oai/"

touch $SRCDIR/oai-setup-complete
echo "OAI gNB setup complete: DPDK, libxran, OAI gNB, and SR-IOV fronthaul interfaces are ready"

set -ex
# =============================================================================
# SRSRAN DEPLOYMENT DISABLED
# This script has been disabled in preparation for OAI deployment.
# All srsRAN-specific deployment code is preserved below for reference.
# TODO: Replace with OAI gNB deployment script (deploy-oai.sh).
# =============================================================================
exit 0

COMMIT_HASH=$1
USE_DPDK=${2:-""}
BINDIR=`dirname $0`
ETCDIR=/local/repository/etc
source $BINDIR/common.sh

if [ -z $COMMIT_HASH ]; then
  echo "Usage: $0 <commit_hash> [dpdk]"
  exit 1
fi
if [ "$USE_DPDK" != "" ] && [ "$USE_DPDK" != "dpdk" ]; then
  echo "Usage: $0 <commit_hash> [dpdk]"
  exit 1
fi

if [ -f $SRCDIR/srs-setup-complete ]; then
  echo "setup already ran; not running again"
  if [ "$USE_DPDK" = "dpdk" ]; then
    echo "need to setup interfaces again..."
    sudo ifconfig eno12409 down
    sudo ifconfig eno12419 down
    sudo dpdk-devbind.py --bind vfio-pci 0000:43:00.1
    sudo dpdk-devbind.py --bind vfio-pci 0000:43:00.2
    sudo dpdk-devbind.py -s
  fi
  exit 0
fi

# if not using dpdk, install uhd
if [ "$USE_DPDK" = "dpdk" ]; then
  #TODO: don't hardcode iface details; using pc01 details for now
  
  # bring down the interfaces and bind them to vfio-pci
  sudo ifconfig eno12409 down
  sudo ifconfig eno12419 down
  sudo dpdk-devbind.py --bind vfio-pci 0000:43:00.1
  sudo dpdk-devbind.py --bind vfio-pci 0000:43:00.2
  sudo dpdk-devbind.py -s

  # Not sure why srsRAN instructions want this since default hugepages mount is
  # /dev/hugepages but this is what the srsRAN instructions say to do, so
  # following them for now
  sudo mkdir -p /mnt/huge
  sudo mount -t hugetlbfs nodev /mnt/huge
  
  # persist hugepage mount
  echo "nodev /mnt/huge hugetlbfs pagesize=1G 0 0" | sudo tee -a /etc/fstab
else
  # Get the emulab repo
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

  sudo apt-get install -y libuhd-dev uhd-host
  sudo uhd_images_downloader -tb2
fi

sudo apt update && sudo apt install -y \
  cmake \
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

cd $SRCDIR
git clone $SRS_PROJECT_REPO
cd srsRAN_Project
git checkout $COMMIT_HASH
mkdir build
cd build
if [ "$USE_DPDK" = "dpdk" ]; then
  echo "Building with DPDK"
  cmake -DENABLE_DPDK=True -DENABLE_UHD=False -DASSERT_LEVEL=MINIMAL ..
else
  echo "Building without DPDK"
  cmake ..
fi
make -j $(nproc)

echo configuring nodeb...
mkdir -p $SRCDIR/etc/srsran
cp -r $ETCDIR/srsran/* $SRCDIR/etc/srsran/
LANIF=`ip r | awk '/192\.168\.1\.0/{print $3}'`
if [ ! -z $LANIF ]; then
  LANIP=`ip r | awk '/192\.168\.1\.0/{print $NF}'`
  echo LAN IFACE is $LANIF IP is $LANIP.. updating nodeb config
  find $SRCDIR/etc/srsran/ -type f -exec sed -i "s/LANIP/$LANIP/" {} \;
  IPLAST=`echo $LANIP | awk -F. '{print $NF}'`
  find $SRCDIR/etc/srsran/ -type f -exec sed -i "s/GNBID/$IPLAST/" {} \;
else
  echo No LAN IFACE.. not updating nodeb config
fi
echo configuring nodeb... done.

sudo cp $SERVICESDIR/srs-gnb.service /etc/systemd/system/srs-gnb.service
sudo cp $SERVICESDIR/srs-gnb-metrics.service /etc/systemd/system/srs-gnb-metrics.service
sudo systemctl daemon-reload
sudo cp $BINDIR/metrics-receiver.py $SRCDIR

touch $SRCDIR/srs-setup-complete

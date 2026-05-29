#!/bin/bash
set -ex

# ============================================================
# CONFIGURATION
# ============================================================
BINDIR=/local/repository/bin
SRCDIR=/local/repository
ETCDIR=/local/repository/etc

# Enable IP forwarding and NAT so UEs (10.45.0.0/16) can reach the internet
# via the CN node. MASQUERADE rewrites UE source IPs on packets leaving
# the node (excluding traffic going back into the ogstun tunnel itself).
sudo sysctl -w net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE

if [ -f $SRCDIR/open5gs-setup-complete ]; then
    echo "setup already ran; not running again"
    exit 0
fi

sudo apt update
sudo apt install -y software-properties-common gnupg curl
sudo add-apt-repository -y ppa:open5gs/latest
sudo add-apt-repository -y ppa:wireshark-dev/stable
echo "wireshark-common wireshark-common/install-setuid boolean false" | sudo debconf-set-selections
sudo apt update

# Install libssl1.1 from Ubuntu 20.04 (focal) — required by MongoDB 4.2 on Ubuntu 22.04
echo "deb http://security.ubuntu.com/ubuntu focal-security main" | \
    sudo tee /etc/apt/sources.list.d/focal-security.list
sudo apt update
sudo apt install -y libssl1.1
sudo rm /etc/apt/sources.list.d/focal-security.list

# Install MongoDB 4.2 (compatible with older CPUs without AVX, e.g. Xeon E5xxx)
curl -fsSL https://www.mongodb.org/static/pgp/server-4.2.asc | sudo apt-key add -
echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu bionic/mongodb-org/4.2 multiverse" | \
    sudo tee /etc/apt/sources.list.d/mongodb-org-4.2.list
sudo apt update
sudo apt install -y mongodb-org

sudo systemctl start mongod
sudo systemctl enable mongod

sudo apt install -y \
    nginx \
    tshark \
    wireshark
sudo apt install -y open5gs
sudo cp $ETCDIR/open5gs/* /etc/open5gs/

# 5G SA core services
sudo systemctl restart open5gs-nrfd
sudo systemctl restart open5gs-ausfd
sudo systemctl restart open5gs-udmd
sudo systemctl restart open5gs-udrd
sudo systemctl restart open5gs-pcfd
sudo systemctl restart open5gs-nssfd
sudo systemctl restart open5gs-bsfd
sudo systemctl restart open5gs-amfd
sudo systemctl restart open5gs-smfd
sudo systemctl restart open5gs-upfd
sudo systemctl restart open5gs-scp 2>/dev/null || true

# 4G/EPC services — masked in 5G-SA mode, skip
# sudo systemctl restart open5gs-mmed
# sudo systemctl restart open5gs-sgwcd
# sudo systemctl restart open5gs-sgwud
# sudo systemctl restart open5gs-hssd
# sudo systemctl restart open5gs-pcrfd

cd $SRCDIR
wget https://raw.githubusercontent.com/open5gs/open5gs/main/misc/db/open5gs-dbctl
chmod +x open5gs-dbctl
# open5gs-dbctl uses 'mongosh' by default; patch it to use legacy 'mongo' shell
# which ships with MongoDB 4.2
sed -i 's/mongosh/mongo/g' open5gs-dbctl
./open5gs-dbctl add_ue_with_slice 999990000000103 00112233445566778899aabbccddeeff 0ed47545168eafe2c39c075829a7b61f internet 1 000001 # IMSI,K,OPC
./open5gs-dbctl type 999990000000103 1  # APN type IPV4
./open5gs-dbctl static_ip 999990000000103 10.45.0.103
./open5gs-dbctl add_ue_with_slice 999990000000105 00112233445566778899aabbccddeeff 0ed47545168eafe2c39c075829a7b61f internet 1 000001 # IMSI,K,OPC
./open5gs-dbctl type 999990000000105 1  # APN type IPV4
./open5gs-dbctl static_ip 999990000000105 10.45.0.105
./open5gs-dbctl add_ue_with_slice 999990000000128 00112233445566778899aabbccddeeff 0ed47545168eafe2c39c075829a7b61f internet 1 000001 # IMSI,K,OPC
./open5gs-dbctl type 999990000000128 1  # APN type IPV4
./open5gs-dbctl static_ip 999990000000128 10.45.0.128
touch $SRCDIR/open5gs-setup-complete

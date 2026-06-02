#!/bin/bash
#
# setup-ric.sh — runs on the cn5g node at experiment startup.
#
# Installs a single-node Kubernetes cluster (via Kubespray) and deploys the
# OSC near-RT RIC (j-release, E2AP v2) on top of it.
#
# Open5GS is installed separately by deploy-open5gs.sh which also fires at
# startup; these two scripts do not interfere.
#
# After this script completes, the cn5g node exposes:
#   - OSC near-RT RIC E2 termination reachable at its ClusterIP (10.96.x.x)
#     or via NodePort on 192.168.1.1 (OAI_shared_VLAN IP).
#   - Kubernetes pod subnet 10.233.0.0/16 and service subnet 10.96.0.0/12
#     are routable from cudu via 192.168.1.1 (IP forwarding + masquerade below).
#
# On cudu, run /local/repository/bin/get-ric-env.sh to discover the live
# E2 term ClusterIP and patch the OAI gNB configuration before starting the gNB.
#

set -x

BINDIR=/local/repository/bin

if [ -f /local/setup/setup-ric-done ]; then
    echo "setup-ric.sh already ran; skipping."
    exit 0
fi

# -----------------------------------------------------------------------
# Step 1: Install Kubernetes (single-node, cn5g only) via Kubespray.
# -----------------------------------------------------------------------
bash "$BINDIR/setup-kubespray-ric.sh"
if [ $? -ne 0 ]; then
    echo "ERROR: setup-kubespray-ric.sh failed. Aborting."
    exit 1
fi

# -----------------------------------------------------------------------
# Step 2: Post-Kubernetes extras (admin token, local registry, etc.)
# -----------------------------------------------------------------------
bash "$BINDIR/setup-kubernetes-extra-ric.sh"
if [ $? -ne 0 ]; then
    echo "ERROR: setup-kubernetes-extra-ric.sh failed. Aborting."
    exit 1
fi

# -----------------------------------------------------------------------
# Step 3: Deploy OSC near-RT RIC (j-release).
# -----------------------------------------------------------------------
bash "$BINDIR/setup-oran-ric.sh"
if [ $? -ne 0 ]; then
    echo "ERROR: setup-oran-ric.sh failed. Aborting."
    exit 1
fi

# -----------------------------------------------------------------------
# Step 4: Enable IP forwarding and masquerade so that cudu (192.168.1.2)
# can reach the Kubernetes pod subnet (10.233.0.0/16) and service subnet
# (10.96.0.0/12) routed through cn5g (192.168.1.1) on OAI_shared_VLAN.
#
# cudu must also add static routes (done in setup-oai.sh on cudu):
#   ip route add 10.233.0.0/16 via 192.168.1.1
#   ip route add 10.96.0.0/12  via 192.168.1.1
# -----------------------------------------------------------------------
sudo sysctl -w net.ipv4.ip_forward=1
# Persist IP forwarding across reboots.
grep -q "net.ipv4.ip_forward" /etc/sysctl.d/99-ric-forward.conf 2>/dev/null || \
    echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-ric-forward.conf

# Masquerade traffic from cudu destined for the pod/service subnets.
sudo iptables -t nat -C POSTROUTING -s 192.168.1.0/24 -d 10.233.0.0/16 -j MASQUERADE 2>/dev/null || \
    sudo iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -d 10.233.0.0/16 -j MASQUERADE
sudo iptables -t nat -C POSTROUTING -s 192.168.1.0/24 -d 10.96.0.0/12  -j MASQUERADE 2>/dev/null || \
    sudo iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -d 10.96.0.0/12  -j MASQUERADE

# Persist iptables rules.
sudo apt-get install -y iptables-persistent 2>/dev/null || true
sudo netfilter-persistent save 2>/dev/null || sudo iptables-save | sudo tee /etc/iptables/rules.v4

touch /local/setup/setup-ric-done
echo "setup-ric.sh complete. OSC near-RT RIC (j-release) is deployed on cn5g."
echo ""
echo "=============================================================="
echo "Next steps: run the following scripts ON THE cudu (DU) NODE in"
echo "this exact order before starting the OAI gNB:"
echo "  1. /local/repository/bin/sriov_conf.sh"
echo "  2. /local/repository/bin/setup-oai.sh"
echo "  3. /local/repository/bin/get-ric-env.sh"
echo "=============================================================="

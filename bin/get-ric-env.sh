#!/bin/bash
#
# get-ric-env.sh — run on cudu (OAI DU node).
#
# Discovers the live OSC near-RT RIC E2 termination ClusterIP from cn5g,
# then patches the OAI gNB configuration file so the gNB E2 agent points
# to the correct IP before you start nr-softmodem.
#
# Usage (on cudu):
#   source /local/repository/bin/get-ric-env.sh
#   # Then start OAI gNB — the E2 agent will connect to $E2TERM_SCTP.
#
# Alternatively, run as a standalone script; it will patch the gNB conf
# in-place so the E2 agent section is pre-configured.
#

set -e

RIC_NODE="cn5g"
GNB_CONF="/local/repository/etc/oai/gnb.sa.band78.106prb.fhi72.4x2.DDDSU.RAN650.conf"

echo "==> Querying E2 termination ClusterIP from $RIC_NODE ..."

# SSH to cn5g and retrieve the ClusterIP of the E2 term SCTP service.
# The OSC RIC ric-dep installs this service in the 'ricplt' namespace.
E2TERM_SCTP=$(ssh -o StrictHostKeyChecking=no "$RIC_NODE" \
    "kubectl get service -n ricplt service-ricplt-e2term-sctp-alpha \
     -o jsonpath='{.spec.clusterIP}'" 2>/dev/null)

if [ -z "$E2TERM_SCTP" ]; then
    echo "ERROR: Could not retrieve E2 term ClusterIP from $RIC_NODE."
    echo "  Make sure setup-ric.sh has finished on cn5g (check /local/setup/setup-ric-done)."
    echo "  You can also run: ssh $RIC_NODE kubectl get pods -n ricplt"
    exit 1
fi

export E2TERM_SCTP
echo "==> E2 term SCTP ClusterIP: $E2TERM_SCTP"

# Ensure cudu can reach the Kubernetes service subnet via cn5g.
echo "==> Verifying routes to Kubernetes subnets via cn5g (192.168.1.1) ..."
ip route show | grep -q "10.233.0.0/16" || \
    sudo ip route add 10.233.0.0/16 via 192.168.1.1 dev eth0
ip route show | grep -q "10.96.0.0/12" || \
    sudo ip route add 10.96.0.0/12  via 192.168.1.1 dev eth0
echo "==> Routes OK."

# Patch the OAI gNB conf with the actual E2 term IP.
if [ -f "$GNB_CONF" ]; then
    sudo sed -i \
        "s|near_ric_ip_addr[[:space:]]*=.*|near_ric_ip_addr = \"$E2TERM_SCTP\";  # patched by get-ric-env.sh|" \
        "$GNB_CONF"
    echo "==> Patched $GNB_CONF with E2TERM_SCTP=$E2TERM_SCTP"
else
    echo "WARNING: gNB conf not found at $GNB_CONF — set near_ric_ip_addr manually."
fi

echo ""
echo "==> RIC environment ready.  To start the OAI gNB with E2 support:"
echo "    sudo /local/openairinterface5g/cmake_targets/ran_build/build/nr-softmodem \\"
echo "        -O $GNB_CONF"
echo ""
echo "    E2TERM_SCTP=$E2TERM_SCTP (port 36421)"

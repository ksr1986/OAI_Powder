#!/bin/bash
#
# get-ric-env.sh — run on cudu (OAI DU node).
#
#   OAI's E2 agent dials the RIC on the standard E2AP SCTP port 36421, so the
#   e2term service NodePort must be pinned to 36421 (done in setup-ric.sh).
#
# Usage (on cudu):
#   sudo /local/repository/bin/get-ric-env.sh
#   # Then start the OAI gNB.
#

set -e

RIC_NODE="cn5g"
# cn5g's IP on the OAI-shared-vlan. The gNB reaches the E2 term NodePort here.
RIC_NODE_IP="192.168.1.1"
# Standard E2AP SCTP port; must match the e2term service nodePort on cn5g.
E2_PORT=36421
GNB_CONF="/local/repository/etc/oai/gnb.sa.band78.106prb.fhi72.4x2.DDDSU.RAN650.conf"

echo "==> Verifying E2 term NodePort on $RIC_NODE ..."
NODEPORT=$(ssh -o StrictHostKeyChecking=no "$RIC_NODE" \
    "kubectl get service -n ricplt service-ricplt-e2term-sctp-alpha \
     -o jsonpath='{.spec.ports[0].nodePort}'" 2>/dev/null)

if [ -z "$NODEPORT" ]; then
    echo "ERROR: Could not query the E2 term service from $RIC_NODE."
    echo "  Make sure setup-ric.sh has finished on cn5g (check /local/setup/setup-ric-done)."
    echo "  Also: ssh $RIC_NODE kubectl get pods -n ricplt"
    exit 1
fi

if [ "$NODEPORT" != "$E2_PORT" ]; then
    echo "WARNING: e2term NodePort is $NODEPORT, but OAI dials $E2_PORT."
    echo "  Pin it on $RIC_NODE with:"
    echo "    kubectl -n ricplt patch svc service-ricplt-e2term-sctp-alpha --type merge \\"
    echo "      -p '{\"spec\":{\"ports\":[{\"name\":\"sctp-alpha\",\"protocol\":\"SCTP\",\"port\":36422,\"targetPort\":36422,\"nodePort\":$E2_PORT}]}}'"
fi
echo "==> E2 term reachable at ${RIC_NODE_IP}:${E2_PORT} (current NodePort: $NODEPORT)"

# Patch the OAI gNB conf so the E2 agent points at cn5g's node IP (NOT the
# ClusterIP, which is unreachable from this external host).
if [ -f "$GNB_CONF" ]; then
    sudo sed -i \
        "s|near_ric_ip_addr[[:space:]]*=.*|near_ric_ip_addr = \"$RIC_NODE_IP\";  # patched by get-ric-env.sh|" \
        "$GNB_CONF"
    echo "==> Patched $GNB_CONF: near_ric_ip_addr = $RIC_NODE_IP"
else
    echo "WARNING: gNB conf not found at $GNB_CONF — set near_ric_ip_addr manually."
fi

echo ""
echo "==> RIC environment ready.  To start the OAI gNB with E2 support:"
echo "    sudo /local/openairinterface5g/cmake_targets/ran_build/build/nr-softmodem \\"
echo "        -O $GNB_CONF"
echo ""
echo "    E2 term: ${RIC_NODE_IP}:${E2_PORT} (SCTP)"

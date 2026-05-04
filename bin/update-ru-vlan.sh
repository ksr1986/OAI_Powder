#!/bin/bash
# Read the testbed-allocated VLAN ID for the DU-RU fronthaul link (duru1t) from
# the experiment manifest, update ru_config.cfg with that VLAN ID (in hex),
# and push the config to the RU.
#
# Method 1: geni-get manifest (works on any Emulab/POWDER node, any machine)
# Method 2: detect VLAN sub-interface on the fronthaul parent interface
# Fallback:  DEFAULT_FH_VLAN from common.sh (same default used by sriov_conf.sh on the DU)

BINDIR=$(dirname "$0")
source "$BINDIR/common.sh"

RU_CFG=/local/repository/etc/ru/bru1/ru_config.cfg

# Physical interface on cudu connected to the fronthaul (eth1 maps to this)
FH_PARENT_IF=eno12409
# These will be populated from the manifest; fallback values match Benetel factory M-plane defaults
RU_MGMT_HOST_IP=10.10.0.1
RU_IP=10.10.0.100
SCP_ARGS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

VLAN_ID=""

# --- Method 1: read VLAN ID, RU IP, and cudu fronthaul IP from manifest via geni-get ---
echo "Attempting to read values from experiment manifest (geni-get)..."
if command -v geni-get &>/dev/null; then
    MANIFEST_VALS=$(geni-get manifest 2>/dev/null | python3 - <<'PYEOF'
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.stdin).getroot()
    ns = root.tag.split('}')[0].lstrip('{') if '}' in root.tag else ''
    pfx = ('{%s}' % ns) if ns else ''

    vlan_id = ''
    ru_ip = ''
    cudu_fh_ip = ''

    for link in root.iter('%slink' % pfx):
        if link.get('client_id') == 'duru1t':
            vlan_id = link.get('vlantag', '').strip()

    for iface in root.iter('%sinterface' % pfx):
        cid = iface.get('client_id', '')
        for ip in iface.iter('%sip' % pfx):
            addr = ip.get('address', '').strip()
            if cid == 'ru1:ru1duofh':
                ru_ip = addr
            elif cid == 'cudu:cuduru1ofh':
                cudu_fh_ip = addr

    print('%s %s %s' % (vlan_id, ru_ip, cudu_fh_ip))
except Exception as e:
    sys.stderr.write("manifest parse error: %s\n" % e)
    print('  ')
PYEOF
)
    read -r M_VLAN M_RU_IP M_CUDU_FH_IP <<< "$MANIFEST_VALS"

    if [[ "$M_VLAN" =~ ^[0-9]+$ ]]; then
        VLAN_ID="$M_VLAN"
        echo "Got VLAN ID $VLAN_ID from manifest."
    else
        echo "Could not extract VLAN ID from manifest. Trying interface detection."
    fi

    if [[ "$M_RU_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        RU_IP="$M_RU_IP"
        echo "Got RU IP $RU_IP from manifest."
    else
        echo "Could not extract RU IP from manifest. Using default: $RU_IP"
    fi

    if [[ "$M_CUDU_FH_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        RU_MGMT_HOST_IP="$M_CUDU_FH_IP"
        echo "Got cudu fronthaul IP $RU_MGMT_HOST_IP from manifest."
    else
        echo "Could not extract cudu fronthaul IP from manifest. Using default: $RU_MGMT_HOST_IP"
    fi
else
    echo "geni-get not available. Trying interface detection."
fi

# --- Method 2: detect VLAN sub-interface on parent port ---
if [ -z "$VLAN_ID" ]; then
    echo "Waiting up to 90s for VLAN sub-interface on $FH_PARENT_IF..."
    FH_VLAN_IF=""
    for i in $(seq 1 90); do
        FH_VLAN_IF=$(ip link show 2>/dev/null | grep -oP "${FH_PARENT_IF}\.\d+" | head -1)
        [ -n "$FH_VLAN_IF" ] && break
        sleep 1
    done

    if [ -n "$FH_VLAN_IF" ]; then
        VLAN_ID=$(echo "$FH_VLAN_IF" | awk -F. '{print $NF}')
        if [[ "$VLAN_ID" =~ ^[0-9]+$ ]]; then
            echo "Detected VLAN ID $VLAN_ID from interface $FH_VLAN_IF."
        else
            VLAN_ID=""
        fi
    fi
fi

# --- Fallback: use DEFAULT_FH_VLAN from common.sh (same default as DU sriov_conf.sh) ---
if [ -z "$VLAN_ID" ]; then
    VLAN_ID=$DEFAULT_FH_VLAN
    echo "WARNING: Could not detect VLAN from manifest or interface. Using default: $VLAN_ID"
    echo "         This must match DEFAULT_FH_VLAN in common.sh used by sriov_conf.sh on the DU."
fi

VLAN_HEX=$(printf '%x' "$VLAN_ID")
echo "Using fronthaul VLAN ID: $VLAN_ID (hex: ${VLAN_HEX})"

# --- Update ru_config.cfg (VLAN fields are stored as hex without 0x prefix) ---
echo "Updating RU VLAN fields in $RU_CFG..."
sed -i "s/^u_plane_du_vlan_uplink=.*/u_plane_du_vlan_uplink=${VLAN_HEX}/" "$RU_CFG"
sed -i "s/^u_plane_du_vlan_downlink=.*/u_plane_du_vlan_downlink=${VLAN_HEX}/" "$RU_CFG"
sed -i "s/^c_plane_du_vlan=.*/c_plane_du_vlan=${VLAN_HEX}/" "$RU_CFG"
echo "ru_config.cfg updated: u/c-plane VLAN set to ${VLAN_HEX}"

# --- Ensure VLAN sub-interface is up with the correct IP ---
FH_VLAN_IF="${FH_PARENT_IF}.${VLAN_ID}"
echo "Ensuring $FH_VLAN_IF is up with IP $RU_MGMT_HOST_IP..."
sudo ip addr add ${RU_MGMT_HOST_IP}/24 dev "$FH_VLAN_IF" 2>/dev/null || true
sudo ip link set "$FH_VLAN_IF" up

# --- Push config to RU (best-effort) ---
echo "Pushing ru_config.cfg to RU at $RU_IP..."
if scp $SCP_ARGS "$RU_CFG" root@$RU_IP:/etc/ru_config.cfg; then
    echo "ru_config.cfg successfully pushed to RU."
else
    echo "WARNING: Could not push ru_config.cfg to RU at $RU_IP (RU may not be ready yet)."
    echo "Run manually: scp $SCP_ARGS $RU_CFG root@$RU_IP:/etc/ru_config.cfg"
fi

VLAN_ID=""

# --- Method 1: read VLAN ID, RU IP, and cudu fronthaul IP from manifest via geni-get ---
echo "Attempting to read values from experiment manifest (geni-get)..."
if command -v geni-get &>/dev/null; then
    MANIFEST_VALS=$(geni-get manifest 2>/dev/null | python3 - <<'PYEOF'
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.stdin).getroot()
    ns = root.tag.split('}')[0].lstrip('{') if '}' in root.tag else ''
    pfx = ('{%s}' % ns) if ns else ''

    vlan_id = ''
    ru_ip = ''
    cudu_fh_ip = ''

    for link in root.iter('%slink' % pfx):
        if link.get('client_id') == 'duru1t':
            vlan_id = link.get('vlantag', '').strip()

    for iface in root.iter('%sinterface' % pfx):
        cid = iface.get('client_id', '')
        for ip in iface.iter('%sip' % pfx):
            addr = ip.get('address', '').strip()
            if cid == 'ru1:ru1duofh':
                ru_ip = addr
            elif cid == 'cudu:cuduru1ofh':
                cudu_fh_ip = addr

    print('%s %s %s' % (vlan_id, ru_ip, cudu_fh_ip))
except Exception as e:
    sys.stderr.write("manifest parse error: %s\n" % e)
    print('  ')
PYEOF
)
    read -r M_VLAN M_RU_IP M_CUDU_FH_IP <<< "$MANIFEST_VALS"

    if [[ "$M_VLAN" =~ ^[0-9]+$ ]]; then
        VLAN_ID="$M_VLAN"
        echo "Got VLAN ID $VLAN_ID from manifest."
    else
        echo "Could not extract VLAN ID from manifest. Falling back to interface detection."
    fi

    if [[ "$M_RU_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        RU_IP="$M_RU_IP"
        echo "Got RU IP $RU_IP from manifest."
    else
        echo "Could not extract RU IP from manifest. Using default: $RU_IP"
    fi

    if [[ "$M_CUDU_FH_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        RU_MGMT_HOST_IP="$M_CUDU_FH_IP"
        echo "Got cudu fronthaul IP $RU_MGMT_HOST_IP from manifest."
    else
        echo "Could not extract cudu fronthaul IP from manifest. Using default: $RU_MGMT_HOST_IP"
    fi
else
    echo "geni-get not available. Falling back to interface detection with default IPs."
fi

# --- Method 2 (fallback): detect VLAN sub-interface on parent port ---
if [ -z "$VLAN_ID" ]; then
    echo "Waiting up to 90s for VLAN sub-interface on $FH_PARENT_IF..."
    FH_VLAN_IF=""
    for i in $(seq 1 90); do
        FH_VLAN_IF=$(ip link show 2>/dev/null | grep -oP "${FH_PARENT_IF}\.\d+" | head -1)
        [ -n "$FH_VLAN_IF" ] && break
        sleep 1
    done

    if [ -z "$FH_VLAN_IF" ]; then
        echo "ERROR: No VLAN sub-interface found on $FH_PARENT_IF after 90s. Cannot update RU VLAN config."
        exit 1
    fi

    VLAN_ID=$(echo "$FH_VLAN_IF" | awk -F. '{print $NF}')
    if ! [[ "$VLAN_ID" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Could not extract a valid VLAN ID from interface $FH_VLAN_IF"
        exit 1
    fi
    echo "Detected VLAN ID $VLAN_ID from interface $FH_VLAN_IF."
fi

VLAN_HEX=$(printf '%x' "$VLAN_ID")
echo "Using fronthaul VLAN ID: $VLAN_ID (hex: ${VLAN_HEX})"

# --- Update ru_config.cfg (VLAN fields are stored as hex without 0x prefix) ---
echo "Updating RU VLAN fields in $RU_CFG..."
sed -i "s/^u_plane_du_vlan_uplink=.*/u_plane_du_vlan_uplink=${VLAN_HEX}/" "$RU_CFG"
sed -i "s/^u_plane_du_vlan_downlink=.*/u_plane_du_vlan_downlink=${VLAN_HEX}/" "$RU_CFG"
sed -i "s/^c_plane_du_vlan=.*/c_plane_du_vlan=${VLAN_HEX}/" "$RU_CFG"
echo "ru_config.cfg updated: u/c-plane VLAN set to ${VLAN_HEX}"

# --- Ensure VLAN sub-interface is up with the correct IP ---
FH_VLAN_IF="${FH_PARENT_IF}.${VLAN_ID}"
echo "Ensuring $FH_VLAN_IF is up with IP $RU_MGMT_HOST_IP..."
sudo ip addr add ${RU_MGMT_HOST_IP}/24 dev "$FH_VLAN_IF" 2>/dev/null || true
sudo ip link set "$FH_VLAN_IF" up

# --- Push config to RU (best-effort) ---
echo "Pushing ru_config.cfg to RU at $RU_IP..."
if scp $SCP_ARGS "$RU_CFG" root@$RU_IP:/etc/ru_config.cfg; then
    echo "ru_config.cfg successfully pushed to RU."
else
    echo "WARNING: Could not push ru_config.cfg to RU at $RU_IP (RU may not be ready yet)."
    echo "Run manually: scp $SCP_ARGS $RU_CFG root@$RU_IP:/etc/ru_config.cfg"
fi


SRCDIR=/local/repository
CFGDIR=/local/repository/etc
SERVICESDIR=/local/repository/etc/services
#SRS_PROJECT_REPO="https://github.com/srsRAN/srsRAN_Project"
OAI_PROJECT_REPO="https://gitlab.eurecom.fr/oai/openairinterface5g"

# Default VLAN ID for the DU-RU fronthaul link.
# Used as fallback when the manifest cannot be read.
# Must be the same on both DU (sriov_conf.sh) and RU (ru_config.cfg).
DEFAULT_FH_VLAN=168

# Helper: read the fronthaul VLAN ID from the experiment manifest.
# Prints the VLAN ID (decimal) to stdout, or nothing on failure.
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

#!/usr/bin/env python

import os

import geni.portal as portal
import geni.rspec.pg as pg
import geni.rspec.igext as ig
import geni.rspec.emulab.pnext as pn
import geni.rspec.emulab as emulab
import geni.rspec.emulab.lanext as lanext
import geni.rspec.emulab.spectrum as spectrum
import geni.rspec.emulab.cotsru as cotsru


# TODO: Update tourDescription for OAI deployment
# tourDescription was: "### srsRAN 5G, VVDN COTS O-RUs, COTS UE in RF matrix"
tourDescription = """
### OAI 5G gNB, Benetel O-RU: CN + CUDU + RU + UE topology
"""

tourInstructions = """
CN + CUDU + RU + UE (nuc16) topology.

#### Start the OAI gNB on `cudu`:
```
sudo /local/openairinterface5g/cmake_targets/ran_build/build/nr-softmodem -O /local/repository/etc/oai/gnb.sa.band78.106prb.fhi72.4x2.DDDSU.RAN650.conf
```

Check `ptp4l` and `phc2sys` status on `cudu` before starting gNB, and verify O-RU status.

#### On `ue1` (nuc16), connect UE:
```
sudo quectel-CM -s internet -4
```

In another terminal on `ue1`:
```
sudo minicom -D /dev/ttyUSB2
```

AT commands for UE control (within minicom):
```
# bring UE online
at+cfun=1

# put UE in airplane mode
at+cfun=4

# check serving cell
at+qeng="servingcell"
```

After attach, UE should be able to ping gateway at 10.45.0.1.

# OAI gNB conf file: `/local/repository/etc/oai/gnb.sa.band78.106prb.fhi72.4x2.DDDSU.RAN650.conf`

"""



BIN_PATH = "/local/repository/bin"
ETC_PATH = "/local/repository/etc"
UBUNTU_IMG = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"
UBUNTU_DPDK_IMG = "urn:publicid:IDN+emulab.net+image+DriveSafe:ubuntu2204-dpdk-iso"
COTS_UE_IMG = "urn:publicid:IDN+emulab.net+image+PowderTeam:cots-jammy-image"
COMP_MANAGER_ID = "urn:publicid:IDN+emulab.net+authority+cm"
OPEN5GS_DEPLOY_SCRIPT = os.path.join(BIN_PATH, "deploy-open5gs.sh")
OAI_DEPLOY_SCRIPT = os.path.join(BIN_PATH, "setup-oai.sh")
RIC_DEPLOY_SCRIPT = os.path.join(BIN_PATH, "setup-ric.sh")

# Name for the shared VLAN connecting cn5g (Open5GS + OSC near-RT RIC) and cudu (OAI DU).
# This single VLAN carries N2 (AMF<->gNB), N3 (UPF<->gNB), and E2 (near-RT RIC<->gNB) traffic.
# It is distinct from the fronthaul VLAN (duru1t) which carries eCPRI between cudu and ru1.
OAI_SHARED_VLAN_NAME = "OAI-shared-vlan"
OAI_SHARED_VLAN_CN5G_IP  = "192.168.1.1"
OAI_SHARED_VLAN_CUDU_IP  = "192.168.1.2"
OAI_SHARED_VLAN_NETMASK  = "255.255.255.0"

NODE_IDS = {
    #"ru1": "vmpru-b48-1",
    "ru1": "bru-650-5",
    "ue1": "nuc16",
}
MATRIX_GRAPH = {
    "ru1": ["ue1"],
    "ue1": ["ru1"],
}
MATRIX_INPUTS = ["ru1"]
RF_IFACES = {}
RF_LINK_NAMES = {}
for k, v in MATRIX_GRAPH.items():
    RF_IFACES[k] = {}
    for node in (v):
        RF_IFACES[k][node] = "{}_{}_rf".format(k, node)
        if k in MATRIX_INPUTS:
            RF_LINK_NAMES["rflink_{}_{}".format(k, node)] = []

for k, v in MATRIX_GRAPH.items():
    if k in MATRIX_INPUTS:
        for node in (v):
            RF_LINK_NAMES["rflink_{}_{}".format(k, node)].append(RF_IFACES[k][node])
            RF_LINK_NAMES["rflink_{}_{}".format(k, node)].append(RF_IFACES[node][k])


pc = portal.Context()

node_types = [
    ("d760p", "Emulab, d760"),
    ("d430", "Emulab, d430"),
    ("d740", "Emulab, d740"),
]


pc.defineParameter(
    name="sdr_compute_image",
    description="Image to use for compute connected to SDRs",
    typ=portal.ParameterType.STRING,
    defaultValue="",
    advanced=True
)

params = pc.bindParameters()
pc.verifyParameters()
request = pc.makeRequestRSpec()

node_name = "cn5g"
cn_node = request.RawPC(node_name)
cn_node.component_manager_id = COMP_MANAGER_ID
# Upgraded from d710 to d430: cn5g now co-hosts Open5GS + Kubernetes + OSC near-RT RIC.
# A d710 is too lightweight for this combined workload.
cn_node.hardware_type = "d430"
cn_node.disk_image = UBUNTU_IMG
cn_if = cn_node.addInterface("{}-if".format(node_name))
cn_if.addAddress(pg.IPv4Address(OAI_SHARED_VLAN_CN5G_IP, OAI_SHARED_VLAN_NETMASK))
# OAI_shared_VLAN: shared link between cn5g and cudu.
# Carries N2/N3 (Open5GS <-> OAI gNB) and E2 (OSC near-RT RIC <-> OAI gNB E2 agent).
OAI_shared_VLAN = request.Link(OAI_SHARED_VLAN_NAME)
OAI_shared_VLAN.setNoBandwidthShaping()
OAI_shared_VLAN.addInterface(cn_if)
cn_node.addService(pg.Execute(shell="bash", command=OPEN5GS_DEPLOY_SCRIPT))
cn_node.addService(pg.Execute(shell="bash", command="/local/repository/bin/install-improved-iperf3.sh"))
cn_node.addService(pg.Execute(shell="bash", command="/local/repository/bin/start-iperf.pl"))
cn_node.addService(pg.Execute(shell="bash", command="/local/repository/bin/install-vsftpd.sh"))
# OSC near-RT RIC (j-release) deployed via Kubernetes on cn5g.
# setup-ric.sh installs Kubespray (single-node cluster) then the OSC RIC.
cn_node.addService(pg.Execute(shell="bash", command=RIC_DEPLOY_SCRIPT))

# Public IP pool for MetalLB on the cn5g Kubernetes cluster.
# MetalLB uses this to expose the OSC RIC services externally if needed.
cn5g_apool = ig.AddressPool("cn5g", 1)
request.addResource(cn5g_apool)

node_name = "cudu"
cudu = request.RawPC(node_name)
cudu.component_manager_id = COMP_MANAGER_ID
cudu.hardware_type = "d760p"  # auto-select any available d760p

#We can install the regular ubuntu image and then install DPDK as part of the OAI deployment script.

cudu.disk_image = UBUNTU_IMG  #TODO: update image for OAI deployment if needed
cudu_cn_if = cudu.addInterface("{}-cn-if".format(node_name))
cudu_cn_if.component_id = "eth0"
cudu_cn_if.addAddress(pg.IPv4Address(OAI_SHARED_VLAN_CUDU_IP, OAI_SHARED_VLAN_NETMASK))
OAI_shared_VLAN.addInterface(cudu_cn_if)

duru1ofh = cudu.addInterface("{}ru1ofh".format(node_name))
duru1ofh.component_id = "eth1"
duru1ofh.PTP()
#duru2ofh = cudu.addInterface("{}ru2ofh".format(node_name))


# Add OAI gNB deploy service here
cudu.addService(pg.Execute(shell="bash", command=OAI_DEPLOY_SCRIPT))
# setup-ptp.sh is now merged into setup-oai.sh
cudu.addService(pg.Execute(shell="bash", command="/local/repository/bin/update-attens bru1 0"))
#cudu.addService(pg.Execute(shell="bash", command="/local/repository/bin/update-attens bru2 95"))
cudu.addService(pg.Execute(shell="bash", command="/local/repository/bin/update-ru-vlan.sh"))

# collect node objects for RF matrix
matrix_nodes = {}
ru_mimo_mode = "1_2_3_4_4x2"

du_mac_addr ="30:3e:a7:1a:8e:49"
ru_type = "bt-ru650"
nr_arfcn = 643334 #Corresponds to 3750 MHz
#nr_arfcn = 3750 #Corresponds to 3750 MHz
bandwidth_mhz = 40 #Bandwidth in MHz
# benetel RU 1
node_name = "ru1"
#ru1 = request.RawPC(node_name)
ru1 = request.COTSRU(client_id=node_name, hardware_type=ru_type, arfcn=nr_arfcn, bandwidth=bandwidth_mhz, mimo_mode=ru_mimo_mode, du_mac = du_mac_addr,component_id=NODE_IDS[node_name])
ru1.component_manager_id = COMP_MANAGER_ID
#ru1.component_id = NODE_IDS[node_name]
ru1duofh = ru1.addInterface("{}duofh".format(node_name))
ru1duofh.component_id = "eth0"
ru1duofh.PTP()
ru1duofh.SyncE()
duru1t = request.Link("duru1t", members=[duru1ofh, ru1duofh])
duru1t.vlan_tagging = True  # Let Emulab auto-configure VLAN on fronthaul link
# duru1t.setVlanTag(params.vlan_id_ru1)
ru1.Desire("rf-controlled", 1)
matrix_nodes[node_name] = ru1

# COTS UEs
node_name = "ue1"
ue1 = request.RawPC(node_name)
ue1.component_manager_id = COMP_MANAGER_ID
ue1.component_id = NODE_IDS[node_name]
ue1.disk_image = COTS_UE_IMG
ue1.Desire("rf-controlled", 1)
ue1.addService(pg.Execute(shell="bash", command="/local/repository/bin/module-airplane.sh"))
ue1.addService(pg.Execute(shell="bash", command="/local/repository/bin/setup-cots-ue.sh internet"))
matrix_nodes[node_name] = ue1


rf_ifaces = {}
for node_name, node in matrix_nodes.items():
    for rf_iface_name in RF_IFACES[node_name].values():
        rf_ifaces[rf_iface_name] = node.addInterface(rf_iface_name)

for rf_link_name, rf_iface_names in RF_LINK_NAMES.items():
    rf_link = request.RFLink(rf_link_name)
    for iface_name in rf_iface_names:
        rf_link.addInterface(rf_ifaces[iface_name])


tour = ig.Tour()
tour.Description(ig.Tour.MARKDOWN, tourDescription)
tour.Instructions(ig.Tour.MARKDOWN, tourInstructions)
request.addTour(tour)

pc.printRequestRSpec(request)

#!/usr/bin/env python

import os

import geni.portal as portal
import geni.rspec.pg as pg
import geni.rspec.igext as ig
import geni.rspec.emulab.pnext as pn
import geni.rspec.emulab as emulab
import geni.rspec.emulab.lanext as lanext


# TODO: Update tourDescription for OAI deployment
# tourDescription was: "### srsRAN 5G, VVDN COTS O-RUs, COTS UE in RF matrix"
tourDescription = """
### OAI 5G gNB, VVDN COTS O-RUs, COTS UE in RF matrix (TODO: update for OAI)
"""

tourInstructions = """
WIP...

#TODO: automate teleop station setup
#TODO: automate UE teleop setup
#TODO: add updated HO control
#TODO: update docs

#### RAN+RF matrix commands for a simple test...

on `cudu` run:
```
sudo /var/tmp/openairinterface5g/ran_build/build/nr-softmodem -O /var/tmp/etc/oai/gnb.sa.band78.106prb.fhi72.4x2.DDDSU.RAN650.conf --sa
# TODO: Replace with OAI gNB start command
# [SRSRAN - DISABLED] sudo /var/tmp/srsRAN_Project/nbuild/apps/gnb/gnb -c /var/tmp/etc/srsran/gnb_ru_ho_test.yml -c /var/tmp/etc/srsran/e2.yml
```

on `ue1` run:

```
sudo quectel-CM -s internet -4
```

in another terminal on `ue1` run:

```
sudo minicom -D /dev/ttyUSB2
```

to start minicom and then use the following AT commands for UE control:

```
# within minicom
# bring UE online
at+cfun=1

# put UE in airplane mode
at+cfun=4

# check serving cell
at+qeng="servingcell"
```

After attach, UE should be able to ping gateway at 10.45.0.1, and the public IP address of the `teleop` node.

# TODO: Update config file paths for OAI deployment
# OAI gNB conf file: `/var/tmp/etc/oai/gnb.sa.band78.106prb.fhi72.4x2.DDDSU.RAN650.conf`
# [SRSRAN - DISABLED] PCIs for the O-RUs can be found in `/var/tmp/etc/srsran/gnb_ru_ho_test.yml` along with other RAN configuration.
# [SRSRAN - DISABLED] E2 setup is at `/var/tmp/etc/srsran/e2.yml`. (Connects to RIC in separate O-RAN experiment for now.)

If UE cannot see/attach to cell; need to check `ptp4l` and `phc2sys` status on `cudu`, and then check status of O-RU.


"""



BIN_PATH = "/local/repository/bin"
ETC_PATH = "/local/repository/etc"
UBUNTU_IMG = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"
UBUNTU_DPDK_IMG = "urn:publicid:IDN+emulab.net+image+DriveSafe:ubuntu2204-dpdk-iso"
COTS_UE_IMG = "urn:publicid:IDN+emulab.net+image+PowderTeam:cots-jammy-image"
COMP_MANAGER_ID = "urn:publicid:IDN+emulab.net+authority+cm"
# DEFAULT_SRSRAN_HASH = "cdc93a60920dfbb2727910f84966068b8e75004d"  # late sept 2025 [SRSRAN - DISABLED]
OPEN5GS_DEPLOY_SCRIPT = os.path.join(BIN_PATH, "deploy-open5gs.sh")
# SRSRAN_DEPLOY_SCRIPT = os.path.join(BIN_PATH, "deploy-srsran.sh")  # [SRSRAN - DISABLED]
OAI_DEPLOY_SCRIPT = os.path.join(BIN_PATH, "setup-oai.sh")

NODE_IDS = {
    #"ru1": "vmpru-b48-1",
    "ru1": "bru-650-5",
 #   "ru2": "vmpru-b48-2",
    #"ue1": "nuc6",
    "ue1": "nuc16",
 #   "ue2": "nuc6",
}
MATRIX_GRAPH = {
    #"ru1": ["ue1", "ue2"],
    "ru1": ["ue1"],
#    "ru2": ["ue1", "ue2"],
    "ue1": ["ru1"],
#    "ue2": ["ru1", "ru2"],
}
#MATRIX_INPUTS = ["ru1", "ru2"]
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
# pc.defineParameter(
#     name="sdr_nodetype",
#     description="Type of compute node paired with the SDRs",
#     typ=portal.ParameterType.STRING,
#     defaultValue=node_types[2],
#     legalValues=node_types
# )

# pc.defineParameter(
#     name="cn_nodetype",
#     description="Type of compute node to use for CN node (if included)",
#     typ=portal.ParameterType.STRING,
#     defaultValue=node_types[0],
#     legalValues=node_types
# )

pc.defineParameter(
    name="cn_compute_id",
    description="Component ID for core network compute node",
    typ=portal.ParameterType.STRING,
    defaultValue="pc20-meb",
)

pc.defineParameter(
    name="cudu_compute_id",
    description="Component ID for compute node connected to RU",
    typ=portal.ParameterType.STRING,
    defaultValue="pc24-fort",
    # defaultValue=node_types[0],
    # legalValues=node_types
)

pc.defineParameter(
    name="vlan_id_ru1",
    description="VLAN ID for RU1",
    typ=portal.ParameterType.INTEGER,
    defaultValue=28,
)

#pc.defineParameter(
#    name="vlan_id_ru2",
#    description="VLAN ID for RU2",
#    typ=portal.ParameterType.INTEGER,
#    defaultValue=29,
#)

# [SRSRAN - DISABLED] use_dpdk parameter (srsRAN-specific, not needed for OAI)
# pc.defineParameter(
#     name="use_dpdk",
#     description="Use DPDK for srsRAN w/ O-RU CU/DU",
#     typ=portal.ParameterType.BOOLEAN,
#     defaultValue=True,
#     advanced=True
# )

# [SRSRAN - DISABLED] srsran_commit_hash parameter
# pc.defineParameter(
#     name="srsran_commit_hash",
#     description="Commit hash for srsRAN",
#     typ=portal.ParameterType.STRING,
#     defaultValue="",
#     advanced=True
# )
# TODO: Add OAI commit hash parameter here

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
cn_node.component_id = params.cn_compute_id
cn_node.disk_image = UBUNTU_IMG
cn_if = cn_node.addInterface("{}-if".format(node_name))
cn_if.addAddress(pg.IPv4Address("192.168.1.1", "255.255.255.0"))
cn_link = request.Link("{}-link".format(node_name))
cn_link.setNoBandwidthShaping()
cn_link.addInterface(cn_if)
cn_node.addService(pg.Execute(shell="bash", command=OPEN5GS_DEPLOY_SCRIPT))
cn_node.addService(pg.Execute(shell="bash", command="/local/repository/bin/install-improved-iperf3.sh"))
cn_node.addService(pg.Execute(shell="bash", command="/local/repository/bin/start-iperf.pl"))
cn_node.addService(pg.Execute(shell="bash", command="/local/repository/bin/install-vsftpd.sh"))

node_name = "cudu"
cudu = request.RawPC(node_name)
cudu.component_manager_id = COMP_MANAGER_ID
cudu.component_id = params.cudu_compute_id
# [SRSRAN - DISABLED] cudu.disk_image = UBUNTU_DPDK_IMG if params.use_dpdk else (params.sdr_compute_image if params.sdr_compute_image else UBUNTU_IMG)

#We can install the regular ubuntu image and then install DPDK as part of the OAI deployment script.

cudu.disk_image = UBUNTU_IMG  #TODO: update image for OAI deployment if needed
cudu_cn_if = cudu.addInterface("{}-cn-if".format(node_name))
cudu_cn_if.PTP()
cudu_cn_if.component_id = "eth0"
cudu_cn_if.addAddress(pg.IPv4Address("192.168.1.2", "255.255.255.0"))
cn_link.addInterface(cudu_cn_if)

duru1ofh = cudu.addInterface("{}ru1ofh".format(node_name))
duru1ofh.component_id = "eth1"
#duru2ofh = cudu.addInterface("{}ru2ofh".format(node_name))
#duru2ofh.component_id = "eth2"

# [SRSRAN - DISABLED] SRS deployment command construction
# if params.srsran_commit_hash:
#     srsran_hash = params.srsran_commit_hash
# else:
#     srsran_hash = DEFAULT_SRSRAN_HASH
#
# if params.use_dpdk:
#     cmd = "{} '{}' dpdk".format(SRSRAN_DEPLOY_SCRIPT, srsran_hash)
# else:
#     cmd = "{} '{}'".format(SRSRAN_DEPLOY_SCRIPT, srsran_hash)

# Add OAI gNB deploy service here
cudu.addService(pg.Execute(shell="bash", command=OAI_DEPLOY_SCRIPT))
cudu.addService(pg.Execute(shell="bash", command="sudo /local/repository/bin/setup-ptp.sh"))
cudu.addService(pg.Execute(shell="bash", command="/local/repository/bin/update-attens bru1 0"))
#cudu.addService(pg.Execute(shell="bash", command="/local/repository/bin/update-attens bru2 95"))

# collect node objects for RF matrix
matrix_nodes = {}

# benetel RU 1
node_name = "ru1"
ru1 = request.RawPC(node_name)
ru1.component_manager_id = COMP_MANAGER_ID
ru1.component_id = NODE_IDS[node_name]
ru1duofh = ru1.addInterface("{}duofh".format(node_name))
ru1duofh.component_id = "eth0"
ru1duofh.PTP()
ru1duofh.SyncE()
duru1t = request.Link("duru1t", members=[duru1ofh, ru1duofh])
duru1t.vlan_tagging = True
duru1t.setVlanTag(params.vlan_id_ru1)
ru1.Desire("rf-controlled", 1)
matrix_nodes[node_name] = ru1

# benetel RU 2
#node_name = "ru2"
#ru2 = request.RawPC(node_name)
#ru2.component_manager_id = COMP_MANAGER_ID
#ru2.component_id = NODE_IDS[node_name]
#ru2duofh = ru2.addInterface("{}duofh".format(node_name))
#ru2duofh.component_id = "eth0"
#ru2duofh.PTP()
#ru2duofh.SyncE()
#duru2t = request.Link("duru2t", members=[duru2ofh, ru2duofh])
#duru2t.vlan_tagging = True
#duru2t.setVlanTag(params.vlan_id_ru2)
#ru2.Desire("rf-controlled", 1)
#matrix_nodes[node_name] = ru2

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

#node_name = "ue2"
#ue2 = request.RawPC(node_name)
#ue2.component_manager_id = COMP_MANAGER_ID
#ue2.component_id = NODE_IDS[node_name]
#ue2.disk_image = COTS_UE_IMG
#ue2.Desire("rf-controlled", 1)
#ue2.addService(pg.Execute(shell="bash", command="/local/repository/bin/module-airplane.sh"))
#ue2.addService(pg.Execute(shell="bash", command="/local/repository/bin/setup-cots-ue.sh internet"))
#matrix_nodes[node_name] = ue2

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

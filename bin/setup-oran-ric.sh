#!/bin/sh

set -x

# Grab our libs
. "`dirname $0`/setup-lib-ric.sh"

if [ -f $OURDIR/setup-oran-done ]; then
    exit 0
fi

logtstart "oran"

mkdir -p $OURDIR/oran
cd $OURDIR/oran

# Login to o-ran docker registry server (both staging and release) so
# that Dockerfile base images can be pulled.
$SUDO docker login -u docker -p docker https://nexus3.o-ran-sc.org:10004
$SUDO docker login -u docker -p docker https://nexus3.o-ran-sc.org:10002
$SUDO chown -R $SWAPPER ~/.docker

#
# The O-RAN build image repo is purged pretty regularly, so re-tag old
# image names to point to the latest thing, to enable old builds.
#
if [ -n "$BUILDORANSC" -a "$BUILDORANSC" = "1" ]; then
    CURRENTIMAGE="nexus3.o-ran-sc.org:10002/o-ran-sc/bldr-ubuntu18-c-go:1.9.0"
    OLDIMAGES="nexus3.o-ran-sc.org:10004/o-ran-sc/bldr-ubuntu18-c-go:1.9.0 nexus3.o-ran-sc.org:10004/o-ran-sc/bldr-ubuntu18-c-go:9-u18.04 nexus3.o-ran-sc.org:10004/o-ran-sc/bldr-ubuntu18-c-go:8-u18.04"

    $SUDO docker pull $CURRENTIMAGE
    for oi in $OLDIMAGES ; do
	$SUDO docker tag $CURRENTIMAGE $oi
    done
fi

#
# Custom-build the O-RAN components we might need.
#

E2TERM_REGISTRY=${HEAD}.cluster.local:5000
if [ $RICVERSION -eq $RICDAWN ]; then
    E2TERM_TAG="5.4.9-powder"
elif [ $RICVERSION -eq $RICERELEASE ]; then
    E2TERM_TAG="5.5.0-powder"
elif [ $RICVERSION -eq $RICFRELEASE ]; then
    E2TERM_TAG="6.0.0-powder"
elif [ $RICVERSION -eq $RICGRELEASE ]; then
    E2TERM_TAG="6.0.1-powder"
fi
if [ -n "$BUILDORANSC" -a "$BUILDORANSC" = "1" ]; then
    E2TERM_NAME="e2term"
    git clone https://gitlab.flux.utah.edu/powderrenewpublic/e2
    cd e2
    git checkout ${RICRELEASE}-powder
    #git checkout 3f5c142bdef909687e4634ef5af22b4b280ecddf
    cd RIC-E2-TERMINATION
    $SUDO docker build -f Dockerfile -t ${E2TERM_REGISTRY}/${E2TERM_NAME}:${E2TERM_TAG} .
    $SUDO docker push ${E2TERM_REGISTRY}/${E2TERM_NAME}:${E2TERM_TAG}
    cd ../..
else
    E2TERM_REGISTRY="gitlab.flux.utah.edu:4567"
    E2TERM_NAME="powder-profiles/oran/e2term"
    $SUDO docker pull ${E2TERM_REGISTRY}/${E2TERM_NAME}:${E2TERM_TAG}
fi

#
# Deploy the platform.
#
RICDEPREPO=https://gerrit.o-ran-sc.org/r/ric-plt/ric-dep
RICDEPBRANCH=$RICRELEASE
if [ $RICVERSION -eq $RICDAWN ]; then
    RICDEPREPO=https://gitlab.flux.utah.edu/powderrenewpublic/ric-dep
    RICDEPBRANCH=dawn-powder
elif [ $RICVERSION -eq $RICHRELEASE ]; then
    RICDEPREPO=https://gitlab.flux.utah.edu/powderrenewpublic/ric-dep
    RICDEPBRANCH=h-release-powder
fi
git clone $RICDEPREPO -b $RICDEPBRANCH
cd ric-dep
git submodule update --init --recursive --remote
git submodule update

helm init --client-only --stable-repo-url "https://charts.helm.sh/stable"

if [ -e RECIPE_EXAMPLE/example_recipe_oran_${RICSHORTRELEASE}_release.yaml ]; then
    cp RECIPE_EXAMPLE/example_recipe_oran_${RICSHORTRELEASE}_release.yaml \
       $OURDIR/oran/example_recipe.yaml
else
    cp RECIPE_EXAMPLE/PLATFORM/example_recipe.yaml $OURDIR/oran
fi
if [ $RICVERSION -lt $RICHRELEASE ]; then
    cat <<EOF >$OURDIR/oran/example_recipe.yaml-override
e2term:
  alpha:
    image:
      registry: "${E2TERM_REGISTRY}"
      name: "${E2TERM_NAME}"
      tag: "${E2TERM_TAG}"
EOF
else
    touch $OURDIR/oran/example_recipe.yaml-override
fi
if [ $RICVERSION -eq $RICDAWN ]; then
    # appmgr > 0.4.3 isn't really released yet.
    cat <<EOF >>$OURDIR/oran/example_recipe.yaml-override
appmgr:
  image:
    appmgr:
      registry: "nexus3.o-ran-sc.org:10002/o-ran-sc"
      name: ric-plt-appmgr
      tag: 0.4.3
EOF
fi

yq --inplace ea '. as $item ireduce ({}; . * $item )' \
    $OURDIR/oran/example_recipe.yaml \
    $OURDIR/oran/example_recipe.yaml-override

# Unfortunately, the helm setup is completely intermingled
# with the chart packaging... and chartmuseum APIs aren't used to upload;
# just copy files into place.  So we have to do everything manually.
# They also assume ownership of the helm local repo... we need to work
# around this eventually, e.g. to co-deploy oran and onap.
#
# So for now, we start up the helm servecm plugin ourselves.

# This becomes root on our behalf :-/
# NB: we need >= 0.13 so that we can get the version that
# can restrict bind to localhost.
#
# helm servecm will prompt us if helm is not already installed,
# so do this manually.
curl -o /tmp/get.sh https://raw.githubusercontent.com/helm/chartmuseum/main/scripts/get-chartmuseum
bash /tmp/get.sh
# This script is super fragile w.r.t. extracting version --
# vulnerable to github HTML format change.  Forcing a particular
# tag works around it.
if [ ! $? -eq 0 ]; then
    bash /tmp/get.sh -v v0.13.1
fi
helm plugin install https://github.com/jdolitsky/helm-servecm
eval `helm env | grep HELM_REPOSITORY_CACHE`
mkdir -p "${HELM_REPOSITORY_CACHE}/local/"
nohup helm servecm --port=8879 --context-path=/charts --storage local \
    --storage-local-rootdir $HELM_REPOSITORY_CACHE/local/ \
    --listen-host localhost 2>&1 >/dev/null &
sleep 4

#
# Performance hack: pre-pull image content if we might have a mirror.
#
# NB: this is just the blobs.  We (k8s) will have to hit the original
# registry for each image as it deploys to grab the manifest.  But we will
# at least have the blobs.
#
BGPULL=0
echo "$DOCKEROPTIONS" | grep registry-mirror
if [ $? -eq 0 -a -e /local/repository/etc/osc-ric-cached-image-list-${RICRELEASE}.txt ]; then
    for image in `cat /local/repository/etc/osc-ric-cached-image-list-${RICRELEASE}.txt` ; do
	$SUDO docker pull $image
    done &
    BGPULL=1
fi

#
# "Modern" ric-dep repos have the common chart, but if not, just grab it from the it/dep repo.
#
if [ ! -e ric-common/Common-Template/helm/ric-common/Chart.yaml ]; then
    git clone --single-branch "https://gerrit.o-ran-sc.org/r/it/dep" ../dep
    cp -pRv ../dep/ric-common .
fi

#
# Lifted from bin/install_common_templates_to_helm.sh .  We want to start
# our own chartmuseum on localhost.
#
export COMMON_CHART_VERSION=`cat ric-common/Common-Template/helm/ric-common/Chart.yaml | grep version | awk '{print $2}'`
helm package -d /tmp ric-common/Common-Template/helm/ric-common
cp /tmp/ric-common-${COMMON_CHART_VERSION}.tgz "${HELM_REPOSITORY_CACHE}/local/"
helm repo add local http://127.0.0.1:8879/charts

if [ -n "$DONFS" -a "$DONFS" = "1" ]; then
    sed -i -e 's/^IS_INFLUX_PERSIST=.*$/IS_INFLUX_PERSIST="nfs-client"/' bin/install
fi

if [ $RICVERSION -gt $RICDAWN ]; then
    cd bin \
	&& ./install -f $OURDIR/oran/example_recipe.yaml -c "influxdb jaegeradapter"
else
    cd bin \
	&& ./install -f $OURDIR/oran/example_recipe.yaml
fi

for ns in ricplt ricxapp ; do # ricinfra
    kubectl get pods -n $ns
    kubectl wait pod -n $ns --for=condition=Ready --all --timeout=300s
done

$SUDO pkill chartmuseum

#
# Set up a local chartmuseum server for post-onboarder service dms_cli cases
# (post-dawn releases).
#
myip=`getnodeip $HEAD $MGMTLAN`
$SUDO docker inspect chartmuseum-oran
if [ ! $? -eq 0 ]; then
    $SUDO docker pull docker.io/bitnamilegacy/chartmuseum-archived:0.15.0-debian-11-r84
    $SUDO docker run -d \
        --name chartmuseum-oran \
	-p 127.0.0.1:8878:8080 -p $myip:8878:8080 \
	-e CONTEXT_PATH=charts \
	--restart always \
	docker.io/bitnamilegacy/chartmuseum-archived:0.15.0-debian-11-r84
fi

#
# Install dms_cli.
#
cd $OURDIR/oran
if [ ! -e appmgr ]; then
    git clone https://gerrit.o-ran-sc.org/r/ric-plt/appmgr
fi
if [ ! -e $OURDIR/venv/dms/bin/activate ]; then
    mkdir -p $OURDIR/venv
    cd $OURDIR/venv
    virtualenv --python /usr/bin/python3 dms
    . $OURDIR/venv/dms/bin/activate \
	&& cd $OURDIR/oran/appmgr/xapp_orchestrater/dev/xapp_onboarder \
	&& pip3 install . \
	&& deactivate
    #
    # xapp_onboarder relies on ancient flask_restful which is no
    # longer maintained (replaced by flask_restx).  So, if we are on
    # python 3.10 or above, where MutableMapping seems to no longer
    # be available in collections (now collections.abc), play a dirty,
    # dirty trick.  :)
    #
    PYMAJOR=`echo 'import sys; print(sys.version_info.major);' | python`
    PYMINOR=`echo 'import sys; print(sys.version_info.minor);' | python`
    if [ -n "$PYMAJOR" -a -n "$PYMINOR" -a "$PYMAJOR" = "3" -a $PYMINOR -gt 9 ]; then
	. $OURDIR/venv/dms/bin/activate \
	    && pip3 uninstall flask_restplus -y \
	    && pip3 install flask_restx \
	    && cd /local/setup/venv/dms/lib/python3*/site-packages/ \
	    && ln -s flask_restx flask_restplus \
	    && deactivate
    fi
fi
if [ ! -e $OURDIR/oran/dms_cli ]; then
    cat <<EOF >$OURDIR/oran/dms_cli
#!/bin/sh

if [ -z "\$CHART_REPO_URL" ]; then
    export CHART_REPO_URL=http://$myip:8878/charts
fi

. $OURDIR/venv/dms/bin/activate \
    && mkdir -p /tmp/dms_cli.tmpdir \
    && cd /tmp/dms_cli.tmpdir \
    && dms_cli "\$@"
EOF
    chmod 755 $OURDIR/oran/dms_cli
fi
if [ ! -e $OURDIR/oran/xapp-embedded-schema.json ]; then
    cp -p $OURDIR/oran/appmgr/xapp_orchestrater/dev/docs/xapp_onboarder/guide/embedded-schema.json \
       $OURDIR/oran/xapp-embedded-schema.json
fi

if [ $BGPULL -eq 1 ]; then
    wait
fi

logtend "oran"
touch $OURDIR/setup-oran-done

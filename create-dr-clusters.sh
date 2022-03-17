#!/usr/bin/bash 

HUB_NAME="${HUB_NAME:-hub-$(uuidgen)}"
SPOKE_NAME="${SPOKE_NAME:-spoke-$(uuidgen)}"
PULL_SECRET=$(cat pull-secret.txt)

read -r -d '' TEMPLATE_INSTALL_CONFIG <<EOF
apiVersion: v1
baseDomain: devcluster.openshift.com
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform:
    aws:
     type: m4.2xlarge
  replicas: 5
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform:
    aws:
      type: m4.2xlarge
  replicas: 3
metadata:
  creationTimestamp: null
  name: {{CLUSTER_NAME}}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  networkType: OpenShiftSDN
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: us-east-1
publish: External
pullSecret: ${PULL_SECRET}
EOF


function label-nodes {
	for node in `kubectl get nodes --selector='!node-role.kubernetes.io/master' --no-headers -o custom-columns=":metadata.name"`; do
        	echo "labeling node $node"
        	kubectl label nodes $node cluster.ocs.openshift.io/openshift-storage=""
	done
}

function clean {
        while read CLUSTER; do
		echo "Destroying cluster $CLUSTER"
        	./openshift-install destroy cluster --dir $CLUSTER
       		echo "Removing cluster directory $CLUSTER"
        	rm -rf $CLUSTER
	done < cluster-list.txt
	rm cluster-list.txt
}

function create-hub-cluster {
	mkdir $HUB_NAME
	echo $HUB_NAME >> cluster-list.txt
	echo "Creating hub cluster $HUB_NAME" 
	echo "$TEMPLATE_INSTALL_CONFIG" | sed "s/{{CLUSTER_NAME}}/${HUB_NAME}/g" > ${HUB_NAME}/install-config.yaml
	./openshift-install create cluster --dir $HUB_NAME
	export KUBECONFIG=${HUB_NAME}/auth/kubeconfig
	kubectl create -f deploy-acm.yaml
	sleep 1m
	kubectl create -f multiclusterhub.yaml
	label-nodes
	kubectl create -f deploy-odf.yaml
	oc apply -f csi-addon-sub-patch.yaml
	oc create -f https://raw.githubusercontent.com/red-hat-storage/volume-replication-operator/main/config/crd/bases/replication.storage.openshift.io_volumereplications.yaml
  oc create -f https://raw.githubusercontent.com/red-hat-storage/volume-replication-operator/main/config/crd/bases/replication.storage.openshift.io_volumereplicationclasses.yaml
	sleep 1m
	kubectl create -f storagesystem.yaml
	oc create namespace odfmo-system
}

function create-spoke-cluster {
	mkdir $SPOKE_NAME
	echo $SPOKE_NAME >> cluster-list.txt
	echo "Creating spoke cluster $SPOKE_NAME"
	echo "$TEMPLATE_INSTALL_CONFIG" | sed "s/{{CLUSTER_NAME}}/${SPOKE_NAME}/g" | sed 's/172.30.0.0/172.31.0.0/g'| sed 's/10.128.0.0/10.132.0.0/g' > ${SPOKE_NAME}/install-config.yaml
	./openshift-install create cluster --dir $SPOKE_NAME
	export KUBECONFIG=${SPOKE_NAME}/auth/kubeconfig
	label-nodes
	oc create -f deploy-odf.yaml
	oc apply -f csi-addon-sub-patch.yaml
	oc create -f https://raw.githubusercontent.com/red-hat-storage/volume-replication-operator/main/config/crd/bases/replication.storage.openshift.io_volumereplications.yaml
  oc create -f https://raw.githubusercontent.com/red-hat-storage/volume-replication-operator/main/config/crd/bases/replication.storage.openshift.io_volumereplicationclasses.yaml
	sleep 1m
	oc create -f storagesystem.yaml
}

function add-cluster-to-hub {
	KUBECONFIG=${SPOKE_NAME}/auth/kubeconfig
	SERVER=$(oc whoami --show-server)
	KUBE_PASSWORD=$(cat ${SPOKE_NAME}/auth/kubeadmin-password)
	AUTH_TOKEN=$(curl -u kubeadmin:${KUBE_PASSWORD} "https://oauth-openshift.apps.${SPOKE_NAME}.devcluster.openshift.com/oauth/authorize?response_type=token&client_id=openshift-challenging-client" -skv -H "X-CSRF-Token: xxx" --stderr - |  grep -oP "access_token=\K[^&]*")A
 	CLUSTER_NAME=spoke-cluster	
	KUBECONFIG=${HUB_NAME}/auth/kubeconfig
	oc create namespace ${CLUSTER_NAME}  
	oc label namespace ${CLUSTER_NAME} cluster.open-cluster-management.io/managedCluster=${CLUSTER_NAME}	
	cat <<EOF | oc apply -f - 
apiVersion: v1
kind: Secret
metadata:
  name: auto-import-secret
  namespace: ${CLUSTER_NAME}
stringData:
  autoImportRetry: "5"
  token: ${AUTH_TOKEN}
  server: ${SERVER}
  type: Opaque
EOF
	cat <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: ${CLUSTER_NAME}
spec:
  hubAcceptsClient: true
EOF
	cat <<EOF | oc apply -f -
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${CLUSTER_NAME}
spec:
  clusterName: ${CLUSTER_NAME}
  clusterNamespace: ${CLUSTER_NAME}
  applicationManager:
    enabled: true
  certPolicyController:
    enabled: true
  clusterLabels:
    cloud: auto-detect
    vendor: auto-detect
  iamPolicyController:
    enabled: true
  policyController:
    enabled: true
  searchCollector:
    enabled: true
  version: 2.3.0
EOF
sleep 30
oc get secret spoke-cluster-import -o go-template='{{range $k,$v := .data}}{{$v|base64decode}}{{"\n\n"}}{{end}}' -n spoke-cluster > import.yaml
export KUBECONFIG=${SPOKE_NAME}/auth/kubeconfig
oc apply -f import.yaml
sleep 30
# TODO the changes from above command are not relected in the spoke cluster and hence applying the same again
oc apply -f import.yaml
}

while getopts "ahscm" op; do
    case "${op}" in
        a)
        create-hub-cluster
	create-spoke-cluster
        ;;
        h)
        create-hub-cluster
        ;;
        s)
        create-spoke-cluster
        ;;
        c)
	echo "Cleaning all active clusters"
        clean
	;;
	m)
	echo "Adding ${SPOKE_NAME} to ${HUB_NAME}"
	add-cluster-to-hub
	;;
        *)
        echo "Invalid option"
    esac
done

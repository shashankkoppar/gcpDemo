#!/bin/bash

#Prerequisites
#gcloud sdk, git, jq
SERVICE_ACCOUNT_KEY_PATH="$1"
CLUSTER_NAME="$2"
PROJECT_NAME="$3"

if [[ -z $SERVICE_ACCOUNT_KEY_PATH ]] || [[ -z $CLUSTER_NAME ]] || [[ -z $PROJECT_NAME ]]
then
  echo "Please pass service account key path,project name and cluster name! Compute zone is hardcoded as us-central1-b for demo purpose!"
  exit 1
fi

#-------------------------------------------------------------------------------
# Define functions
#-------------------------------------------------------------------------------
function infomessage() {
  echo "========================================================="
  echo "[INFO] $1"
  echo "========================================================="
}

function getExternalIP() {
  local namespace="$1"
  until kubectl get ing basic-ingress -n $namespace -o json | jq '.status.loadBalancer.ingress[].ip'
  do
    sleep 40
    echo "Waiting for external ip for ingress to be assigned!"
  done
}

function deployAppAndCreateIngress() {

  local cluster_name="$1"
  local zone_name="$2"
  local project_name="$3"
  local namespace="$4"

  infomessage "Deploy application and create ingress in $cluster_name's $namspace!"
  gcloud container clusters get-credentials $cluster_name --zone $zone_name --project $project_name
  kubectl get pods -n $namespace

cat <<-EOF >>deployment.yaml
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: sinatra
spec:
  replicas: 1
  selector:
    matchLabels:
      run: sinatra
  strategy:
    rollingUpdate:
      maxSurge: 100%
      maxUnavailable: 30%
    type: RollingUpdate
  template:
    metadata:
      labels:
        run: sinatra
    spec:
      containers:
      - name: sinatra
        image: gcr.io/sinatra/test
        ports:
        - containerPort: 4567
        livenessProbe:
          httpGet:
            path: /
            port: 4567
          initialDelaySeconds: 20
          timeoutSeconds: 3
        readinessProbe:
          httpGet:
            path: /
            port: 4567
          initialDelaySeconds: 20
          timeoutSeconds: 3
EOF

  kubectl create -f deployment.yaml -n $namespace
  rm deployment.yaml
  kubectl expose deployment sinatra --target-port=4567 --port=80 --type=NodePort -n $namespace

  cat <<-EOF >>ingress.yaml
  apiVersion: extensions/v1beta1
  kind: Ingress
  metadata:
    name: basic-ingress
  spec:
    backend:
      serviceName: sinatra
      servicePort: 80
EOF

  kubectl create -f ingress.yaml -n $namespace
  rm ingress.yaml
  endpoint=`echo $(getExternalIP "$namespace") | tr -d '"'`
  while [[ "$(curl -s -o /dev/null -w ''%{http_code}'' $endpoint)" != "200" ]]; do
    sleep 40
    echo "Waiting for external IP to be ready!"
  done
  echo "Application is deployed and can be accessed from Ingress!"
}

function createAndTestHPA() {

  local cluster_name="$1"
  local zone_name="$2"
  local project_name="$3"
  local namspace="$4"

  infomessage "Test horizontal Pod Scaling in $cluster_name's $namespace!"
  gcloud container clusters get-credentials $cluster_name --zone $zone_name --project $project_name
  kubectl autoscale deployment sinatra --min=1 --max=5 --cpu-percent=8 -n $namespace
  external_ip=$(getExternalIP "$namespace")

  for run in {1..150}
  do
    curl -s $external_ip
  done
  sleep 5
  echo "Check HPA status"
  kubectl get hpa -n $namespace
  kubectl get pods -n $namspace
}

function createCluster() {

  local cluster_name="$1"
  local zone_name="$2"
  infomessage "Creating $cluster_name in $zone_name zone!"
  gcloud container clusters create $cluster_name --zone $zone_name --enable-network-policy --num-nodes=2
}

function upgradeCluster() {
  local cluster_name="$1"
  local zone_name="$2"
  infomessage "Updating kubernetes node pool in $cluster_name!"
  gcloud container node-pools create pool-$cluster_name --cluster=$cluster_name --num-nodes=1
  gcloud config set container/cluster $cluster_name
  gcloud container clusters get-credentials $cluster_name

  infomessage "Cordon the old nodes in $cluster_name!"

  declare -a nodes=($(kubectl get nodes  --selector=cloud.google.com/gke-nodepool=default-pool --output=jsonpath='{.items..metadata.name}'))
  for i in  "${nodes[@]}"
  do
    kubectl cordon $i
  done

  infomessage "Drain the old nodes in $cluster_name!"
  for i in  "${nodes[@]}"
  do
    kubectl drain $i --force --ignore-daemonsets
  done

  infomessage "Delete the old node pool in $cluster_name!"
  echo y | gcloud container node-pools delete default-pool

  echo "Check ingress endpoint if working properly in $cluster_name after cluster upgrade!"
  echo "Check staging ingress!"
  endpoint1=`echo $(getExternalIP "staging") | tr -d '"'`
  curl -I $endpoint1

  echo "Check production ingress!"
  endpoint2=`echo $(getExternalIP "production") | tr -d '"'`
  curl -I $endpoint2

}

function buildDockerImage() {

  local image_name="$1"
  gcloud config set builds/use_kaniko True
  gcloud builds submit --tag=$image_name
}

function deleteCluster() {

  local cluster_name="$1"
  local zone_name="$2"
  infomessage "Deleting $cluster_name in $zone_name zone!"
  echo y | gcloud container clusters delete $cluster_name --zone $zone_name
}

function createNamespaces() {
  local cluster_name="$1"
  infomessage "Creating Namspaces!"
  gcloud container clusters get-credentials $cluster_name
  kubectl create namespace staging
  kubectl create namespace production
  kubectl label namespace staging environment=staging
  kubectl label namespace production environment=production
}

function createNetworkPolicy() {

  local namespace="$1"
  infomessage "Creating NetworkPolicy for $namespace!"
  cat <<-EOF >>networkpolicy.yaml
  kind: NetworkPolicy
  apiVersion: networking.k8s.io/v1
  metadata:
    name: allow-traffic
  spec:
    podSelector:
      matchLabels:
        run: sinatra
    ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            environment: $namespace
EOF

  kubectl create -f networkpolicy.yaml -n $namespace
  rm networkpolicy.yaml
}

#-------------------------------------------------------------------------------
# initialize
#-------------------------------------------------------------------------------
infomessage "initialize prject and set compute zone"
gcloud auth activate-service-account --key-file="$SERVICE_ACCOUNT_KEY_PATH"
gcloud config set project $PROJECT_NAME
gcloud config set compute/zone us-central1-b

#-------------------------------------------------------------------------------
#  gcp cluster
#-------------------------------------------------------------------------------
createCluster "$CLUSTER_NAME" "us-central1-b"

#-------------------------------------------------------------------------------
#  Create namespaces
#-------------------------------------------------------------------------------
createNamespaces "$CLUSTER_NAME"
createNetworkPolicy "staging"
createNetworkPolicy "production"

#-------------------------------------------------------------------------------
# git clone sinatra project and change current working directory
#-------------------------------------------------------------------------------
infomessage "Getting sinatra application and creating Dockerfile"
git clone git@github.com:anynines/ruby-sinatra-example-app.git
cd ruby-sinatra-example-app

#Write dockerfile for sinatra
cat <<-EOF >>Dockerfile
FROM ruby:2.6.1-alpine3.9

COPY . .

RUN rm Gemfile.lock &&\
    bundle install

ENTRYPOINT ["bundle" ,"exec","ruby","app.rb", "-o","0.0.0.0"]
EOF

#-------------------------------------------------------------------------------
# Set up kaniko and build docker image
#-------------------------------------------------------------------------------
infomessage "Building docker image for sinatra using Kaniko"
buildDockerImage "gcr.io/sinatra/test"
rm -rf ruby-sinatra-example-app

#-------------------------------------------------------------------------------
# Set up kubectl and deploy application to access the cluster and Deploy ingress
#-------------------------------------------------------------------------------
deployAppAndCreateIngress "$CLUSTER_NAME" "us-central1-b" "$PROJECT_NAME" "staging"
deployAppAndCreateIngress "$CLUSTER_NAME" "us-central1-b" "$PROJECT_NAME" "production"

#-------------------------------------------------------------------------------
# Test HPA
#-------------------------------------------------------------------------------
createAndTestHPA "$CLUSTER_NAME" "us-central1-b" "$PROJECT_NAME" "staging"
createAndTestHPA "$CLUSTER_NAME" "us-central1-b" "$PROJECT_NAME" "production"

#-------------------------------------------------------------------------------
# upgradeCluster
#-------------------------------------------------------------------------------
upgradeCluster "$CLUSTER_NAME" "us-central1-b"

#-------------------------------------------------------------------------------
# Clean up
#-------------------------------------------------------------------------------
deleteCluster "$CLUSTER_NAME" "us-central1-b"

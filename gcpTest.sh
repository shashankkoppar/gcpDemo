#!/bin/bash

#Prerequisites
#gcloud sdk, git, jq
SERVICE_ACCOUNT_KEY_PATH="$1"

if [[ -z "$1" ]]; then

  echo "Please pass service account key path!"
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
  until kubectl get ing  basic-ingress  -o json | jq '.status.loadBalancer.ingress[].ip'
  do
    sleep 40
    echo "Waiting for external ip for ingress to be assigned"
  done
}

function deployAppAndCreateIngress() {

  local cluster_name="$1"
  local zone_name="$2"
  local project_name="$3"

  infomessage "Deploy application and create ingress in $cluster_name!"
  gcloud container clusters get-credentials $cluster_name --zone $zone_name --project $project_name
  kubectl get pods
  kubectl run --image=gcr.io/sinatra/test --port=4567 --limits=cpu=10m,memory=12Mi sinatra
  kubectl expose deployment sinatra --target-port=4567 --type=NodePort

  cat <<-EOF >>ingress.yaml
  apiVersion: extensions/v1beta1
  kind: Ingress
  metadata:
    name: basic-ingress
  spec:
    backend:
      serviceName: sinatra
      servicePort: 4567
EOF

  kubectl create -f ingress.yaml
  endpoint=`echo $(getExternalIP) | tr -d '"'`
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

  infomessage "Test horizontal Pod Scaling in $cluster_name!"
  gcloud container clusters get-credentials $cluster_name --zone $zone_name --project $project_name
  kubectl autoscale deployment sinatra --min=1 --max=5 --cpu-percent=8
  external_ip=$(getExternalIP)

  for run in {1..150}
  do
    curl -s $external_ip
  done
  sleep 5
  echo "Check HPA status"
  kubectl get hpa
  kubectl get pods
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

  endpoint=`echo $(getExternalIP) | tr -d '"'`
  echo "Check ingress endpoint if working properly in $cluster_name after cluster upgrade!"
  curl -I $endpoint

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

#-------------------------------------------------------------------------------
# initialize
#-------------------------------------------------------------------------------
infomessage "initialize prject and set compute zone"
gcloud auth activate-service-account --key-file="$SERVICE_ACCOUNT_KEY_PATH"
gcloud config set project sinatra
gcloud config set compute/zone us-central1-b

#-------------------------------------------------------------------------------
# Set up two gcp clusters
#-------------------------------------------------------------------------------
createCluster "sinatra-test-1" "us-central1-b"
createCluster "sinatra-test-2" "us-central1-b"

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
deployAppAndCreateIngress "sinatra-test-1" "us-central1-b" "sinatra"
deployAppAndCreateIngress "sinatra-test-2" "us-central1-b" "sinatra"

#-------------------------------------------------------------------------------
# Test HPA
#-------------------------------------------------------------------------------
createAndTestHPA "sinatra-test-1" "us-central1-b" "sinatra"
createAndTestHPA "sinatra-test-2" "us-central1-b" "sinatra"

#-------------------------------------------------------------------------------
# upgradeCluster
#-------------------------------------------------------------------------------
upgradeCluster "sinatra-test-1" "us-central1-b"
upgradeCluster "sinatra-test-2" "us-central1-b"

#-------------------------------------------------------------------------------
# Clean up
#-------------------------------------------------------------------------------
deleteCluster "sinatra-test-1" "us-central1-b"
deleteCluster "sinatra-test-2" "us-central1-b"

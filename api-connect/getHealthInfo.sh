#!/bin/bash

# This script is used to get the health info of API Connect V10 on OVA.
#
# Usage:
#   ./getHealthInfoV10.sh
#
# On the management server, this script requires `apicops`. Installation
# instructions for `apicops` is here: https://github.com/ibm-apiconnect/apicops#latest-v10-release

DIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

if [ -z "${KUBECONFIG}" ]; then
  echo KUBECONFIG not set. Set KUBECONFIG before running this script.
  echo Example:
  echo '  export KUBECONFIG=/etc/kubernetes/admin.conf'
  exit 1
fi

if [ ! -e "${KUBECONFIG}" ]; then
  echo "KUBECONFIG file \"${KUBECONFIG}\" does not exist."
  exit 1
fi

if [ ! -r "${KUBECONFIG}" ]; then
  echo "Cannot read KUBECONFIG file \"${KUBECONFIG}\". Give permission to"
  echo "config file with:"
  echo '  sudo chmod a+x '"\"${KUBECONFIG}\""
  exit 1
fi

echo "Detecting API Connect version"

apic_version=$(sudo apic version 2>/dev/null | grep subsystem-.*:10\..* | sed -e 's/.*://')
isV10=$(echo ${apic_version} | grep '^10\.' > /dev/null && echo true || echo false)
isV2018=$(echo ${apic_version} | grep '^2018\.' > /dev/null && echo true || echo false)

if sudo apic version 2> /dev/null | grep subsystem-management > /dev/null; then

  # Detect apicops 

  if [ -e "./apicops" ]; then
    apicops_cmd='./apicops'
    apicops_access_ok=$([ -x ${apicops_cmd} ] && echo "true" || echo "false")
  elif which apicops > /dev/null; then
    apicops_cmd=$(which apicops)
  else 
    echo "Health info on management servers requires apicops, either in the"
    echo "current directory or the system path."
    echo "Download apicops with these instructions: "
    echo "  https://github.com/ibm-apiconnect/apicops#latest-v10-release"
    exit 1;  
  fi

  if [ ! -x ${apicops_cmd} ]; then
    echo "Cannot run apicops. Give execute permission to apicops with"
    echo '  sudo chmod a+x '"\"${apicops_cmd}\""
    exit 1
  fi
fi

echo ' --> version:' ${apic_version}
echo ' --> isV10  :' ${isV10}
echo ' --> isV2018:' ${isV2018}
if [ ! -z ${apicops_cmd} ]; then
  echo 'Management apicops at "'${apicops_cmd}'"'
fi

echo "Setting up working directory"

out=$(mktemp -d)
echo " --> \"${out}\""
podlogs=$out/apic-logs/pod-logs
opslogs=$out/apic-logs/ops-logs
kublogs=$out/apic-logs/kube-logs
apiclogs=$out/apic-logs/apic-logs
mkdir -p $podlogs
mkdir -p $kublogs
mkdir -p $apiclogs

echo "Gathering pod status"

kubectl get pods -o wide > $kublogs/pods.wide
kubectl get pods -o json > $kublogs/pods.json

if [ ! -z "${apicops_cmd}" ]; then

  echo "Gathering management operations data"

  mkdir -p $opslogs
  ${apicops_cmd} services:identify-state             > $opslogs/services--identify-state.log
  if ${isV2018}; then
    ${apicops_cmd} tables:check-index                  > $opslogs/tables--check-index.log
    ${apicops_cmd} tables:check-link                   > $opslogs/tables--check-link.log
    ${apicops_cmd} task-queue:list-stuck-tasks         > $opslogs/task-queue--list-stuck-tasks.log
    ${apicops_cmd} webhook-subscriptions:check-orphans > $opslogs/webhook-subscriptions--check-orphans.log
  fi

fi

echo "Gathering container logs"

for __pod in $(kubectl get pods -o name | cut -d'/' -f2); do
  for __container in $(kubectl get pod $__pod -o jsonpath="{.spec.containers[*].name}"); do
    kubectl logs $__pod -c $__container &> $podlogs/${__pod}_${__container}.log
    kubectl logs --previous $__pod -c $__container &> $podlogs/${__pod}_${__container}__previous.log
    [ $? -eq 0 ] || rm -f $podlogs/${__pod}_${__container}__previous.log
  done
done

echo "Gathering apic data"

for i in status version; do
    sudo apic $i > $apiclogs/$i.log
done
sudo apic health-check --verbose > $apiclogs/health-check.log 
sudo apic logs

echo "Archiving results and removing working directory"

tar -C $out -cz -f ${DIR}/apic-logs.tgz .

rm -rf $out

echo "Complete. Logs in \"${DIR}/apic-logs.tgz\""

#!/bin/bash

FLAVOR="${1:-}"


sudo rm -rfv ${FLAVOR}/appliance/cache/* ${FLAVOR}/appliance/temp/*
sudo rm -fv $(find . | grep openshift_install)
./${FLAVOR}/appliance/generate_appliance.sh ${FLAVOR}/pull-secret.json ~/.ssh/id_ed25519.pub
./${FLAVOR}/configimage/generate_config_image.sh ${FLAVOR}/pull-secret.json
sudo rm -f /opt/cache/hbn/*
mv ${FLAVOR}/appliance/appliance.iso ${FLAVOR}/configimage/configimage/agentconfig.noarch.iso /opt/cache/hbn/
sudo restorecon -RFv /opt/cache/hbn/
./idrac.sh 192.168.132.150 http://192.168.132.10:8080/hbn/appliance.iso http://192.168.132.10:8080/hbn/agentconfig.noarch.iso
./idrac.sh 192.168.132.151 http://192.168.132.10:8080/hbn/appliance.iso http://192.168.132.10:8080/hbn/agentconfig.noarch.iso
./idrac.sh 192.168.132.152 http://192.168.132.10:8080/hbn/appliance.iso http://192.168.132.10:8080/hbn/agentconfig.noarch.iso


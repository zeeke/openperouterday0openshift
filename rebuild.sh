#!/bin/bash

sudo rm -rfv srv6raw/appliance/cache/* srv6raw/appliance/temp/*
sudo rm -fv $(find . | grep openshift_install)
./srv6raw/appliance/generate_appliance.sh srv6raw/pull-secret.json ~/.ssh/id_ed25519.pub
./srv6raw/configimage/generate_config_image.sh srv6raw/pull-secret.json
sudo rm -f /opt/cache/hbn/*
mv srv6raw/appliance/appliance.iso srv6raw/configimage/configimage/agentconfig.noarch.iso /opt/cache/hbn/
sudo restorecon -RFv /opt/cache/hbn/
./idrac.sh 192.168.132.150 http://192.168.132.10:8080/hbn/appliance.iso http://192.168.132.10:8080/hbn/agentconfig.noarch.iso
./idrac.sh 192.168.132.151 http://192.168.132.10:8080/hbn/appliance.iso http://192.168.132.10:8080/hbn/agentconfig.noarch.iso
./idrac.sh 192.168.132.152 http://192.168.132.10:8080/hbn/appliance.iso http://192.168.132.10:8080/hbn/agentconfig.noarch.iso


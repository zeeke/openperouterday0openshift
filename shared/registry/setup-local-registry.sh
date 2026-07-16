#!/usr/bin/env bash

source "/usr/local/bin/mount-agent-data.sh"

# Load and tag the registry image
source "/usr/local/bin/load-registry-image.sh"

# Create certificate for the local registry
mkdir -p /etc/iri-registry/certs

# Only generate self-signed certs if they don't already exist (e.g., from IRI TLS)
if [[ ! -s /etc/iri-registry/certs/tls.crt ]] || [[ ! -s /etc/iri-registry/certs/tls.key ]]; then
    echo "Generating self-signed certificate for local registry"
    openssl req -newkey rsa:4096 -nodes -sha256 -keyout /etc/iri-registry/certs/tls.key \
        -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=registry.appliance.openshift.com" \
        -addext "subjectAltName=DNS:registry.appliance.openshift.com,DNS:quay.io" \
        -x509 -days 36500 -out /etc/iri-registry/certs/tls.crt
else
    echo "Using existing certificates at /etc/iri-registry/certs/"
fi

# Apply certificates
mkdir -p /etc/docker/certs.d/registry.appliance.openshift.com:22625
mkdir -p /etc/containers/certs.d/registry.appliance.openshift.com:22625

cp /etc/iri-registry/certs/tls.crt /etc/pki/ca-trust/source/anchors/
update-ca-trust extract

# Config registry local dns
sed -i '/127.0.0.1 registry.appliance.openshift.com/d' /etc/hosts
echo "127.0.0.1 registry.appliance.openshift.com" >> /etc/hosts

#!/usr/bin/env bash
set -euo pipefail

# ====== CONFIGURATION VARIABLES ======
STATIC_IP="192.168.1.10"
NETMASK="255.255.255.0"
GATEWAY="192.168.1.1"
DNS1="8.8.8.8"
DNS2="8.8.4.4"
CLUSTER_NAME="k8s"
BASE_DOMAIN="dantest.internal"
INGRESS_IP="192.168.1.10"  # This is different IF you are running with a VIP for ingress
INTERFACE_NAME="eno1.10"
# ====================================

# Generate hosts file content
HOSTS_CONTENT=$(cat <<EOF
# Hosts file for OpenShift resilience
127.0.0.1 localhost localhost.localdomain localhost4 localhost4.localdomain4
::1 localhost localhost.localdomain localhost6 localhost6.localdomain6

# OpenShift API endpoints
${INGRESS_IP} master0.${CLUSTER_NAME}.${BASE_DOMAIN}
${INGRESS_IP} api.${CLUSTER_NAME}.${BASE_DOMAIN}
${INGRESS_IP} api-int.${CLUSTER_NAME}.${BASE_DOMAIN}

# OpenShift application routes
${INGRESS_IP} console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
${INGRESS_IP} oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
${INGRESS_IP} prometheus-k8s.openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
${INGRESS_IP} grafana.openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
${INGRESS_IP} alertmanager.openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}

# Wildcard entry for all apps (fallback)
${INGRESS_IP} dummy.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
EOF
)

# Advanced function to convert IP to reverse DNS format
ip_to_reverse() {
    local ip="$1"
    echo "$ip" | awk -F. '{print $4"."$3"."$2"."$1".in-addr.arpa"}'
}

# Generate reverse DNS entries dynamically
STATIC_IP_REVERSE=$(ip_to_reverse "$STATIC_IP")
INGRESS_IP_REVERSE=$(ip_to_reverse "$INGRESS_IP")

DNSMASQ_CONTENT=$(cat <<EOF
# OpenShift Local DNS Configuration
# Generated for cluster: ${CLUSTER_NAME}.${BASE_DOMAIN}

# API Endpoints
address=/api.${CLUSTER_NAME}.${BASE_DOMAIN}/${STATIC_IP}
address=/api-int.${CLUSTER_NAME}.${BASE_DOMAIN}/${STATIC_IP}

# Application Wildcard Routes
address=/.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/${INGRESS_IP}

# Specific Application Endpoints
address=/console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/${INGRESS_IP}
address=/oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/${INGRESS_IP}
address=/prometheus-k8s.openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/${INGRESS_IP}
address=/grafana.openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/${INGRESS_IP}
address=/alertmanager.openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/${INGRESS_IP}
address=/thanos-querier.openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}/${INGRESS_IP}

# PTR Records (Reverse DNS) - Generated dynamically from IP variables
ptr-record=${STATIC_IP_REVERSE},api-int.${CLUSTER_NAME}.${BASE_DOMAIN}
ptr-record=${INGRESS_IP_REVERSE},master0.${CLUSTER_NAME}.${BASE_DOMAIN}

# Additional hostnames for the nodes (adjust as needed)
address=/master0.${CLUSTER_NAME}.${BASE_DOMAIN}/${STATIC_IP}
address=/bootstrap.${CLUSTER_NAME}.${BASE_DOMAIN}/${STATIC_IP}

# Network Configuration
interface=lo
interface=${INTERFACE_NAME}
bind-interfaces

# Local domain handling
local=/${BASE_DOMAIN}/
domain=${BASE_DOMAIN}
expand-hosts

# Upstream DNS servers for external queries
server=${DNS1}
server=${DNS2}

# Logging (disable in production)
log-queries
log-dhcp

# Performance and caching
cache-size=1000
neg-ttl=60
local-ttl=60

# Security
bogus-priv
domain-needed
stop-dns-rebind
rebind-localhost-ok

# Additional useful options
no-resolv
no-poll
EOF
)

# Generate network interface configuration
IFCFG_CONTENT=$(cat <<EOF
TYPE=Ethernet
BOOTPROTO=static
ONBOOT=yes
NAME=${INTERFACE_NAME}
DEVICE=${INTERFACE_NAME}
IPADDR=${INGRESS_IP}
NETMASK=${NETMASK}
IPADDR1=${STATIC_IP}
NETMASK1=${NETMASK}
GATEWAY=${GATEWAY}
DNS1=${INGRESS_IP}
DEFROUTE=yes
EOF
)

DNSMASQ_OVERRIDE=$(cat <<'EOF'
[Unit]
Description=DNS caching server for OpenShift
After=network.target
Before=bootkube.service kubelet.service crio.service
Wants=network.target

[Install]
WantedBy=multi-user.target
RequiredBy=bootkube.service

[Service]
Type=simple
ExecStartPre=/usr/sbin/dnsmasq --test --conf-file=/etc/dnsmasq.conf
ExecStart=
ExecStart=/usr/sbin/dnsmasq --conf-file=/etc/dnsmasq.conf -k
Restart=on-failure
RestartSec=5
EOF
)

echo "Adding partition config, hosts file, and network interface config..."
echo "Static IP: ${STATIC_IP}"
echo "Cluster: ${CLUSTER_NAME}.${BASE_DOMAIN}"
echo "Interface: ${INTERFACE_NAME}"
echo ""
# ========== END EDIT ==========

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 input.json output.json"
  exit 1
fi

INPUT_JSON="$1"
OUTPUT_JSON="$2"

# Base64 encode all content
DNSMASQ_BASE64=$(printf "%s" "$DNSMASQ_CONTENT" | base64 | tr -d '\n')
IFCFG_BASE64=$(printf "%s" "$IFCFG_CONTENT" | base64 | tr -d '\n')
DNSMASQ_OVERRIDE_BASE64=$(printf "%s" "$DNSMASQ_OVERRIDE" | base64 | tr -d '\n')

MACHINE_CONFIG=$(cat <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-static-network
spec:
  config:
    ignition:
      version: 3.4.0
    storage:
      files:
        - path: /etc/dnsmasq.d/openshift.conf
          mode: 0644
          overwrite: true
          contents:
            source: data:text/plain;charset=utf-8;base64,${DNSMASQ_BASE64}
        - path: /etc/systemd/system/dnsmasq.service.d/override.conf
          mode: 0644
          overwrite: true
          contents:
            source: data:text/plain;charset=utf-8;base64,${DNSMASQ_OVERRIDE_BASE64}
        - path: /etc/sysconfig/network-scripts/ifcfg-${INTERFACE_NAME}
          mode: 0644
          overwrite: true
          contents:
            source: data:text/plain;charset=utf-8;base64,${IFCFG_BASE64}
    systemd:
      units:
        - name: dnsmasq.service
          enabled: true
          contents: |
            [Unit]
            Description=DNS caching server for OpenShift
            After=network.target
            Before=bootkube.service kubelet.service crio.service
            Wants=network.target

            [Service]
            Type=forking
            PIDFile=/run/dnsmasq.pid
            ExecStartPre=/usr/sbin/dnsmasq --test
            ExecStart=/usr/sbin/dnsmasq -k
            ExecReload=/bin/kill -HUP \$MAINPID
            Restart=on-failure
            RestartSec=5

            [Install]
            WantedBy=multi-user.target
            RequiredBy=bootkube.service
EOF
)

MACHINE_CONFIG_BASE64=$(printf "%s" "$MACHINE_CONFIG" | base64 | tr -d '\n')

# Construct jq objects for all files
JQ_OBJECTS=$(jq -n \
  --arg dnsmasq_b64 "$DNSMASQ_BASE64" \
  --arg ifcfg_b64 "$IFCFG_BASE64" \
  --arg override_b64 "$DNSMASQ_OVERRIDE_BASE64" \
  --arg interface "$INTERFACE_NAME" \
  --arg machine_b64 "$MACHINE_CONFIG_BASE64" \
  '
    {
      "files": [
        {
          overwrite: true,
          path: "/opt/openshift/manifests/99-master-static-network.yaml",
          user: { name: "root" },
          contents: { source: ("data:text/plain;charset=utf-8;base64," + $machine_b64) },
          mode: 420
        },
        {
          overwrite: true,
          path: "/opt/openshift/openshift/99-master-static-network.yaml",
          user: { name: "root" },
          contents: { source: ("data:text/plain;charset=utf-8;base64," + $machine_b64) },
          mode: 420
        },
        {
          overwrite: true,
          path: "/etc/dnsmasq.d/openshift.conf",
          user: { name: "root" },
          contents: { source: ("data:text/plain;charset=utf-8;base64," + $dnsmasq_b64) },
          mode: 420
        },
        {
          overwrite: true,
          path: "/etc/systemd/system/dnsmasq.service.d/override.conf",
          user: { name: "root" },
          contents: { source: ("data:text/plain;charset=utf-8;base64," + $override_b64) },
          mode: 420
        },
        {
          overwrite: true,
          path: ("/etc/sysconfig/network-scripts/ifcfg-" + $interface),
          user: { name: "root" },
          contents: { source: ("data:text/plain;charset=utf-8;base64," + $ifcfg_b64) },
          mode: 420
        }
      ],
      "systemd": {
        "units": [
          {
            name: "dnsmasq.service",
            enabled: true,
            contents: "[Unit]\nDescription=DNS caching server for OpenShift\nAfter=network.target\nBefore=bootkube.service kubelet.service crio.service\nWants=network.target\n\n[Service]\nType=forking\nPIDFile=/run/dnsmasq.pid\nExecStartPre=/usr/sbin/dnsmasq --test\nExecStart=/usr/sbin/dnsmasq -k\nExecReload=/bin/kill -HUP $MAINPID\nRestart=on-failure\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\nRequiredBy=bootkube.service"
          }
        ]
      }
    }
  '
)

echo "Generated file objects:"
echo "$JQ_OBJECTS" | jq '.[]'
echo ""

# Add all objects to root.storage.files[]
jq -c \
  --argjson config "$JQ_OBJECTS" \
  '
    .storage.files += $config.files |
    .systemd.units += $config.systemd.units
  ' "$INPUT_JSON" > "$OUTPUT_JSON"

echo "Successfully modified ignition file: $OUTPUT_JSON"
echo ""
echo "Files added:"
echo "  - /etc/dnsmsaq.d/openshift.conf (with static entries for ${CLUSTER_NAME}.${BASE_DOMAIN})"
echo "  - /etc/sysconfig/network-scripts/ifcfg-${INTERFACE_NAME} (static IP: ${STATIC_IP})"
echo "  - /etc/systemd/system/dnsmasq.service.d/override.conf (service ordering)"

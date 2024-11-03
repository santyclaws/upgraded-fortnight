#!/bin/bash

# Function to clean up existing network namespaces and veth pairs
cleanup_namespaces() {
    echo "Cleaning up existing network namespaces and veth pairs..."

    # Delete veth pairs if they exist
    for veth in $(ip link show | grep veth | awk '{print $2}' | sed 's/:$//'); do
        if ip link show "$veth" > /dev/null 2>&1; then
            echo "Deleting veth pair: $veth"
            ip link delete "$veth"
        else
            echo "Veth pair $veth does not exist, skipping."
        fi
    done

    # Delete namespaces
    for ns in $(ip netns list | awk '{print $1}'); do
        echo "Deleting namespace: $ns"
        ip netns del "$ns" 2>/dev/null || echo "Namespace $ns does not exist, skipping."
    done
}

# Function to create a network namespace
create_namespace() {
    local ns_name=$1
    if ip netns list | grep -q "$ns_name"; then
        echo "Namespace '$ns_name' already exists. Deleting it."
        ip netns del "$ns_name" 2>/dev/null || echo "Failed to delete existing namespace '$ns_name', it may not exist."
    fi
    ip netns add "$ns_name" || {
        echo "Failed to create namespace '$ns_name'."
        return 1
    }
    echo "Successfully created namespace '$ns_name'."
}

# Function to create a virtual Ethernet pair
create_veth() {
    local veth1=$1
    local veth2=$2
    local ns_name=$3

    if ip link show "$veth1" > /dev/null 2>&1; then
        echo "Veth pair $veth1 and $veth2 already exists, skipping creation."
        return 0
    fi

    ip link add "$veth1" type veth peer name "$veth2" || {
        echo "Failed to create veth pair: $veth1, $veth2"
        return 1
    }

    ip link set "$veth2" netns "$ns_name" || {
        echo "Failed to move $veth2 to namespace $ns_name"
        return 1
    }

    return 0
}

# Ensure SNMP daemon is installed
install_snmpd() {
    if ! command -v snmpd &> /dev/null; then
        echo "SNMP daemon (snmpd) not found. Installing..."
        sudo apt-get update
        sudo apt-get install -y snmpd
    fi
}

# Configuration
BASE_IP="192.168.100"      # Base IP range for all simulated devices
MAC_FILE="mac_addresses.conf"  # File to store static MAC addresses

# Static IPs for essential network elements
ROUTER_IP="$BASE_IP.1"
FIREWALL1_IP="$BASE_IP.2"
FIREWALL2_IP="$BASE_IP.3"
SWITCH1_IP="$BASE_IP.4"
SWITCH2_IP="$BASE_IP.5"
SWITCH3_IP="$BASE_IP.6"
SWITCH4_IP="$BASE_IP.7"

# Device Counts for dynamic devices
NUM_WORKSTATIONS=10
NUM_WIFI_DEVICES=10        # MacBooks and iPhones
NUM_ACCESS_POINTS=2

# Load or generate static MAC addresses
declare -A MAC_ADDRESSES

# Generate or load MAC address for a device
generate_or_load_mac() {
    local device_name=$1

    if [[ -f $MAC_FILE && -n $(grep "$device_name" "$MAC_FILE") ]]; then
        MAC_ADDRESSES[$device_name]=$(grep "$device_name" "$MAC_FILE" | cut -d '=' -f2)
    else
        local mac_suffix=$(printf '%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)))
        MAC_ADDRESSES[$device_name]="00:0c:29:33:$mac_suffix"
        echo "$device_name=${MAC_ADDRESSES[$device_name]}" >> "$MAC_FILE"
    fi
}

# Helper function to create virtual interface, configure MAC, and configure SNMP
create_device() {
    local device_name=$1
    local device_type=$2
    local ip=$3

    generate_or_load_mac "$device_name"
    local mac_addr="${MAC_ADDRESSES[$device_name]}"
    local ns_name="${device_name//-/_}"  # Replace dashes with underscores
    local short_name="${device_name:0:12}"  # Limit to 12 characters
    local veth_host="veth_${short_name}"
    local veth_ns="veth_${short_name}_ns"

    echo "Creating veth pair: $veth_host and $veth_ns"

    # Check for name length
    if [[ "${#veth_host}" -gt 15 || "${#veth_ns}" -gt 15 ]]; then
        echo "Error: Device name too long: $veth_host or $veth_ns"
        return 1
    fi

    # Create namespace if not already created
    create_namespace "$ns_name" || return 1

    # Create veth pair
    create_veth "$veth_host" "$veth_ns" "$ns_name" || return 1

    # Set the MAC address for the host side
    sudo ip link set dev "$veth_host" address "$mac_addr"

    # Configure IP for the host side
    sudo ip addr add "$ip/24" dev "$veth_host"
    sudo ip link set dev "$veth_host" up

    # Configure IP for the namespace side
    sudo ip netns exec "$ns_name" ip addr add "$ip/24" dev "$veth_ns"
    sudo ip netns exec "$ns_name" ip link set dev "$veth_ns" address "$mac_addr"
    sudo ip netns exec "$ns_name" ip link set dev "$veth_ns" up

    echo "Created $device_type $device_name with IP $ip and MAC $mac_addr"

    # Configure SNMP for this device
    SNMP_CONF="/etc/snmp/snmpd_${device_name}.conf"  # Use device name in the config file
    sudo cp /etc/snmp/snmpd.conf "$SNMP_CONF"
    echo "agentAddress udp:$ip:161" | sudo tee -a "$SNMP_CONF" > /dev/null
    echo "rocommunity public" | sudo tee -a "$SNMP_CONF" > /dev/null

    # Start SNMP daemon with unique config in the namespace
    sudo ip netns exec "$ns_name" snmpd -Lo -C -c "$SNMP_CONF" &

    DEVICE_COUNT=$((DEVICE_COUNT + 1))
}

# Ensure mac_addresses.conf exists
if [[ ! -f $MAC_FILE ]]; then
    touch $MAC_FILE
fi

# Install SNMP daemon if not already installed
install_snmpd

# Clean up existing namespaces
cleanup_namespaces

# Set up Device Counter
DEVICE_COUNT=0

# Create essential devices with static IPs and MACs
create_device "rtr" "Router/Switch" $ROUTER_IP
create_device "fw-1" "Ethernet Firewall" $FIREWALL1_IP
create_device "fw-2" "WiFi Firewall" $FIREWALL2_IP
create_device "sw-1" "Managed Switch" $SWITCH1_IP
create_device "sw-2" "Managed Switch" $SWITCH2_IP
create_device "sw-3" "Managed Switch" $SWITCH3_IP
create_device "sw-4" "Managed Switch" $SWITCH4_IP

# Dynamic IP assignment for workstations and Wi-Fi devices
START_IP=20  # Starting IP within the subnet for dynamic devices

# Create Workstations (10 devices)
for ((i=0; i<NUM_WORKSTATIONS; i++)); do
    IP="$BASE_IP.$((START_IP + i))"  # Use i for unique IPs
    create_device "ws-$i" "Workstation" $IP
done

# Create WiFi Access Points (2 devices)
for ((i=0; i<NUM_ACCESS_POINTS; i++)); do
    IP="$BASE_IP.$((START_IP + NUM_WORKSTATIONS + i))"  # Avoid overlap
    create_device "ap-$i" "WiFi AP" $IP
done

# Create WiFi Devices (10 devices - MacBooks and iPhones)
for ((i=0; i<NUM_WIFI_DEVICES; i++)); do
    IP="$BASE_IP.$((START_IP + NUM_WORKSTATIONS + NUM_ACCESS_POINTS + i))"  # Avoid overlap
    create_device "wi-$i" "WiFi Device" $IP
done

echo "Network simulation complete. Devices configured with SNMP, static IPs, and persistent MACs for essential network elements."

# Function to simulate network activity with SNMP requests
simulate_network_activity() {
    echo "Starting network activity simulation..."

    while true; do
        for ((i=0; i<DEVICE_COUNT; i++)); do
            IP="$BASE_IP.$((START_IP + i))"
            
            # Poll SNMP data (e.g., system uptime or interface status)
            snmpget -v 2c -c public "$IP" SNMPv2-MIB::sysUpTime.0 > /dev/null 2>&1
            
            # Simulate a ping to the next device (simple traffic generation)
            NEXT_IP="$BASE_IP.$((START_IP + (i + 1) % DEVICE_COUNT))"
            ping -c 1 "$NEXT_IP" > /dev/null 2>&1
        done
        sleep 5  # Adjust the sleep duration as needed
    done
}

# Uncomment the following line to start the simulation
simulate_network_activity

#!/bin/sh
# Runs inside the kubo container before every daemon start (mounted into /container-init.d).
# A small, polite node: DHT client only, few connections, a hard memory ceiling, and a gateway
# that serves only what this node pins (never fetches for strangers).
set -e
ipfs config --json Gateway.NoFetch true
ipfs config --json Gateway.DeserializedResponses true
ipfs config --json Swarm.ConnMgr '{"Type":"basic","LowWater":20,"HighWater":60,"GracePeriod":"30s"}'
ipfs config Swarm.ResourceMgr.MaxMemory "256MB"
ipfs config --json Swarm.DisableNatPortMap true
ipfs config --json Discovery.MDNS.Enabled false
ipfs config Datastore.StorageMax "20GB"

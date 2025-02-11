#!/bin/bash
set -e

if [[ $# != 1 ]] || { [[ "$1" != quic ]] && [[ "$1" != vanilla ]]; }
then
    echo "usage: ./create-network.sh (quic|vanilla)"
    exit 1;
fi

FLAVOR="$1"
DIR_PORT=$(grep Dirport torrc | awk '{print $2}')
DA_NODES=1
CLIENT_NODES=4
IP_TEMPLATE="10.0.0."
IP_NUMBER=5
echo "Clearing node directory"
rm -rf nodes/
mkdir nodes

TORSH_WHITELIST_AUTH_IPS=()
TORSH_WHITELIST_AUTH_PORT="8000"
TORSH_LAUNCHER_NAME="torsh-launch.sh"
TORSH_SERVER_CMD='
# Node is authority
echo "Starting TorSH server in the background"
ROCKET_ADDRESS="0.0.0.0" /torsh/bin/torsh-server --authlist-file /torsh/authlist/torsh_nodelist-0.json \
                                                 --whitelist-file /torsh/whitelist/torsh_whitelist-0.json \
                                                 --release-bin-dir /torsh/node-releases/ &'
TORSH_CLIENT_CMD='
echo "Starting TorSH client in the background"
TORSH_IPTABLES_USE_OUTPUT=1 RUST_BACKTRACE=1 TORSH_IN_CONTAINERNET=1 \
/torsh/bin/torsh-node --authlist-dir /torsh/authlist \
                      --whitelist-dir /torsh/whitelist \
                      --whitelist-update-interval 60 \
                      --profiling-max-endpoints 10 \
                      --profiling-submission-interval 30'

TORSH_PROXY_TORRC='
# TorSH-specific configuration
# Inspired by https://gitlab.torproject.org/legacy/trac/-/wikis/doc/OpenWRT
VirtualAddrNetwork 10.192.0.0/10
AutomapHostsOnResolve 1
TransPort 9040
DNSPort 9053
ExitPolicy accept *:*'

function create_node {
  NAME=$1
  NODE_DIR=$2
  echo "Creating $NAME"
  mkdir "$NODE_DIR"
  cp torrc "$NODE_DIR/"
  if [[ "$FLAVOR" == "quic" ]]
  then
      echo "QUIC 1" >> "$NODE_DIR/torrc"
  fi
  echo "Nickname $NAME" >> "$NODE_DIR/torrc"
  IP_NUMBER=$((IP_NUMBER + 1))
  IP="${IP_TEMPLATE}${IP_NUMBER}"
  echo "Address $IP" >> "$NODE_DIR/torrc"
}

# Directory authorities
for i in $(seq $DA_NODES); do
  NAME="a$i"
  NODE_DIR="nodes/$NAME"
  create_node "$NAME" "$NODE_DIR"
  KEYPATH="$NODE_DIR/keys"
  mkdir "$KEYPATH"
  echo 'password' | tor-gencert --create-identity-key --passphrase-fd 0 -a "$IP:$DIR_PORT" \
    -i "$KEYPATH"/authority_identity_key \
    -s "$KEYPATH"/authority_signing_key \
    -c "$KEYPATH"/authority_certificate
  echo | tor -f - --list-fingerprint --datadirectory "$NODE_DIR" --orport 1 --dirserver "x 127.0.0.1:1 ffffffffffffffffffffffffffffffffffffffff"
  cat torrc.da >> "$NODE_DIR"/torrc
  scripts/da_fingerprint.sh "$NODE_DIR" >>nodes/da
  TORSH_WHITELIST_AUTH_IPS+=( "$IP" ) 
done
for i in $(seq $DA_NODES); do
  NAME="a$i"
  NODE_DIR="nodes/$NAME"
  cat nodes/da >> "$NODE_DIR/torrc"
  echo "ExitPolicy reject *:*" >>"$NODE_DIR/torrc"
  echo "$TORSH_SERVER_CMD" >>"$NODE_DIR/$TORSH_LAUNCHER_NAME"
done

# Client nodes
for i in $(seq $CLIENT_NODES); do
  NAME="c$i"
  NODE_DIR="nodes/$NAME"
  create_node "$NAME" "$NODE_DIR"
  cat nodes/da >> "$NODE_DIR/torrc"
  echo "SOCKSPort 9050" >> "$NODE_DIR/torrc"
  echo "$TORSH_PROXY_TORRC" >> "$NODE_DIR/torrc"
  echo "$TORSH_CLIENT_CMD" >> "$NODE_DIR/$TORSH_LAUNCHER_NAME"
done

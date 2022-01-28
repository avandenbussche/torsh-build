#!/bin/bash
set -e

if [[ $# != 1 ]] || { [[ "$1" != quic ]] && [[ "$1" != vanilla ]]; }
then
    echo "usage: ./create-network.sh (quic|vanilla)"
    exit 1;
fi

FLAVOR="$1"
DIR_PORT=$(grep Dirport torrc | awk '{print $2}')
DA_NODES=3
RELAY_NODES=0 # NOTE: TorSH should not have idea of relay nodes, since all clients are also relays!
CLIENT_NODES=6
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
ROCKET_ADDRESS="0.0.0.0" /torsh/bin/torsh-server &'
TORSH_CLIENT_CMD='
# Node is client or relay
echo "Starting TorSH client in the background"
/torsh/bin/torsh-node --socket-path /torsh/torsh.sock --whitelist-dir /torsh/whitelist '
                      # we will append whitelist authorities below in for loop
                      # --whitelist-authority-url 10.0.0.6:8000 \\ \
                      # --whitelist-authority-url 10.0.0.7:8000 \\ \
                      # --whitelist-authority-url 10.0.0.8:8000 &'

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
  echo "Nickname $NAME" >>"$NODE_DIR/torrc"
  IP_NUMBER=$((IP_NUMBER + 1))
  IP="${IP_TEMPLATE}${IP_NUMBER}"
  echo "Address $IP" >>"$NODE_DIR/torrc"
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
  cat nodes/da >>"$NODE_DIR/torrc"
  echo "$TORSH_SERVER_CMD" >>"$NODE_DIR/$TORSH_LAUNCHER_NAME"
done

# Append whitelist authority urls to TorSH client launcher config
for this_auth_ip in ${TORSH_WHITELIST_AUTH_IPS[@]}; do
  TORSH_CLIENT_CMD="$TORSH_CLIENT_CMD --whitelist-authority-url $this_auth_ip:$TORSH_WHITELIST_AUTH_PORT"
done
TORSH_CLIENT_CMD="$TORSH_CLIENT_CMD &"

# Relay nodes
# NOTE: TorSH should not have idea of relay nodes, since all clients are also relays!
for i in $(seq $RELAY_NODES); do
  NAME="r$i"
  NODE_DIR="nodes/$NAME"
  create_node "$NAME" "$NODE_DIR"
  cat nodes/da >> "$NODE_DIR/torrc"
done

# Client nodes
for i in $(seq $CLIENT_NODES); do
  NAME="c$i"
  NODE_DIR="nodes/$NAME"
  create_node "$NAME" "$NODE_DIR"
  cat nodes/da >> "$NODE_DIR/torrc"
  echo "SOCKSPort 9050" >> "$NODE_DIR/torrc"
  echo "$TORSH_CLIENT_CMD" >> "$NODE_DIR/$TORSH_LAUNCHER_NAME"
done

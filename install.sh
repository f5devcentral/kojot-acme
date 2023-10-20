#!/usr/bin/env bash

# Simple Dehydrated Acme (F5 BIG-IP) - Install Utility
# Maintainer: kevin-at-f5-dot-com
# Version: 20231013-1
# Description: Wrapper for Dehydrated Acme client to simplify usage on F5 BIG-IP
#
# Usage:
# - Execute: curl -s https://raw.githubusercontent.com/f5devcentral/kojot-acme/install.sh | bash


## Set download paths
ACMECLIENT_URL="https://raw.githubusercontent.com/dehydrated-io/dehydrated/master"
F5ACMEHANDLER_URL="https://raw.githubusercontent.com/f5devcentral/kojot-acme/main"
INSTALL_DIR="/shared/acme"


# Ensure the installation directory exists
mkdir -p "$INSTALL_DIR"

# Download and install Dehydrated Acme client
curl -s ${ACMECLIENT_URL}/dehydrated -o "${INSTALL_DIR}/dehydrated" && chmod +x "${INSTALL_DIR}/dehydrated"

# Download and install F5 Acme handler scripts
curl -s ${F5ACMEHANDLER_URL}/f5acmehandler.sh -o "${INSTALL_DIR}/f5acmehandler.sh" && chmod +x "${INSTALL_DIR}/f5acmehandler.sh"
curl -s ${F5ACMEHANDLER_URL}/f5hook.sh -o "${INSTALL_DIR}/f5hook.sh" && chmod +x "${INSTALL_DIR}/f5hook.sh"
curl -s ${F5ACMEHANDLER_URL}/config -o "${INSTALL_DIR}/config"
curl -s ${F5ACMEHANDLER_URL}/config -o "${INSTALL_DIR}/config_reporting"


## Create BIG-IP data groups (dg_acme_challenge, dg_acme_config)
tmsh create ltm data-group internal dg_acme_challenge type string > /dev/null 2>&1
tmsh create ltm data-group internal dg_acme_config type string > /dev/null 2>&1


## Create BIG-IP iRule (acme_handler_rule)
tmsh load sys config verify file acme.rule merge > /dev/null 2>&1
(($? != 0)) && { printf '%s\n' "ACME irule verification command failed with non-zero"; exit 1; }
tmsh load sys config file acme.rule merge > /dev/null 2>&1
(($? != 0)) && { printf '%s\n' "ACME irule load command failed with non-zero"; exit 1; }

# Copy ca-bundle.crt to the working directory
cp "$(tmsh list sys file ssl-cert ca-bundle.crt -hidden | grep cache-path | sed -E 's/^\s+cache-path\s//')" "${INSTALL_DIR}/ca-bundle.crt"

# Create the log file
touch /var/log/acmehandler

echo "Installation completed successfully."
exit 0

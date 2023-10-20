#!/usr/bin/env bash

## Simple Dehydrated Acme (F5 BIG-IP) - Uninstall Utility
## Maintainer: kevin-at-f5-dot-com
## Version: 20231013-1
## Description: Uninstall wrapper for Dehydrated Acme client and all components
##
## Usage:
## - Execute: curl -s https://raw.githubusercontent.com/f5devcentral/kojot-acme/uninstall.sh | bash


# Function to delete a resource if it exists
delete_resource() {
    local resource="$1"
    tmsh delete "$resource" > /dev/null 2>&1
}

# Function to delete a directory and all its contents
delete_directory() {
    local directory="$1"
    rm -rf "$directory" > /dev/null 2>&1
}

# Delete log file
rm -f /var/log/acmehandler > /dev/null 2>&1

# Delete config data group (challenge data group referenced by acme iRule, also not deleted)
delete_resource "ltm data-group internal dg_acme_config"

# Delete iFiles
delete_resource "sys file ifile f5_acme_account_state"
delete_resource "sys file ifile f5_acme_config_state"

# Delete /shared/acme folder and all contents
delete_directory "/shared/acme"

echo "Uninstallation completed successfully."
exit 0

#!/usr/bin/env bash

## Simple Dehydrated Acme (F5 BIG-IP) - Uninstall Utility
## Maintainer: kevin-at-f5-dot-com
## Version: 20231013-1
## Description: Uninstall wrapper for Dehydrated Acme client and all components
##
## Usage:
## - Execute: curl -s https://<this-repo-url>/uninstall.sh | bash


## Delete log file
rm -f /var/log/acmehandler > /dev/null 2>&1


## Delete config data group (challenge data group referenced by acme iRule, also not deleted)
tmsh delete ltm data-group internal dg_acme_config > /dev/null 2>&1


## Delete iFiles
tmsh delete sys file ifile f5_acme_account_state > /dev/null 2>&1
tmsh delete sys file ifile f5_acme_config_state > /dev/null 2>&1


## Delete /shared/acme folder and all contents
rm -rf /shared/acme > /dev/null 2>&1

return 0

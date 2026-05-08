#!/usr/bin/env bash
## F5 BIG-IP ACME Device Hook Script
## Maintainer: kevin-at-f5-dot-com
## Version: 20260508-1
## Description: Hook script called from the deploy_cert function in f5hook.sh to be used to copy a new ACME certificate
##  and key to some location in the control plane, to support device certificate renewal. This script serves as a template.
##  The actual copy implementation must be derived by the administrator.

## Ref: https://my.f5.com/manage/s/article/K54213074

f5_devicehook_main() {
    local CERTOBJ=$1
    local_cert=$(tmsh list sys file ssl-cert ${CERTOBJ} -hidden | grep cache-path | sed -E 's/^\s+cache-path\s//')
    local_key=$(tmsh list sys file ssl-key ${CERTOBJ} -hidden | grep cache-path | sed -E 's/^\s+cache-path\s//')

    ## Check that the local_cert and local_key values are present
    if [[ ( -z "${local_cert}" ) || ( -z "${local_key}" ) ]]; then
        echo "Certificate and/or key file is missing. Aborting"
        exit 1
    fi

    ## Use this section to push the local_cert and local_key to different device certificate paths
    # echo "$local_cert"
    # echo "$local_key"



}

f5_devicehook_main "${@:-}"
exit 0

#!/usr/bin/env bash

## F5 BIG-IP ACME Client (Dehydrated) Hook Script
## Maintainer: kevin-at-f5-dot-com
## Version: 20250509-1
## Description: ACME client hook script used for staging ACME http-01 challenge response, then cleanup



## ================================================== ##
## FUNCTIONS ======================================== ##
## ================================================== ##

## Function: process_config_file --> source values from the default or a defined config file
process_config_file() {
    ## Set default values
    export FULLCHAIN=true
    export ZEROCYCLE=3
    export CREATEPROFILE=false
    export DNS_DELAY=10
    export tmp=""

    . "${CONFIG}"
}


## Function: process_errors --> print error and debug logs to the log file
process_errors () {
   local ERR="${1}"
   VERBOSE="yes"
   timestamp=$(date +%F_%T)
   if [[ "$ERR" =~ ^"ERROR" && "$ERRORLOG" == "true" ]]; then echo -e ">> [${timestamp}]  ${ERR}" >> ${LOGFILE}; fi
   if [[ "$ERR" =~ ^"DEBUG" && "$DEBUGLOG" == "true" ]]; then echo -e ">> [${timestamp}]  ${ERR}" >> ${LOGFILE}; fi
   if [[ "$ERR" =~ ^"PANIC" ]]; then echo -e ">> [${timestamp}]  ${ERR}" >> ${LOGFILE}; fi
   if [[ "$VERBOSE" == "yes" ]]; then echo -e ">> [${timestamp}]  ${ERR}"; fi
}


## Function: startup_hook --> called by ACME client when ACME protocol challenge starts
startup_hook() {
    process_errors "DEBUG (hook function: startup_hook)\n"
}


## Function: deploy_challenge --> called by ACME client to insert token into dg_acme_challenge data group for ACME server http-01 challenge
deploy_challenge() {
    local DOMAIN="${1}" TOKEN_FILENAME="${2}" TOKEN_VALUE="${3}"
    process_errors "DEBUG (hook function: deploy_challenge)\n   DOMAIN=${DOMAIN}\n   TOKEN_FILENAME=${TOKEN_FILENAME}\n   TOKEN_VALUE=${TOKEN_VALUE}\n"

    if [ "${ACME_METHOD}" == "http-01" ]
    then
        ## HTTP-01 method defined --> Add a record to the data group
        process_errors "DEBUG (hook function: deploy_challenge) -- http-01 access-method\n"            
        tmsh modify ltm data-group internal dg_acme_challenge records add { \"${TOKEN_FILENAME}\" { data \"${TOKEN_VALUE}\" } }

    elif [[ "${ACME_METHOD}" == "dns-01" && "${DNS_2_PHASE}" == "false" ]]
    then
        ## DNS-01 method defined --> Call DNS-API script to deploy TXT record
        process_errors "DEBUG (hook function: deploy_challenge) -- dns-01 access-method\n"
        if [[ ! -f "${ACMEDIR}/dnsapi/${DNSAPI}.sh" ]]
        then
            process_errors "PANIC: Specified DNS API script does not exist: ${ACMEDIR}/${DNSAPI}.sh\n"
            return 1
        else
            source "${ACMEDIR}/dnsapi/${DNSAPI}.sh"
            "${DNSAPI}_add" "_acme-challenge.${DOMAIN}" "${TOKEN_VALUE}"
        fi

    elif [[ "${ACME_METHOD}" == "dns-01" && "${DNS_2_PHASE}" == "true" ]]
    then
        ## Check if in interactive shell - 2-phase DNS requires this
        if [[ "${INTERACTIVE}" != "true" ]]
        then
            process_errors "PANIC: 2-Phase Manual DNS specified but not in an interactive shell. Quiting.\n"
            exit 1
        else
            msg1="... 2-Phase Manual DNS - Phase 1 (deploy)\n" 
            msg2="... Manually update DNS and add a TXT record for: \"_acme-challenge.${DOMAIN}\" with value of: \"${TOKEN_VALUE}\"\n\n"
            msg3="... Press the Enter key to continue...\n"
            set -eu -o pipefail
            echo -e ${msg1}${msg2}${msg3} > /dev/tty
            read -e < /dev/tty
        fi

    else
        ## Exit and log error on unknown method
        process_errors "DEBUG (hook function: deploy_challenge) -- unknown access-method\n"
        process_errors "ERROR: Unknown ACME method defined: ${ACME_METHOD}\n"
        return 1
    fi
}


## Function: clean_challenge --> called by ACME client to remove the ephemeral data group entry when the http-01 challenge is complete
clean_challenge() {
    ## Delete the record from the data group
    local DOMAIN="${1}" TOKEN_FILENAME="${2}" TOKEN_VALUE="${3}"
    process_errors "DEBUG (hook function: clean_challenge)\n   DOMAIN=${DOMAIN}\n   TOKEN_FILENAME=${TOKEN_FILENAME}\n   TOKEN_VALUE=${TOKEN_VALUE}\n"
    if [ "${ACME_METHOD}" == "http-01" ]
    then
        ## HTTP-01 method defined --> Add a record to the data group
        process_errors "DEBUG (hook function: deploy_challenge) -- http-01 access-method\n"   
        tmsh modify ltm data-group internal dg_acme_challenge records delete { \"${TOKEN_FILENAME}\" }

    elif [[ "${ACME_METHOD}" == "dns-01" && "${DNS_2_PHASE}" == "false" ]]
    then
        process_errors "DEBUG (hook function: deploy_challenge) -- sleeping $DNS_DELAY seconds\n"
        sleep $DNS_DELAY

        ## DNS-01 method defined --> Call DNS-API script to deploy TXT record
        process_errors "DEBUG (hook function: deploy_challenge) -- dns-01 access-method\n"
        if [[ ! -f "${ACMEDIR}/dnsapi/${DNSAPI}.sh" ]]
        then
            process_errors "PANIC: Specified DNS API script does not exist: ${ACMEDIR}/${DNSAPI}.sh\n"
            return 1
        else
            source "${ACMEDIR}/dnsapi/${DNSAPI}.sh"
            "${DNSAPI}_rm" "_acme-challenge.${DOMAIN}" "${TOKEN_VALUE}"
        fi

    elif [[ "${ACME_METHOD}" == "dns-01" && "${DNS_2_PHASE}" == "true" ]]
    then
        set -eu -o pipefail
        echo -n "... 2-Phase Manual DNS - Phase 2 (clean): Manually delete DNS and then press any key to continue..." > /dev/tty
        read -e < /dev/tty

    else
        ## Exit and log error on unknown method
        process_errors "DEBUG (hook function: deploy_challenge) -- unknown access-method\n"
        process_errors "ERROR: Unknown ACME method defined: ${ACME_METHOD}\n"
        return 1
    fi
}


## Function deploy_cert --> called by ACME client to install/replace the renewed certificate and private key on the BIG-IP
deploy_cert() {
    ## Import new cert and key
    local DOMAIN="${1}" KEYFILE="${2}" CERTFILE="${3}" FULLCHAINFILE="${4}" CHAINFILE="${5}" TIMESTAMP="${6}"
    process_errors "DEBUG (hook function: deploy_cert)\n   DOMAIN=${DOMAIN}\n   KEYFILE=${KEYFILE}\n   CERTFILE=${CERTFILE}\n   FULLCHAINFILE=${FULLCHAINFILE}\n   CHAINFILE=${CHAINFILE}\n   TIMESTAMP=${TIMESTAMP}\n"
    
    # ALIAS is a directory name
    ALIAS="$(echo ${KEYFILE} | awk -F\/ '{ print $(NF-1) }')"

    ## Test if cert and key exist
    key=true && [[ "$(tmsh list sys file ssl-key ${ALIAS} 2>&1)" =~ "was not found" ]] && key=false
    cert=true && [[ "$(tmsh list sys file ssl-cert ${ALIAS} 2>&1)" =~ "was not found" ]] && cert=false

    if ($key && $cert)
    then
        if [[ "${FULLCHAIN}" == "true" ]]
        then
            ## Create transaction to update existing cert and key
            process_errors "DEBUG (hook function: deploy_cert -> Updating existing cert and key)\n"
            echo "    Updating existing cert and key." >> ${REPORT}
            (echo create cli transaction
            echo install sys crypto key ${ALIAS} from-local-file ${ACMEDIR}/certs/${ALIAS}/privkey.pem
             echo install sys crypto cert ${ALIAS} from-local-file ${ACMEDIR}/certs/${ALIAS}/fullchain.pem
            echo submit cli transaction
            ) | tmsh
        else
            ## Create transaction to update existing cert and key
            process_errors "DEBUG (hook function: deploy_cert -> Updating existing cert and key)\n"
            echo "    Updating existing cert and key." >> ${REPORT}
            (echo create cli transaction
            echo install sys crypto key ${ALIAS} from-local-file ${ACMEDIR}/certs/${ALIAS}/privkey.pem
            echo install sys crypto cert ${ALIAS} from-local-file ${ACMEDIR}/certs/${ALIAS}/cert.pem
            echo submit cli transaction
            ) | tmsh
        fi
    else
        if [[ "${FULLCHAIN}" == "true" ]]
        then
            ## Create cert and key
            process_errors "DEBUG (hook function: deploy_cert -> Installing new cert and key)\n"
            echo "    Installing new cert and key." >> ${REPORT}
            tmsh install sys crypto key ${ALIAS} from-local-file ${ACMEDIR}/certs/${ALIAS}/privkey.pem
            tmsh install sys crypto cert ${ALIAS} from-local-file ${ACMEDIR}/certs/${ALIAS}/fullchain.pem
        else
            process_errors "DEBUG (hook function: deploy_cert -> Installing new cert and key)\n"
            echo "    Installing new cert and key." >> ${REPORT}
            tmsh install sys crypto key ${ALIAS} from-local-file ${ACMEDIR}/certs/${ALIAS}/privkey.pem
            tmsh install sys crypto cert ${ALIAS} from-local-file ${ACMEDIR}/certs/${ALIAS}/cert.pem
        fi
    fi

    ## Clean up and zeroize local storage (via shred)
    cd ${ACMEDIR}/certs/${ALIAS}
    find . -type f -print0 | xargs -0 shred -fuz -n ${ZEROCYCLE}
    cd ${ACMEDIR}/
    rm -rf ${ACMEDIR}/certs/${ALIAS}/


    ## Test if corresponding clientssl profile exists
    if ($CREATEPROFILE)
    then
        clientssl=true && [[ "$(tmsh list ltm profile client-ssl "${ALIAS}_clientssl" 2>&1)" =~ "was not found" ]] && clientssl=false

        if [[ $clientssl == "false" ]]
        then
            ## Create the clientssl profile
            tmsh create ltm profile client-ssl "${ALIAS}_clientssl" cert-key-chain replace-all-with { ${ALIAS} { key ${ALIAS} cert ${ALIAS} } }
        fi
    fi
}


## Function: sync_cert --> called by ACME client, waits for hook script to sync the files before creating the symlinks
sync_cert() {
    local KEYFILE="${1}" CERTFILE="${2}" FULLCHAINFILE="${3}" CHAINFILE="${4}" REQUESTFILE="${5}"
    process_errors "DEBUG (hook function: sync_cert)\n   KEYFILE=${KEYFILE}\n   CERTFILE=${CERTFILE}\n   FULLCHAINFILE=${FULLCHAINFILE}\n   CHAINFILE=${CHAINFILE}\n   REQUESTFILE=${REQUESTFILE}\n"
}


## Function: deploy_ocsp --> called by ACME client...
deploy_ocsp() {
    local DOMAIN="${1}" OCSPFILE="${2}" TIMESTAMP="${3}"
    process_errors "DEBUG (hook function: deploy_ocsp)\n   DOMAIN=${DOMAIN}\n   OCSPFILE=${OCSPFILE}\n   TIMESTAMP=${TIMESTAMP}\n"
}


## Function: unchanged_cert --> called by ACME client, check expire date of existing certificate
unchanged_cert() {
    local DOMAIN="${1}" KEYFILE="${2}" CERTFILE="${3}" FULLCHAINFILE="${4}" CHAINFILE="${5}"
    process_errors "DEBUG (hook function: unchanged_cert)\n   DOMAIN=${DOMAIN}\n   KEYFILE=${KEYFILE}\n   CERTFILE=${CERTFILE}\n   FULLCHAINFILE=${FULLCHAINFILE}\n   CHAINFILE=${CHAINFILE}\n"
}


## Function: invalid_challenge --> called by ACME client, triggered when the challenge request status has failed (is invalid)
invalid_challenge() {
    local DOMAIN="${1}" RESPONSE="${2}"
    process_errors "DEBUG (hook function: invalid_challenge)\n   DOMAIN=${DOMAIN}\n   RESPONSE=${RESPONSE}\n"
}


## Function: request_failure --> called by ACME client...
request_failure() {
    local STATUSCODE="${1}" REASON="${2}" REQTYPE="${3}" HEADERS="${4}"
    process_errors "DEBUG (hook function: request_failure)\n   STATUSCODE=${STATUSCODE}\n   REASON=${REASON}\n   REQTYPE=${REQTYPE}\n   HEADERS=${HEADERS}\n"
}


## Function: generate_csr --> called by ACME client, triggered when an external CSR is passed in
generate_csr() {
    local DOMAIN="${1}" CERTDIR="${2}" ALTNAMES="${3}"
    process_errors "DEBUG (hook function: generate_csr)\n   DOMAIN={DOMAIN}\n   CERTDIR=${CERTDIR}\n   ALTNAMES=${ALTNAMES}\n"
}


## Function: exit_hook --> called by ACME client when ACME challenge process is complete
exit_hook() {
    local ERROR="${1:-}"
    process_errors "DEBUG (hook function: exit_hook)\n   ERROR=${ERROR}\n"
}



## Script processing starts here

## Read the config file
process_config_file

## Read command argument and call requested function
HANDLER="$1"; shift
if [[ "${HANDLER}" =~ ^(deploy_challenge|clean_challenge|sync_cert|deploy_cert|deploy_ocsp|unchanged_cert|invalid_challenge|request_failure|generate_csr|startup_hook|exit_hook)$ ]]; then
    "$HANDLER" "$@"
fi

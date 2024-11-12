#!/usr/bin/env bash

## F5 BIG-IP ACME Client (Dehydrated) Handler Utility
## Maintainer: kevin-at-f5-dot-com
## Version: 20231206-1
## Description: Wrapper utility script for Dehydrated ACME client
## 
## Configuration and installation: 
##    - Install: curl -s https://raw.githubusercontent.com/kevingstewart/f5acmehandler-bash/main/install.sh | bash
##    - Update global config data group (dg_acme_config) - [domain] := --ca [acme-provider-url] [--config [config-path]]
##        www.foo.com := --ca https://acme-v02.api.letsencrypt.org/directory
##        www.bar.com := --ca https://acme.zerossl.com/v2/DV90 --config /shared/acme/config_www_example_com
##        www.baz.com := --ca https://acme.locallab.com:9000/directory -a rsa
##    - Update client config file (/shared/acme/config), and/or create new config files per provider as needed (name must start with "config")
##    - Create HTTP VIPs to match corresponding HTTPS VIPs, and attach iRule (acme_handler_rule)
##    - Perform an initial fetch: cd /shared/acme && ./f5acmehandler.sh
##    - Set a cron-based schedule: cd /shared/acme && ./f5acmehandler.sh --schedule "00 04 * * 1"


## PLEASE DO NOT EDIT THIS SCRIPT ##


## ================================================== ##
## FUNCTIONS ======================================== ##
## ================================================== ##

## Static processing variables - do not touch
ACMEDIR=/shared/acme
STANDARD_OPTIONS="-x -k ${ACMEDIR}/f5hook.sh -t http-01"
REGISTER_OPTIONS="--register --accept-terms"
LOGFILE=/var/log/acmehandler
FORCERENEW="no"
SINGLEDOMAIN=""
VERBOSE="no"
ACCTSTATEEXISTS="no"
CONFSTATEEXISTS="no"
THISCONFIG=""
SAVECONFIG="no"
ENABLE_REPORTING=false
FORCE_SYNC=false
DEVICE_GROUP=""
MAILHUB=""
USESTARTTLS=no
USETLS=no
AUTHUSER=""
AUTHPASS=""
TLS_CA_FILE=""
REPORT_FROM=""
REPORT_TO=""
REPORT_SUBJECT=""
FROMLINEOVERRIDE=no
REPORT=""
HASCHANGED="false"


## Function: process_errors --> print error and debug logs to the log file
process_errors () {
   local ERR="${1}"
   timestamp=$(date +%F_%T)
   if [[ "$ERR" =~ ^"ERROR" && "$ERRORLOG" == "true" ]]; then echo -e ">> [${timestamp}]  ${ERR}" >> ${LOGFILE}; fi
   if [[ "$ERR" =~ ^"DEBUG" && "$DEBUGLOG" == "true" ]]; then echo -e ">> [${timestamp}]  ${ERR}" >> ${LOGFILE}; fi
   if [[ "$ERR" =~ ^"PANIC" ]]; then echo -e ">> [${timestamp}]  ${ERR}" >> ${LOGFILE}; fi
   if [[ "$VERBOSE" == "yes" ]]; then echo -e ">> [${timestamp}]  ${ERR}"; fi
}


## Function: process_report --> generate and send report via SMTP (requires)
process_report () {
   local TMPREPORT="${1}"

   ## Only process reporting if config_reporting file exists and ENABLE_REPORTING is true
   if [[ -f "${ACMEDIR}/config_reporting" ]]
   then
      . "${ACMEDIR}/config_reporting"
      if [[ "$ENABLE_REPORTING" == "true" ]]
      then
         # echo -e "From: ${REPORT_FROM}\nSubject: ${REPORT_SUBJECT}\n\n$(echo -e $(cat ${TMPREPORT})\n\n)"
         echo -e "From: ${REPORT_FROM}\nSubject: ${REPORT_SUBJECT}\n\n$(echo -e $(cat ${TMPREPORT}))" | ssmtp -C "${ACMEDIR}/config_reporting" "${REPORT_TO}"
      fi   
   fi
}


## Function: process_base64_decode --> performs base64 decode addressing any erroneous padding in input
process_base64_decode() {
   # local INPUT="${1}"
   # echo "$INPUT"==== | fold -w 4 | sed '$ d' | tr -d '\n' | base64 --decode
   echo "${1}"==== | fold -w 4 | sed '$ d' | tr -d '\n' | base64 --decode
}


## Function: process_config_file --> source values from the default or a defined config file
process_config_file() {
   local COMMAND="${1}"
      
   ## Set default values
   THRESHOLD=30
   ALWAYS_GENERATE_KEY=false
   FULLCHAIN=true
   ERRORLOG=true
   DEBUGLOG=false
   CHECK_REVOCATION=false

   ## Extract --config value and read config values
   if [[ "$COMMAND" =~ "--config " ]]; then COMMAND_CONFIG=$(echo "$COMMAND" | sed -E 's/.*(--config+\s[^[:space:]]+).*/\1/g;s/"//g'); else COMMAND_CONFIG=""; fi
   if [[ "$COMMAND_CONFIG" == "" ]]
   then
      ## No config specified --> source from the default config file
      . "${ACMEDIR}/config"

      ## Test if WELLKNOWN entry are included in file, add if missing
      if ! grep -q "WELLKNOWN=" "${ACMEDIR}/config"
      then 
         echo "WELLKNOWN=\"/tmp/wellknown\"" >> "${ACMEDIR}/config"
      fi
      ## Test if HOOK entry are included in file, add if missing
      if ! grep -q "HOOK=" "${ACMEDIR}/config"
      then 
         echo "HOOK=\"\${BASEDIR}/f5hook.sh\"" >> "${ACMEDIR}/config"
      fi
   else
      ## Alternate config specified --> source from this alternate config file
      THIS_COMMAND_CONFIG=$(echo ${COMMAND_CONFIG} | sed -E 's/--config //')
      if [[ ! -f "${THIS_COMMAND_CONFIG}" ]]
      then
         process_errors "PANIC: Specified config file for (${DOMAIN}) does not exist (${THIS_COMMAND_CONFIG})\n"
         echo "    PANIC: Specified config file for (${DOMAIN}) does not exist (${THIS_COMMAND_CONFIG})." >> ${REPORT}
         continue
      else
         . "${THIS_COMMAND_CONFIG}"
      fi

      ## Test if WELLKNOWN entry are included in file, add if missing
      if ! grep -q "WELLKNOWN=" "${THIS_COMMAND_CONFIG}"
      then 
         echo "WELLKNOWN=\"/tmp/wellknown\"" >> "${THIS_COMMAND_CONFIG}"
      fi
      ## Test if HOOK entry are included in file, add if missing
      if ! grep -q "HOOK=" "${THIS_COMMAND_CONFIG}"
      then 
         echo "HOOK=\"\${BASEDIR}/f5hook.sh\"" >> "${THIS_COMMAND_CONFIG}"
      fi
   fi
}


## Function: (handler) generate_new_cert_key
## This function triggers the ACME client directly, which then calls the configured hook script to assist 
## in auto-generating a new certificate and private key. The hook script then installs the cert/key if not
## present, or updates the existing cert/key via TMSH transaction.
generate_new_cert_key() {
   local DOMAIN="${1}" COMMAND="${2}"
   process_errors "DEBUG (handler function: generate_new_cert_key)\n   DOMAIN=${DOMAIN}\n   COMMAND=${COMMAND}\n"

   ## Trigger ACME client. All BIG-IP certificate management is then handled by the hook script
   cmd="${ACMEDIR}/dehydrated ${STANDARD_OPTIONS} -c -g -d ${DOMAIN} $(echo ${COMMAND} | tr -d '"')"
   process_errors "DEBUG (handler: ACME client command):\n$cmd\n"
   do=$(REPORT=${REPORT} eval $cmd 2>&1 | cat | sed 's/^/    /')
   process_errors "DEBUG (handler: ACME client output):\n$do\n"

   ## Catch connectivity errors
   if [[ $do =~ "ERROR: Problem connecting to server" ]]
   then
      process_errors "PANIC: Connectivity error for (${DOMAIN}). Please verify configuration (${COMMAND}).\n\n"
      echo "    PANIC: Connectivity error for (${DOMAIN}). Please verify configuration (${COMMAND})." >> ${REPORT}
      continue
   fi
}


## Function: (handler) generate_cert_from_csr
## This function triggers a CSR creation via TMSH, collects and passes the CSR to the ACME client, then collects
## the renewed certificate and replaces the existing certificate via TMSH transaction.
generate_cert_from_csr() {
   local DOMAIN="${1}" COMMAND="${2}"
   process_errors "DEBUG (handler function: generate_cert_from_csr)\n   DOMAIN=${DOMAIN}\n   COMMAND=${COMMAND}\n"

   ## Fetch existing subject-alternative-name (SAN) values from the certificate
   certsan=$(tmsh list sys crypto cert ${DOMAIN} | grep subject-alternative-name | awk '{$1=$1}1' | sed 's/subject-alternative-name//' | sed 's/IP Address:/IP:/')
   ## If certsan is empty, assign the domain/CN value
   if [ -z "$certsan" ]
   then
      certsan="DNS:${DOMAIN}"
   fi

   ## Commencing acme renewal process - first delete and recreate a csr for domain (check first to prevent ltm error log message if CSR doesn't exist)
   csrexists=false && [[ "$(tmsh list sys crypto csr ${DOMAIN} 2>&1)" =~ "${DOMAIN}" ]] && csrexists=true
   if ($csrexists)
   then
      tmsh delete sys crypto csr ${DOMAIN} > /dev/null 2>&1
   fi
   tmsh create sys crypto csr ${DOMAIN} common-name ${DOMAIN} subject-alternative-name "${certsan}" key ${DOMAIN}
   
   ## Dump csr to cert.csr in DOMAIN subfolder
   mkdir -p ${ACMEDIR}/certs/${DOMAIN} 2>&1
   tmsh list sys crypto csr ${DOMAIN} |sed -n '/-----BEGIN CERTIFICATE REQUEST-----/,/-----END CERTIFICATE REQUEST-----/p' > ${ACMEDIR}/certs/${DOMAIN}/cert.csr
   process_errors "DEBUG (handler: csr):\n$(cat ${ACMEDIR}/certs/${DOMAIN}/cert.csr | sed 's/^/   /')\n"

   ## Trigger ACME client and dump renewed cert to certs/{domain}/cert.pem
   cmd="${ACMEDIR}/dehydrated ${STANDARD_OPTIONS} -s ${ACMEDIR}/certs/${DOMAIN}/cert.csr $(echo ${COMMAND} | tr -d '"')"
   process_errors "DEBUG (handler: ACME client command):\n   $cmd\n"
   do=$(eval $cmd 2>&1 | cat | sed 's/^/    /')
   process_errors "DEBUG (handler: ACME client output):\n$do\n"

   ## Catch connectivity errors
   if [[ $do =~ "ERROR: Problem connecting to server" ]]
   then
      process_errors "PANIC: Connectivity error for (${DOMAIN}). Please verify configuration (${COMMAND}).\n\n"
      echo "    PANIC: Connectivity error for (${DOMAIN}). Please verify configuration (${COMMAND})." >> ${REPORT}
      continue
   fi

   ## Catch and process returned certificate
   if [[ $do =~ "# CERT #" ]]
   then
      if [[ "${FULLCHAIN}" == "true" ]]
      then
         cat $do 2>&1 | sed -n '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' | sed -E 's/^\s+//g' > ${ACMEDIR}/certs/${DOMAIN}/cert.pem
      else
         cat $do 2>&1 | sed -n '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p;/-END CERTIFICATE-/q' | sed -E 's/^\s+//g' > ${ACMEDIR}/certs/${DOMAIN}/cert.pem
      fi
   else
      process_errors "ERROR: ACME client failure: $do\n"
      return
   fi

   ## Create transaction to update existing cert and key
   (echo create cli transaction
      echo install sys crypto cert ${DOMAIN} from-local-file ${ACMEDIR}/certs/${DOMAIN}/cert.pem
      echo submit cli transaction
   ) | tmsh > /dev/null 2>&1
   process_errors "DEBUG (handler: tmsh transaction) Installed certificate via tmsh transaction\n"
   echo "    Installed certificate via tmsh transaction." >> ${REPORT}

   ## Clean up objects
   tmsh delete sys crypto csr ${DOMAIN}
   rm -rf ${ACMEDIR}/certs/${DOMAIN}
   process_errors "DEBUG (handler: cleanup) Cleaned up CSR and ${DOMAIN} folder\n\n"
}


## Function: process_handler_config --> take dg config string as input and perform cert renewal processes
process_handler_config () {

   ## Split input line into {DOMAIN} and {COMMAND} variables.
   IFS="=" read -r DOMAIN COMMAND <<< $1
   
   ## Pull values from default or defined config file
   process_config_file "$COMMAND"

   if [[ ( ! -z "$SINGLEDOMAIN" ) && ( ! "$SINGLEDOMAIN" == "$DOMAIN" ) ]]
   then
      ## Break out of function if SINGLEDOMAIN is specified and this pass is not for the matching domain
      continue
   else
      process_errors "DEBUG (handler function: process_handler_config)\n   --domain argument specified for ($DOMAIN).\n"
   fi

   echo "\n    Processing for domain: ${DOMAIN}" >> ${REPORT}


   ######################
   ### VALIDATION CHECKS
   ######################

   ## Validation check --> Defined DOMAIN should be syntactically correct
   dom_regex='^([a-zA-Z0-9](([a-zA-Z0-9-]){0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
   if [[ ! "$DOMAIN" =~ $dom_regex ]]
   then
      process_errors "PANIC: Configuration entry ($DOMAIN) is incorrect. Skipping.\n"
      echo "    PANIC: Configuration entry ($DOMAIN) is incorrect. Skipping." >> ${REPORT}
      continue 
   fi

   ## Validation check: Config entry must include "--ca" option
   if [[ ! "$COMMAND" =~ "--ca " ]]
   then
      process_errors "PANIC: Configuration entry for ($DOMAIN) must include a \"--ca\" option. Skipping.\n"
      echo "    PANIC: Configuration entry for ($DOMAIN) must include a \"--ca\" option. Skipping." >> ${REPORT}
      continue 
   fi

   ## Validation check: Defined provider should be registered
   if [[ "$(process_check_registered $COMMAND)" == "notfound" ]]
   then
      process_errors "DEBUG: Defined ACME provider not registered. Registering.\n"
      echo "    Defined ACME provider not registered. Registering." >> ${REPORT}

      ## Extract --ca and --config values
      COMMAND_CA=$(echo "$COMMAND" | sed -E 's/.*(--ca+\s[^[:space:]]+).*/\1/g;s/"//g')
      if [[ "$COMMAND" =~ "--config " ]]; then COMMAND_CONFIG=$(echo "$COMMAND" | sed -E 's/.*(--config+\s[^[:space:]]+).*/\1/g;s/"//g'); else COMMAND_CONFIG=""; fi
      
      ## Handling registration
      cmd="${ACMEDIR}/dehydrated --register --accept-terms ${COMMAND_CA} ${COMMAND_CONFIG}"
      do=$(eval $cmd 2>&1 | cat | sed 's/^/   /')
      process_errors "DEBUG (handler: ACME provider registration):\n$do\n"
   fi


   ## Start logging
   process_errors "DEBUG (handler function: process_handler_config)\n   VAR: DOMAIN=${DOMAIN}\n   VAR: COMMAND=${COMMAND}\n"

   ## Error test: check if cert exists in BIG-IP config
   certexists=true && [[ "$(tmsh list sys crypto cert ${DOMAIN} 2>&1)" == "" ]] && certexists=false

   ## If cert exists or ALWAYS_GENERATE_KEYS is true, call the generate_new_cert_key function
   if [[ "$certexists" == "false" || "$ALWAYS_GENERATE_KEY" == "true" ]]
   then
      process_errors "DEBUG: Certificate does not exist, or ALWAYS_GENERATE_KEY is true --> call generate_new_cert_key.\n"
      echo "    Certificate does not exist, or ALWAYS_GENERATE_KEY is true. Generating a new cert and key." >> ${REPORT}
      HASCHANGED="true"
      generate_new_cert_key "$DOMAIN" "$COMMAND"
   
   elif [[ "$certexists" == "true" && "$CHECK_REVOCATION" == "true" && "$(process_revocation_check "${DOMAIN}")" == "revoked" ]]
   then
      process_errors "DEBUG: Certificate exists, CHECK_REVOCATION is enabled, and revocation check found that (${DOMAIN}) is revoked -- Fetching new certificate and key"
      echo "    Certificate exists, CHECK_REVOCATION is enabled, and revocation check found that (${DOMAIN}) is revoked -- Fetching new certificate and key." >> ${REPORT}
      HASCHANGED="true"
      generate_new_cert_key "$DOMAIN" "$COMMAND"
   
   else
      ## Else call the generate_cert_from_csr function
      process_errors "DEBUG: Certificate exists and ALWAYS_GENERATE_KEY is false --> call generate_cert_from_csr.\n"
      echo "    Certificate exists and ALWAYS_GENERATE_KEY is false --> call generate_cert_from_csr." >> ${REPORT}

      ## Collect today's date and certificate expiration date
      if [[ ! "${FORCERENEW}" == "yes" ]]
      then
         date_cert=$(tmsh list sys crypto cert ${DOMAIN} | grep expiration | awk '{$1=$1}1' | sed 's/expiration //')
         date_cert=$(date -d "$date_cert" "+%Y%m%d")
         date_today=$(date +"%Y%m%d")
         date_test=$(( ($(date -d "$date_cert" +%s) - $(date -d "$date_today" +%s)) / 86400 ))
         process_errors "DEBUG (handler: dates)\n   date_cert=$date_cert\n   date_today=$date_today\n   date_test=$date_test\n"
      else
         date_test=0
         process_errors "DEBUG (handler: dates)\n   --force argument specified, forcing renewal\n"
      fi

      ## If certificate is past the threshold window, initiate renewal
      if [ $THRESHOLD -ge $date_test ]
      then
         process_errors "DEBUG (handler: threshold) THRESHOLD ($THRESHOLD) -ge date_test ($date_test) - Starting renewal process for ${DOMAIN}\n"
         HASCHANGED="true"
         generate_cert_from_csr "$DOMAIN" "$COMMAND"
      else
         process_errors "DEBUG (handler: bypass) Bypassing renewal process for ${DOMAIN} - Certificate within threshold.\n"
         echo "    Bypassing renewal process for ${DOMAIN} - Certificate within threshold." >> ${REPORT}
         #return
      fi
   fi
}


## Function: process_check_registered --> tests for local registration
process_check_registered() {
   local INCOMMAND="${1}"
   account=$(echo "$INCOMMAND" | sed -E 's/.*(--ca+\s[^[:space:]]+).*/\1/g;s/"//g;s/--ca //g' | base64 | sed -E 's/=//g')
   if [[ -d "${ACMEDIR}/accounts/${account}" ]]
   then
      echo "found"
   else
      echo "notfound"
   fi
}


## Function: process_get_configs --> pulls configs from iFile central store into local folder
process_get_configs() {
   ## Only run this on HA systems
   ISHA=$(tmsh show cm sync-status | grep Standalone | wc -l)
   if [[ "${ISHA}" = "0" ]]
   then
      ## ACCOUNTS STATE DATA 
      ## Test if the iFile exists (f5_acme_state) and pull into local folder if it does
      ifileexists=true && [[ "$(tmsh list sys file ifile f5_acme_account_state 2>&1)" =~ "was not found" ]] && ifileexists=false
      if ($ifileexists)
      then
         cat $(tmsh list sys file ifile f5_acme_account_state -hidden | grep cache-path | sed -E 's/^\s+cache-path\s//') | base64 -d | tar xz
         ACCTSTATEEXISTS="yes"
         process_errors "DEBUG Pulling acme account state information from iFile central storage\n"
      else
         ACCTSTATEEXISTS="no"
         process_errors "DEBUG No iFile central account store found - New state data will need to be created locally\n"
      fi
      
      ## Generate checksum on accounts state file (accounts folder)
      # STARTSUM=$(find -type f \( -path "./accounts/*" -o -name "config*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')
      # ACCTSTARTSUM=$(find -type f \( -path "./accounts/*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')
      ACCTSTARTSUM=$(find "${ACMEDIR}/accounts" -type f \( -path "*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')
      
      ## Generate checksum on config state files (config* files)
      # CONFSTARTSUM=$(find -type f \( -name "config*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')
      CONFSTARTSUM=$(find "${ACMEDIR}" -type f \( -name "config*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')


      ## CONFIGS STATE DATA 
      ## Process config files only if --save is specified
      if [[ "${SAVECONFIG}" == "yes" ]]
      then
         ## SAVECONFIG enabled - do not get config state from central store
         process_errors "DEBUG SAVECONFIG enabled - working from local config data\n"
      else
         ## SAVECONFIG not enabled - get the config state from central store
         ## Test if the iFile exists (f5_acme_state) and pull into local folder if it does
         confifileexists=true && [[ "$(tmsh list sys file ifile f5_acme_config_state 2>&1)" =~ "was not found" ]] && confifileexists=false
         if ($confifileexists)
         then
            cat $(tmsh list sys file ifile f5_acme_config_state -hidden | grep cache-path | sed -E 's/^\s+cache-path\s//') | base64 -d | tar xz
            CONFSTATEEXISTS="yes"
            process_errors "DEBUG Pulling acme config state information from iFile central storage\n"
         else
            CONFSTATEEXISTS="no"
            process_errors "DEBUG No iFile central config store found - New state data will need to be created locally\n"
         fi
      fi
   fi
}


## Function: process_put_configs --> pushes local configs to iFile central store
process_put_configs() {
   ## Only run this on HA systems
   if [[ "${ISHA}" = "0" ]]
   then
      ## ACCOUNTS STATE DATA 
      ## Generate checksum on state files (accounts folder)
      # ENDSUM=$(find -type f \( -path "./accounts/*" -o -name "config*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')
      # ACCTENDSUM=$(find -type f \( -path "./accounts/*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')
      ACCTENDSUM=$(find "${ACMEDIR}/accounts" -type f \( -path "*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')

      ## Generate checksum on state files (config files)
      # CONFENDSUM=$(find -type f \( -name "config*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')
      CONFENDSUM=$(find "${ACMEDIR}" -type f \( -name "config*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')

      ## STARTSUM/ENDSUM inequality indicates that changes were made - push state changes to iFile store
      if [[ "$ACCTSTARTSUM" != "$ACCTENDSUM" || "$ACCTSTATEEXISTS" == "no" ]]
      then
         process_errors "DEBUG START/END account checksums are different or iFile state is missing - pushing account state data to iFile central store\n"

         ## Update HASCHANGED flag
         HASCHANGED="true"

         ## First compress and base64-encode the accounts folder and config files
         # tar -czf - accounts/ config* | base64 -w 0 > data.b64
         cd "${ACMEDIR}"
         tar -czf - "./accounts/" | base64 -w 0 > "${ACMEDIR}/accounts.b64"

         ## Test if the iFile exists (f5_acme_account_state)
         ifileexists=true && [[ "$(tmsh list sys file ifile f5_acme_account_state 2>&1)" =~ "was not found" ]] && ifileexists=false
         if ($ifileexists)
         then
            ## iFile exists - update iFile and delete local file
            tmsh modify sys file ifile f5_acme_account_state source-path "file://${ACMEDIR}/accounts.b64"
            rm -f accounts.b64
         else
            ## iFile doesn't exist - create iFile and delete local file
            tmsh create sys file ifile f5_acme_account_state source-path "file://${ACMEDIR}/accounts.b64"
            rm -f accounts.b64
         fi 
      else
         process_errors "DEBUG START/END account checksums detects no changes - not pushing account state data to iFile central store\n"
      fi


      ## CONFIGS STATE DATA 
      if [[ "$CONFSTARTSUM" != "$CONFENDSUM" || "$CONFSTATEEXISTS" == "no" ]]
      then
         process_errors "DEBUG START/END config checksums are different or iFile state is missing - pushing config state data to iFile central store\n"

         ## Update HASCHANGED flag
         HASCHANGED="true"

         ## First compress and base64-encode the accounts folder and config files
         # tar -czf - accounts/ config* | base64 -w 0 > data.b64
         cd "${ACMEDIR}"
         tar -czf - ./config* | base64 -w 0 > "${ACMEDIR}/configs.b64"

         ## Test if the iFile exists (f5_acme_config_state)
         confifileexists=true && [[ "$(tmsh list sys file ifile f5_acme_config_state 2>&1)" =~ "was not found" ]] && confifileexists=false
         if ($confifileexists)
         then
            ## iFile exists - update iFile and delete local file
            tmsh modify sys file ifile f5_acme_config_state source-path "file://${ACMEDIR}/configs.b64"
            rm -f configs.b64
         else
            ## iFile doesn't exist - create iFile and delete local file
            tmsh create sys file ifile f5_acme_config_state source-path "file://${ACMEDIR}/configs.b64"
            rm -f configs.b64
         fi
      else
         process_errors "DEBUG START/END config checksums detects no changes - not pushing config state data to iFile central store\n"
      fi

      if [[ "$HASCHANGED" == "true" && "$FORCE_SYNC" == "true" ]]
      then
         ## The config has changed and FORCE_SYNC is set to true - force an HA sync
         process_errors "DEBUG START/END config checksums are different and FORCE_SYNC is set to true - forcing an HA sync operation\n"
         tmsh run /cm config-sync to-group ${DEVICE_GROUP}
      fi
   fi
}


## Function: process_revocation_check --> consume BIG-IP certificate object name as input and attempt to perform a direct OCSP revocation check
process_revocation_check() {
   ## Fetch PEM certificate from BIG-IP, separate into cert and chain, and get OCSP URI
   local INCERT="${1}"
   FULLCHAIN=$(cat $(tmsh list sys file ssl-cert "$INCERT" all-properties -hidden | grep cache-path | sed -E 's/^\s+cache-path\s//') | sed -n '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p')
   CERT="${FULLCHAIN%%-----END CERTIFICATE-----*}-----END CERTIFICATE-----"
   CHAIN=$(echo -e "${FULLCHAIN#*-----END CERTIFICATE-----}" | sed '/./,$!d')
   OCSPURL=$(echo "$CERT" | openssl x509 -noout -ocsp_uri)

   ## If CERT, CHAIN, and OCSPURL are not empty, attempt to perform OCSP check and return "revoked", "notrevoked", or "unavailable"
   if [[ ! -z "${CERT:-}" && ! -z "${CHAIN:-}" && ! -z "${OCSPURL:-}" ]]
   then
      ## Get hostname from OCSP URI
      OCSPHOST=$(echo $OCSPURL | sed -E 's/^https?:\/\/([^:|\/]+)[:\/]?.*/\1/')
      
      ## Perform revocation check
      revstate=$(openssl ocsp -issuer <(echo "$CHAIN") -cert <(echo "$CERT") -url "${OCSPURL}" -header "HOST" "${OCSPHOST}" -noverify)
      
      ## Test for "revoked" in response
      if [[ "$revstate" =~ "revoked" ]]
      then
         echo "revoked"
      else
         echo "notrevoked"
      fi
   else
      ## Either there's no chain (issuer) for this cert, or no defined OCSP URI --> exit with 'none'
      echo "unavailable"
   fi
   
}


## Function: process_listaccounts --> loop through the accounts folder and print the encoded and decoded values for each registered account
process_listaccounts() {
   printf "\nThe following ACME providers are registered:\n\n"
   for acct in ${ACMEDIR}/accounts/*
   do
      acct_tmp=$(echo $acct | sed -E 's/.*\/accounts\///')
      printf "   PROVIDER: $(process_base64_decode $acct_tmp)\n"
      printf "   LOCATION: ${ACMEDIR}/accounts/$acct_tmp\n\n"
   done
}


## Function: process_schedule --> accept a cron string value and create a crontab entry for this utility
process_schedule() {
   local CRON="${1}"

   ## Validate cron string - currently does a basic structure check (to refine later...)
   testcron=$(echo "$CRON" | sed -E 's/^([[:digit:]\,\-\*\/]+)\s([[:digit:]\,\-\*\/]+)\s([[:digit:]\,\-\*\/]+)\s([[:digit:]\,\-\*\/]+)\s([[:digit:]\,\-\*\/]+)$/match/g')
   if [[ "$testcron" == "match" ]]
   then
      ## Presumably correct cron string entered --> add to crontab

      ## Get current user
      myuser=$(whoami)

      ## Clear out any existing script entry
      crontab -l |grep -v f5acmehandler | crontab

      ## Write entry to bottom of the file
      echo "${CRON} ${ACMEDIR}/f5acmehandler.sh" >> /var/spool/cron/${myuser}

      printf "\nThe f5acmehandler script has been scheduled. Current crontab:\n\n"
      crontab -l | sed 's/^/   /'
      printf "\n\n"

   else
      printf "\nERROR: Please correct the format of supplied cron string. No schedule applied.\n\n"
   fi
}


## Function: process_uninstall --> uninstall the crontab entry
process_uninstall() {
   ## Clear out any existing script entry
   crontab -l |grep -v f5acmehandler | crontab
}


## Function: process_handler_main --> loop through config data group and pass DOMAIN and COMMAND values to client handlers
process_handler_main() {
   ## Test for and only run on active BIG-IP
   ACTIVE=$(tmsh show cm failover-status | grep ACTIVE | wc -l)
   if [[ "${ACTIVE}" = "1" ]]
   then
      echo "\n  Processing renewals:" >> ${REPORT}

      ## Call process_get_configs to retrieve centrally stored iFile state data into the local folder
      process_get_configs

      ## Create wellknown folder
      mkdir -p /tmp/wellknown > /dev/null 2>&1
      
      ## Read from the config data group and loop through keys:values
      config=true && [[ "$(tmsh list ltm data-group internal dg_acme_config 2>&1)" =~ "was not found" ]] && config=false
      if ($config)
      then
         IFS=";" && for v in $(tmsh list ltm data-group internal dg_acme_config one-line | sed -e 's/ltm data-group internal dg_acme_config { records { //;s/ \} type string \}//;s/ { data /=/g;s/ \} /;/g;s/ \}//'); do process_handler_config $v; done
      else
         process_errors "PANIC: There was an error accessing the dg_acme_config data group. Please re-install.\n"
         echo "    PANIC: There was an error accessing the dg_acme_config data group" >> ${REPORT}
         exit 1
      fi

      ## Call process_put_configs to push local state data into central iFile store
      process_put_configs

      process_report "${REPORT}"
      # echo -e "$(cat ${REPORT})"
   fi
   return 0
}


## Function: command_help --> display help information in stdout
## Usage: --help
command_help() {
  printf "\nUsage: %s [--help]\n"
  printf "Usage: %s [--force] [--domain <domain>]\n"
  printf "Usage: %s [--listaccounts]\n"
  printf "Usage: %s [--schedule <cron>]\n"
  printf "Usage: %s [--testrevocation <domain>]\n"
  printf "Usage: %s [--uninstall]\n"
  printf "Usage: %s [--save]\n"
  printf "Usage: %s [--verbose]\n\n"
  printf "Default (no arguments): renewal operations\n"
  printf -- "\nParameters:\n"
  printf " --help:\t\t\tPrint this help information\n"
  printf " --force:\t\t\tForce renewal (override data checks)\n"
  printf " --domain <domain>:\t\tRenew a single domain (ex. --domain www.f5labs.com)\n"
  printf " --listaccounts:\t\tPrint a list of all registered ACME providers\n"
  printf " --schedule <cron>:\t\tInstall/update the scheduler. See REPO for scheduling instructions\n"
  printf " --testrevocation <domain>:\tAttempt to performs an OCSP revocation check on an existing certificate (domain)\n"
  printf " --uninstall:\t\t\tUninstall the scheduler\n"
  printf " --save:\t\t\tSave the local config to HA central store (only for HA)\n"
  printf " --verbose:\t\t\tDump verbose output to stdout\n\n\n"
}


## Function: main --> process command line arguments
main() {
   while (( ${#} )); do
      case "${1}" in
         --help)
           command_help >&2
           exit 0
           ;;

         --listaccounts)
           process_listaccounts
           exit 0
           ;;

         --schedule)
           shift 1
           if [[ -z "${1:-}" ]]; then
             printf "\nThe specified command requires an additional parameter. Please see --help:" >&2
             echo >&2
             command_help >&2
             exit 1
           fi
           process_schedule "${1}"
           exit 0
           ;;

         --uninstall)
           process_uninstall
           exit 0
           ;;

         --testrevocation)
           shift 1
           if [[ -z "${1:-}" ]]; then
             printf "\nThe specified command requires an additional parameter. Please see --help:" >&2
             echo >&2
             command_help >&2
             exit 1
           fi
           process_revocation_check "${1}"
           exit 0
           ;;

         --force)
           echo "  Command Line Option Specified: --force" >> ${REPORT}
           FORCERENEW="yes"
           ;;

         --save)
           echo "  Command Line Option Specified: --save" >> ${REPORT} 
           SAVECONFIG="yes"
           ;;

         --verbose)
           echo "  Command Line Option Specified: --verbose" >> ${REPORT}
           VERBOSE="yes"
           ;;

         --domain)
           shift 1
           if [[ -z "${1:-}" ]]; then
             printf "\nThe specified command requires additional an parameter. Please see --help:" >&2
             echo >&2
             command_help >&2
             exit 1
           fi
           echo "  Command Line Option Specified: --domain ${1}" >> ${REPORT}
           SINGLEDOMAIN="${1}"
           ;;

         *)
           process_errors "DEBUG (handler function: main)\n   Launching default renew operations\n"
           ;;
      esac
   shift 1
   done

   ## Call main function
   process_handler_main
}


## Script entry
REPORT=$(mktemp)
echo "ACMEv2 Renewal Report: $(date)\n\n" > ${REPORT}
main "${@:-}"








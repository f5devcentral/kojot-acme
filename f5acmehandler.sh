#!/usr/bin/env bash

## F5 BIG-IP ACME Client (Dehydrated) Handler Utility
## Maintainer: kevin-at-f5-dot-com
## Version: 20251020-1
## Description: Wrapper utility script for Dehydrated ACME client
## 
## Configuration and installation: 
##    - Install: curl -s https://raw.githubusercontent.com/kevingstewart/f5acmehandler-bash/main/install.sh | bash
##    - Update global config data group (dg_acme_config) - [domain] := --ca [acme-provider-url] [--config [config-path]]
##        www.foo.com := --ca https://acme-v02.api.letsencrypt.org/directory
##        www.bar.com := --ca https://acme.zerossl.com/v2/DV90 --config /shared/acme/config_www_example_com
##        www.baz.com := --ca https://acme.locallab.com:9000/directory -a rsa
##    - Update client config file (/shared/acme/config), and/or create new config files per provider as needed (name must start with "config_")
##    - Create HTTP VIPs to match corresponding HTTPS VIPs, and attach iRule (acme_handler_rule)
##    - Perform an initial fetch: cd /shared/acme && ./f5acmehandler.sh
##    - Set a cron-based schedule: cd /shared/acme && ./f5acmehandler.sh --schedule "00 04 * * 1"


## PLEASE DO NOT EDIT THIS SCRIPT ##


## ================================================== ##
## FUNCTIONS ======================================== ##
## ================================================== ##

## Static processing variables - do not touch
export ACMEDIR="/shared/acme"
#export  STANDARD_OPTIONS="-x -k ${ACMEDIR}/f5hook.sh -t http-01"
export STANDARD_OPTIONS="-x -k ${ACMEDIR}/f5hook.sh"
export REGISTER_OPTIONS="--register --accept-terms"
export LOGFILE=/var/log/acmehandler
export DGCONFIG="/Common/dg_acme_config"
export SYSLOG=""
export FORCERENEW="no"
export SINGLEDOMAIN=""
export ACCTSTATEEXISTS="no"
export CONFSTATEEXISTS="no"
export THISCONFIG=""
export SAVECONFIG="no"
export LOCALCONFIG="no"
export ENABLE_REPORTING=false
export FORCE_SYNC=false
export DEVICE_GROUP=""
export MAILHUB=""
export USESTARTTLS=no
export USETLS=no
export AUTHUSER=""
export AUTHPASS=""
export TLS_CA_FILE=""
export REPORT_FROM=""
export REPORT_TO=""
export REPORT_SUBJECT=""
export FROMLINEOVERRIDE=no
export REPORT=""
export HASCHANGED="false"
export ALIAS=""
export SYSLOG=""
export ACME_METHOD="http-01"
export ZEROCYCLE=3
export DNS_DELAY=10
export DNS_2_PHASE=false
export INTERACTIVE="false"
export DEBUGLOG=false
export ERRORLOG=true
export CHECK_REVOCATION=false
export ALWAYS_GENERATE_KEY=false
export THRESHOLD=30
export OCSP_MUST_STAPLE="yes"
export CONTACT_EMAIL=admin@foo.com
export KEYSIZE="2048"
export KEY_ALGO=rsa
export CURL_OPTS="--http1.1 -k"
export DNSAPI=""
export RENEW_DAYS="30"
export OCSP_FETCH="yes"
export OCSP_DAYS=5
export FULLCHAIN=true
export CREATEPROFILE=false
export WELLKNOWN="/tmp/wellknown"
export ORDER_TIMEOUT=0
export VALIDATION_TIMEOUT=0
export CERT_OCSP=""
export CERT_ISSUER=""
export REPORT
export VERBOSE="no"

## Function: process_errors --> print error and debug logs to the log file
f5_process_errors() {
   local ERR="${1}"
   timestamp=$(date +%F_%T)
   if [[ "$ERR" =~ ^"ERROR" && "$ERRORLOG" == "true" ]]; then echo "    $ERR" >> ${REPORT} && echo -e ">> [${timestamp}]  ${ERR}" >> ${LOGFILE}; if [ -n "$SYSLOG" ]; then /usr/bin/logger -p "${SYSLOG}" "ACME LOG: [${timestamp}]  ${ERR}"; fi; fi
   if [[ "$ERR" =~ ^"DEBUG" && "$DEBUGLOG" == "true" ]]; then echo -e ">> [${timestamp}]  ${ERR}" >> ${LOGFILE}; if [ -n "$SYSLOG" ]; then /usr/bin/logger -p "${SYSLOG}" "ACME LOG: [${timestamp}] ${ERR}"; fi; fi
   if [[ "$ERR" =~ ^"PANIC" ]]; then echo "    $ERR" >> ${REPORT} && echo -e ">> [${timestamp}]  ${ERR}" >> ${LOGFILE}; if [ -n "$SYSLOG" ]; then /usr/bin/logger -p "${SYSLOG}" "ACME LOG: [${timestamp}] ${ERR}"; fi; fi
   if [[ "$VERBOSE" == "yes" ]]; then echo -e ">> [${timestamp}]  ${ERR}" && echo -e ">> [${timestamp}]  ${ERR}" >> ${LOGFILE}; if [ -n "$SYSLOG" ]; then /usr/bin/logger -p "${SYSLOG}" "ACME LOG: [${timestamp}] ${ERR}"; fi; fi
}

export -f f5_process_errors

## Function: process_dehydrated --> call dehydrated ACME client
f5_process_dehydrated() {
   # ./bin/dehydrated "${@:-}"
   # cmd="${@:-}"
   if [[ ! "${@:-}" =~ "--config " ]]
   then 
      ${ACMEDIR}/bin/dehydrated "${@:-}" --config /shared/acme/config
   else
      ${ACMEDIR}/bin/dehydrated "${@:-}"
   fi
}


## Function: process_report --> generate and send report via SMTP (requires)
f5_process_report() {
   local TMPREPORT="${1}"

   ## Only process reporting if config_reporting file exists and ENABLE_REPORTING is true
   if [[ -f "${ACMEDIR}/config_reporting" ]]
   then
      . "${ACMEDIR}/config_reporting"
      if [[ "$ENABLE_REPORTING" == "true" ]]
      then
         echo -e "From: ${REPORT_FROM}\nSubject: ${REPORT_SUBJECT}\n\n$(echo -e $(cat ${TMPREPORT}))" | /usr/sbin/ssmtp -C "${ACMEDIR}/config_reporting" "${REPORT_TO}"
      fi   
   fi
   # echo -e $(cat ${TMPREPORT})
}


## Function: process_base64_decode --> performs base64 decode addressing any erroneous padding in input
f5_process_base64_decode() {
   echo "${1}"==== | fold -w 4 | sed '$ d' | tr -d '\n' | base64 --decode
}


## Function: process_config_file --> source values from the default or a defined config file
f5_process_config_file() {
   local COMMAND="${1}"
      
   ## Set default values
   THRESHOLD=30
   ALWAYS_GENERATE_KEY=false
   FULLCHAIN=true
   ERRORLOG=true
   DEBUGLOG=false
   CHECK_REVOCATION=false
   ACME_METHOD="http-01"

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
         f5_process_errors "PANIC: Specified config file for (${DOMAIN}) does not exist (${THIS_COMMAND_CONFIG})\n"
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
f5_generate_new_cert_key() {
   local DOMAIN="${1}" COMMAND="${2}" ALIAS="${3}"
   if [[ -z "$ALIAS" ]]; then ALIAS="${DOMAIN}"; fi
   f5_process_errors "DEBUG (handler function: f5_generate_new_cert_key)\n   DOMAIN=${DOMAIN}\n   COMMAND=${COMMAND}\n   ALIAS=${ALIAS}\n"

   ## Trigger ACME client. All BIG-IP certificate management is then handled by the hook script
   ## --alias is passed to the hook script through ${COMMAND}
   ##### cmd="${ACMEDIR}/dehydrated ${STANDARD_OPTIONS} -t ${ACME_METHOD} -c -g -d ${DOMAIN} $(echo ${COMMAND} | tr -d '"')"
   cmd="f5_process_dehydrated ${STANDARD_OPTIONS} -t ${ACME_METHOD} -c -g -d ${DOMAIN} $(echo ${COMMAND} | tr -d '"')"
   
   f5_process_errors "DEBUG (handler: ACME client command):\n$cmd\n"
   do=$(REPORT=${REPORT} eval $cmd 2>&1 | cat | sed 's/^/    /')
   f5_process_errors "DEBUG (handler: ACME client output):\n$do\n"

   ## Catch connectivity errors
   if [[ $do =~ "ERROR: Problem connecting to server" ]]
   then
      f5_process_errors "PANIC: Connectivity error for (${DOMAIN}). Please verify configuration (${COMMAND}).\n\n"
      echo "    PANIC: Connectivity error for (${DOMAIN}). Please verify configuration (${COMMAND})." >> ${REPORT}
      continue
   elif [[ $do =~ "ERROR: Timed out waiting for processing of domain validation (still pending)" ]]
   then
      f5_process_errors "PANIC: Timed out waiting for processing of domain validation for (${DOMAIN}).\n\n"
      echo "    PANIC: Timed out waiting for processing of domain validation for (${DOMAIN})." >> ${REPORT}
      continue
   elif [[ $do =~ "ERROR: An error occurred" ]]
   then
      f5_process_errors "ERROR: An error occurred for (${DOMAIN}): ${do}.\n\n"
      echo "    ERROR: An error occurred for (${DOMAIN}): ${do}." >> ${REPORT}
      continue
   elif [[ $do =~ "ERROR: Challenge is invalid" ]]
   then
      f5_process_errors "ERROR: An error occurred for (${DOMAIN}): ${do}.\n\n"
      echo "    ERROR: An error occurred for (${DOMAIN}): ${do}." >> ${REPORT}
      continue
   fi
}


## Function: (handler) generate_cert_from_csr
## This function triggers a CSR creation via TMSH, collects and passes the CSR to the ACME client, then collects
## the renewed certificate and replaces the existing certificate via TMSH transaction.
f5_generate_cert_from_csr() {
   local DOMAIN="${1}" COMMAND="${2}" ALIAS="${3}"
   if [[ -z "$ALIAS" ]]; then ALIAS="${DOMAIN}"; fi
   f5_process_errors "DEBUG (handler function: f5_generate_cert_from_csr)\n   DOMAIN=${DOMAIN}\n   COMMAND=${COMMAND}\n   ALIAS=${ALIAS}\n"

   ## Fetch existing subject-alternative-name (SAN) values from the certificate
   certsan=$(tmsh list sys crypto cert ${ALIAS} | grep subject-alternative-name | awk '{$1=$1}1' | sed 's/subject-alternative-name//' | sed 's/IP Address:/IP:/')
   ## If certsan is empty, assign the domain/CN value
   if [ -z "$certsan" ]
   then
      certsan="DNS:${DOMAIN}"
   fi

   ## Commencing acme renewal process - first delete and recreate a csr for domain (check first to prevent ltm error log message if CSR doesn't exist)
   csrexists=false && [[ "$(tmsh list sys crypto csr ${ALIAS} 2>&1)" =~ "${ALIAS}" ]] && csrexists=true
   if ($csrexists)
   then
      tmsh delete sys crypto csr ${ALIAS} > /dev/null 2>&1
   fi
   tmsh create sys crypto csr ${ALIAS} common-name ${DOMAIN} subject-alternative-name "${certsan}" key ${ALIAS}
   
   ## Dump csr to cert.csr in DOMAIN subfolder
   mkdir -p ${ACMEDIR}/certs/${ALIAS} 2>&1
   tmsh list sys crypto csr ${ALIAS} |sed -n '/-----BEGIN CERTIFICATE REQUEST-----/,/-----END CERTIFICATE REQUEST-----/p' > ${ACMEDIR}/certs/${ALIAS}/cert.csr
   f5_process_errors "DEBUG (handler: csr):\n$(cat ${ACMEDIR}/certs/${ALIAS}/cert.csr | sed 's/^/   /')\n"

   ## Trigger ACME client and dump renewed cert to certs/{domain}/cert.pem
   ##### cmd="${ACMEDIR}/dehydrated ${STANDARD_OPTIONS} -t ${ACME_METHOD} -s ${ACMEDIR}/certs/${ALIAS}/cert.csr $(echo ${COMMAND} | tr -d '"')"
   cmd="f5_process_dehydrated ${STANDARD_OPTIONS} -t ${ACME_METHOD} -s ${ACMEDIR}/certs/${ALIAS}/cert.csr $(echo ${COMMAND} | tr -d '"')"

   f5_process_errors "DEBUG (handler: ACME client command):\n   $cmd\n"
   do=$(eval $cmd 2>&1 | cat | sed 's/^/    /')
   f5_process_errors "DEBUG (handler: ACME client output):\n$do\n"

   ## Catch connectivity errors
   if [[ $do =~ "ERROR: Problem connecting to server" ]]
   then
      f5_process_errors "PANIC: Connectivity error for (${DOMAIN}). Please verify configuration (${COMMAND}).\n\n"
      echo "    PANIC: Connectivity error for (${DOMAIN}). Please verify configuration (${COMMAND})." >> ${REPORT}
      continue
   fi

   ## Catch and process returned certificate
   if [[ $do =~ "# CERT #" ]]
   then
      if [[ "${FULLCHAIN}" == "true" ]]
      then
         cat $do 2>&1 | sed -n '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' | sed -E 's/^\s+//g' > ${ACMEDIR}/certs/${ALIAS}/cert.pem
      else
         cat $do 2>&1 | sed -n '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p;/-END CERTIFICATE-/q' | sed -E 's/^\s+//g' > ${ACMEDIR}/certs/${ALIAS}/cert.pem
      fi
   else
      f5_process_errors "ERROR: ACME client failure: $do\n"
      return
   fi

   ## Create transaction to update existing cert and key
   (echo create cli transaction
      echo install sys crypto cert ${ALIAS} from-local-file ${ACMEDIR}/certs/${ALIAS}/cert.pem
      echo submit cli transaction
   ) | tmsh > /dev/null 2>&1
   f5_process_errors "DEBUG (handler: tmsh transaction) Installed certificate via tmsh transaction\n"
   echo "    Installed certificate via tmsh transaction." >> ${REPORT}

   ## Clean up objects
   tmsh delete sys crypto csr ${ALIAS}
   rm -rf ${ACMEDIR}/certs/${ALIAS}
   f5_process_errors "DEBUG (handler: cleanup) Cleaned up CSR and ${ALIAS} folder\n\n"
}


## Function: process_handler_config --> take dg config string as input and perform cert renewal processes
f5_process_handler_config() {

   ## Split input line into {DOMAIN} and {COMMAND} variables.
   IFS="=" read -r DOMAIN COMMAND <<< $1
   f5_process_errors "DEBUG START for ($DOMAIN) ==================>\n"
   
   ## Pull values from default or defined config file
   f5_process_config_file "$COMMAND"

   if [[ ( ! -z "$SINGLEDOMAIN" ) && ( ! "$SINGLEDOMAIN" == "$DOMAIN" ) ]]
   then
      ## Break out of function if SINGLEDOMAIN is specified and this pass is not for the matching domain
      continue
   else
      f5_process_errors "DEBUG (handler function: f5_process_handler_config)\n   --domain argument specified for ($DOMAIN).\n"
   fi

   echo "\n    Processing for domain: ${DOMAIN}" >> ${REPORT}


   ######################
   ### VALIDATION CHECKS
   ######################

   ## Validation check --> Defined DOMAIN should be syntactically correct
   DOMAIN=$(echo "$DOMAIN" | sed 's/\\\*/*/g')
   dom_regex='^(\*\.)?([a-zA-Z0-9](([a-zA-Z0-9-]){0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
   if [[ ! "$DOMAIN" =~ $dom_regex ]]
   then
      f5_process_errors "PANIC: Configuration entry ($DOMAIN) is incorrect. Skipping.\n"
      echo "    PANIC: Configuration entry ($DOMAIN) is incorrect. Skipping." >> ${REPORT}
      continue 
   fi

   ## Validation check: Does the config entry include a "--alias" option
   if [[ "$COMMAND" =~ "--alias " ]]
   then
      ALIAS=$(echo "$COMMAND" | sed -E 's/.*(--alias+\s[^[:space:]]+).*/\1/g;s/"//g;s/--alias //g')
   else
      ALIAS="${DOMAIN}"
   fi

   ## Validation check: Does --ocsp exist without --issuer, and vice-versa
   if [[ (("$COMMAND" =~ "--ocsp ") && !("$COMMAND" =~ "--issuer ")) || (("$COMMAND" =~ "--issuer ") && !("$COMMAND" =~ "--ocsp ")) ]]
   then
      f5_process_errors "PANIC: Configuration contains either an --ocsp option or --issuer option. Both are required when one is set."
      echo "    PANIC: Configuration contains either an --ocsp option or --issuer option. Both are required when one is set." >> ${REPORT}
      continue
   elif [[ (("$COMMAND" =~ "--ocsp ") && ("$COMMAND" =~ "--issuer ")) ]]
   then
      CERT_OCSP=$(echo "$COMMAND" | sed -E 's/.*(--ocsp+\s[^[:space:]]+).*/\1/g;s/"//g;s/--ocsp //g')
      CERT_ISSUER=$(echo "$COMMAND" | sed -E 's/.*(--issuer+\s[^[:space:]]+).*/\1/g;s/"//g;s/--issuer //g')

      ## Remove --issuer and --ocsp from COMMAND
      COMMAND=$(echo $COMMAND | sed -E 's/(.*)--ocsp+\s[^[:space:]]+(.*)/\1\2/g;s/(.*)--issuer+\s[^[:space:]]+(.*)/\1\2/g;s/[[:space:]]+/ /g')

      ## Now check if either ocsp config object or issuer certificate are missing
      ocspexists=true && [[ "$(tmsh list sys crypto cert-validator ocsp ${CERT_OCSP} 2>&1)" =~ "was not found" ]] && ocspexists=false
      issuerexists=true && [[ "$(tmsh list sys crypto cert ${CERT_ISSUER} 2>&1)" == "" ]] && issuerexists=false

      if [[ "$ocspexists" == "false" ]]
      then
         f5_process_errors "PANIC: Configuration contains --ocsp option that points to an OCSP object that does not exist."
         echo "    PANIC: Configuration contains --ocsp option that points to an OCSP object that does not exist." >> ${REPORT}
         continue
      fi

      if [[ "$issuerexists" == "false" ]]
      then
         f5_process_errors "PANIC: Configuration contains --issuer option that points to a certificate that does not exist."
         echo "    PANIC: Configuration contains --issuer option that points to a certificate that does not exist." >> ${REPORT}
         continue
      fi
   fi

   ## Validation check: Config entry must include "--ca" option
   if [[ ! "$COMMAND" =~ "--ca " ]]
   then
      f5_process_errors "PANIC: Configuration entry for ($DOMAIN) must include a \"--ca\" option. Skipping.\n"
      echo "    PANIC: Configuration entry for ($DOMAIN) must include a \"--ca\" option. Skipping." >> ${REPORT}
      continue 
   fi

   ## Validation check: Defined provider should be registered
   if [[ "$(f5_process_check_registered $COMMAND)" == "notfound" ]]
   then
      f5_process_errors "DEBUG: Defined ACME provider not registered. Registering.\n"
      echo "    Defined ACME provider not registered. Registering." >> ${REPORT}

      ## Extract --ca and --config values
      COMMAND_CA=$(echo "$COMMAND" | sed -E 's/.*(--ca+\s[^[:space:]]+).*/\1/g;s/"//g')
      if [[ "$COMMAND" =~ "--config " ]]; then COMMAND_CONFIG=$(echo "$COMMAND" | sed -E 's/.*(--config+\s[^[:space:]]+).*/\1/g;s/"//g'); else COMMAND_CONFIG=""; fi
      
      ## Handling registration
      ##### cmd="${ACMEDIR}/dehydrated --register --accept-terms ${COMMAND_CA} ${COMMAND_CONFIG}"
      cmd="f5_process_dehydrated --register --accept-terms ${COMMAND_CA} ${COMMAND_CONFIG}"

      do=$(eval $cmd 2>&1 | cat | sed 's/^/   /')
      f5_process_errors "DEBUG (handler: ACME provider registration):\n$do\n"
   fi


   ## Start logging
   f5_process_errors "DEBUG (handler function: f5_process_handler_config)\n   VAR: DOMAIN=${DOMAIN}\n   VAR: COMMAND=${COMMAND}\n"

   ## Error test: check if cert exists in BIG-IP config
   certexists=true && [[ "$(tmsh list sys crypto cert ${ALIAS} 2>&1)" == "" ]] && certexists=false

   if [[ "$ALWAYS_GENERATE_KEY" == "true" ]]
   then
      ## If ALWAYS_GENERATE_KEYS is true, call the f5_generate_new_cert_key function, else call f5_generate_cert_from_csr
      if [[ "$certexists" == "false" ]]
      then
         ## Certificate does not exist
         f5_process_errors "DEBUG: ALWAYS_GENERATE_KEY is true and certificate does not exist --> call f5_generate_new_cert_key.\n"
         echo "    ALWAYS_GENERATE_KEY is true and certificate does not exist. Generating a new cert and key." >> ${REPORT}
         HASCHANGED="true"
         f5_generate_new_cert_key "$DOMAIN" "$COMMAND" "$ALIAS"
      
      elif [[ "$certexists" == "true" && "$CHECK_REVOCATION" == "true" && "$(f5_process_revocation_check "${ALIAS}")" == "revoked" ]]
      then
         ## Certificate exists, but CHECK_REVOCATION is enabled and certificate is revoked
         f5_process_errors "DEBUG: ALWAYS_GENERATE_KEY is true, certificate exists, CHECK_REVOCATION is on, and revocation check found (${DOMAIN}) is revoked -- Fetching new certificate and key"
         echo "    ALWAYS_GENERATE_KEY is true, certificate exists, CHECK_REVOCATION is on, and revocation check found (${DOMAIN}) is revoked -- Fetching new certificate and key." >> ${REPORT}
         HASCHANGED="true"
         f5_generate_new_cert_key "$DOMAIN" "$COMMAND" "$ALIAS"
      
      else
         ## Certificate exists and is not expired. Check for FORCERENEW and collect today's date and certificate expiration date
         if [[ ! "${FORCERENEW}" == "yes" ]]
         then
            date_cert=$(tmsh list sys crypto cert ${ALIAS} | grep expiration | awk '{$1=$1}1' | sed 's/expiration //')
            date_cert=$(date -d "$date_cert" "+%Y%m%d")
            date_today=$(date +"%Y%m%d")
            date_test=$(( ($(date -d "$date_cert" +%s) - $(date -d "$date_today" +%s)) / 86400 ))
            f5_process_errors "DEBUG (handler: dates)\n   date_cert=$date_cert\n   date_today=$date_today\n   date_test=$date_test\n"
         else
            date_test=0
            f5_process_errors "DEBUG (handler: dates)\n   --force argument specified, forcing renewal\n"
         fi

         ## If certificate is past the threshold window, initiate renewal
         if [ $THRESHOLD -ge $date_test ]
         then
            f5_process_errors "DEBUG: ALWAYS_GENERATE_KEY is true, certificate exists, and THRESHOLD ($THRESHOLD) -ge date_test ($date_test) - Starting renewal process for ${DOMAIN}\n"
            echo "    ALWAYS_GENERATE_KEY is true, certificate exists, and THRESHOLD ($THRESHOLD) -ge date_test ($date_test) - Starting renewal process for ${DOMAIN}" >> ${REPORT}
            HASCHANGED="true"
            f5_generate_new_cert_key "$DOMAIN" "$COMMAND" "$ALIAS"
         else
            f5_process_errors "DEBUG: ALWAYS_GENERATE_KEY is true, certificate exists, and bypassing renewal process for ${DOMAIN} - Certificate within threshold\n"
            echo "    ALWAYS_GENERATE_KEY is true, certificate exists, and bypassing renewal process for ${DOMAIN} - Certificate within threshold" >> ${REPORT}
         fi
      fi
   
   else
      ## If ALWAYS_GENERATE_KEYS is false, call the f5_generate_cert_from_csr function
      if [[ "$certexists" == "false" ]]
      then
         ## Certificate does not exist
         f5_process_errors "DEBUG: ALWAYS_GENERATE_KEY is false and certificate does not exist --> call f5_generate_cert_from_csr.\n"
         echo "    ALWAYS_GENERATE_KEY is false and certificate does not exist. Generating a new cert and key." >> ${REPORT}
         HASCHANGED="true"
         #f5_generate_cert_from_csr "$DOMAIN" "$COMMAND" "$ALIAS"
         f5_generate_new_cert_key "$DOMAIN" "$COMMAND" "$ALIAS"
      
      elif [[ "$certexists" == "true" && "$CHECK_REVOCATION" == "true" && "$(f5_process_revocation_check "${DOMAIN}")" == "revoked" ]]
      then
         ## Certificate exists, but CHECK_REVOCATION is enabled and certificate is revoked
         f5_process_errors "DEBUG: ALWAYS_GENERATE_KEY is false, certificate exists, CHECK_REVOCATION is on, and revocation check found (${DOMAIN}) is revoked -- Fetching new certificate"
         echo "    ALWAYS_GENERATE_KEY is false, certificate exists, CHECK_REVOCATION is on, and revocation check found (${DOMAIN}) is revoked -- Fetching new certificate." >> ${REPORT}
         HASCHANGED="true"
         f5_generate_cert_from_csr "$DOMAIN" "$COMMAND" "$ALIAS"
      
      else
         ## Certificate exists and is not expired. Check for FORCERENEW and collect today's date and certificate expiration date
         if [[ ! "${FORCERENEW}" == "yes" ]]
         then
            date_cert=$(tmsh list sys crypto cert ${ALIAS} | grep expiration | awk '{$1=$1}1' | sed 's/expiration //')
            date_cert=$(date -d "$date_cert" "+%Y%m%d")
            date_today=$(date +"%Y%m%d")
            date_test=$(( ($(date -d "$date_cert" +%s) - $(date -d "$date_today" +%s)) / 86400 ))
            f5_process_errors "DEBUG (handler: dates)\n   date_cert=$date_cert\n   date_today=$date_today\n   date_test=$date_test\n"
         else
            date_test=0
            f5_process_errors "DEBUG (handler: dates)\n   --force argument specified, forcing renewal\n"
         fi

         ## If certificate is past the threshold window, initiate renewal
         if [ $THRESHOLD -ge $date_test ]
         then
            f5_process_errors "DEBUG: ALWAYS_GENERATE_KEY is false, certificate exists, and THRESHOLD ($THRESHOLD) -ge date_test ($date_test) - Starting renewal process for ${DOMAIN}\n"
            echo "    ALWAYS_GENERATE_KEY is false, certificate exists, and THRESHOLD ($THRESHOLD) -ge date_test ($date_test) - Starting renewal process for ${DOMAIN}" >> ${REPORT}
            HASCHANGED="true"
            f5_generate_cert_from_csr "$DOMAIN" "$COMMAND" "$ALIAS"
         else
            f5_process_errors "DEBUG: ALWAYS_GENERATE_KEY is false, certificate exists, and bypassing renewal process for ${DOMAIN} - Certificate within threshold\n"
            echo "    ALWAYS_GENERATE_KEY is false, certificate exists, and bypassing renewal process for ${DOMAIN} - Certificate within threshold" >> ${REPORT}
         fi
      fi
   fi
}


## Function: process_check_registered --> tests for local registration
f5_process_check_registered() {
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
f5_process_get_configs() {
   ## Only run this on HA systems
   ISHA=$(tmsh show cm sync-status | grep Standalone | wc -l)
   if [[ "${ISHA}" = "0" || "${SAVECONFIG}" == "yes" ]]
   then
      ## ACCOUNTS STATE DATA 
      ## Test if the iFile exists (f5_acme_state) and pull into local folder if it does
      ifileexists=true && [[ "$(tmsh list sys file ifile f5_acme_account_state 2>&1)" =~ "was not found" ]] && ifileexists=false
      if ($ifileexists)
      then
         cat $(tmsh list sys file ifile f5_acme_account_state -hidden | grep cache-path | sed -E 's/^\s+cache-path\s//') | base64 -d | tar xz
         ACCTSTATEEXISTS="yes"
         f5_process_errors "DEBUG Pulling acme account state information from iFile central storage\n"
      else
         ACCTSTATEEXISTS="no"
         f5_process_errors "DEBUG No iFile central account store found - New state data will need to be created locally\n"
      fi

      ## DNSAPI STATE DATA 
      ## Test if the iFile exists (f5_acme_state) and pull into local folder if it does
      ifileexists=true && [[ "$(tmsh list sys file ifile f5_acme_dnsapi_state 2>&1)" =~ "was not found" ]] && ifileexists=false
      if ($ifileexists)
      then
         cat $(tmsh list sys file ifile f5_acme_dnsapi_state -hidden | grep cache-path | sed -E 's/^\s+cache-path\s//') | base64 -d | tar xz
         DNSAPISTATEEXISTS="yes"
         f5_process_errors "DEBUG Pulling acme dnsapi state information from iFile central storage\n"
      else
         DNSAPISTATEEXISTS="no"
         f5_process_errors "DEBUG No iFile central dnsapi store found - New state data will need to be created locally\n"
      fi
      
      ## Generate checksum on accounts state file (accounts folder)
      # STARTSUM=$(find -type f \( -path "./accounts/*" -o -name "config*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')
      # ACCTSTARTSUM=$(find -type f \( -path "./accounts/*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')
      ACCTSTARTSUM=$(find "${ACMEDIR}/accounts" -type f \( -path "*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')
      
      ## Generate checksum on config state files (config* files)
      # CONFSTARTSUM=$(find -type f \( -name "config*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')
      CONFSTARTSUM=$(find "${ACMEDIR}" -type f \( -name "config*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')

      ## Generate checksum on dnsapi state file (dnsapi folder)
      # STARTSUM=$(find -type f \( -path "./dnsapi/*" -o -name "config*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')
      # DNSAPISTARTSUM=$(find -type f \( -path "./dnsapi/*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')
      DNSAPISTARTSUM=$(find "${ACMEDIR}/dnsapi" -type f \( -path "*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')


      ## CONFIGS STATE DATA 
      ## Process config files only if --save is specified
      if [[ "${LOCALCONFIG}" == "yes" ]]
      then
         ## LOCALCONFIG enabled - do not get config state from central store
         f5_process_errors "DEBUG LOCALCONFIG enabled - working from local config data\n"
      else
         ## LOCALCONFIG not enabled - get the config state from central store
         ## Test if the iFile exists (f5_acme_state) and pull into local folder if it does
         confifileexists=true && [[ "$(tmsh list sys file ifile f5_acme_config_state 2>&1)" =~ "was not found" ]] && confifileexists=false
         if ($confifileexists)
         then
            cat $(tmsh list sys file ifile f5_acme_config_state -hidden | grep cache-path | sed -E 's/^\s+cache-path\s//') | base64 -d | tar xz
            CONFSTATEEXISTS="yes"
            f5_process_errors "DEBUG Pulling acme config state information from iFile central storage\n"
         else
            CONFSTATEEXISTS="no"
            f5_process_errors "DEBUG No iFile central config store found - New state data will need to be created locally\n"
         fi
      fi
   fi
}


## Function: process_put_configs --> pushes local configs to iFile central store
f5_process_put_configs() {
   ## Only run this on HA systems
   if [[ "${ISHA}" = "0" || "${SAVECONFIG}" == "yes" ]]
   then
      ## ACCOUNTS STATE DATA 
      ## Generate checksum on state files (accounts folder)
      # ENDSUM=$(find -type f \( -path "./accounts/*" -o -name "config*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')
      # ACCTENDSUM=$(find -type f \( -path "./accounts/*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')
      ACCTENDSUM=$(find "${ACMEDIR}/accounts" -type f \( -path "*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')

      ## Generate checksum on state files (config files)
      # CONFENDSUM=$(find -type f \( -name "config*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')
      CONFENDSUM=$(find "${ACMEDIR}" -type f \( -name "config*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')

      ## Generate checksum on state files (dnsapi folder)
      DNSAPIENDSUM=$(find "${ACMEDIR}/dnsapi" -type f \( -path "*" \) -exec md5sum {} \; | sort -k 2 | md5sum | awk -F" " '{print $1}')


      ## STARTSUM/ENDSUM inequality indicates that changes were made - push state changes to iFile store
      ## ACCOUNTS STATE DATA
      if [[ "$ACCTSTARTSUM" != "$ACCTENDSUM" || "$ACCTSTATEEXISTS" == "no" ]]
      then
         f5_process_errors "DEBUG START/END account checksums are different or iFile state is missing - pushing account state data to iFile central store\n"

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
         f5_process_errors "DEBUG START/END account checksums detects no changes - not pushing account state data to iFile central store\n"
      fi


      ## CONFIGS STATE DATA
      if [[ "$CONFSTARTSUM" != "$CONFENDSUM" || "$CONFSTATEEXISTS" == "no" ]]
      then
         f5_process_errors "DEBUG START/END config checksums are different or iFile state is missing - pushing config state data to iFile central store\n"

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
         f5_process_errors "DEBUG START/END config checksums detects no changes - not pushing config state data to iFile central store\n"
      fi

      if [[ "$HASCHANGED" == "true" && "$FORCE_SYNC" == "true" ]]
      then
         ## The config has changed and FORCE_SYNC is set to true - force an HA sync
         f5_process_errors "DEBUG START/END config checksums are different and FORCE_SYNC is set to true - forcing an HA sync operation\n"
         tmsh run /cm config-sync to-group ${DEVICE_GROUP}
         tmsh run /cm config-sync from-group ${DEVICE_GROUP}
      fi


      ## DNSAPI STATE DATA
      if [[ "$DNSAPISTARTSUM" != "$DNSAPIENDSUM" || "$DNSAPISTATEEXISTS" == "no" ]]
      then
         f5_process_errors "DEBUG START/END dnsapi checksums are different or iFile state is missing - pushing dnsapi state data to iFile central store\n"

         ## Update HASCHANGED flag
         HASCHANGED="true"

         ## First compress and base64-encode the dnsapi folder and config files
         # tar -czf - dnsapi/ config* | base64 -w 0 > data.b64
         cd "${ACMEDIR}"
         tar -czf - "./dnsapi/" | base64 -w 0 > "${ACMEDIR}/dnsapi.b64"

         ## Test if the iFile exists (f5_acme_dnsapi_state)
         ifileexists=true && [[ "$(tmsh list sys file ifile f5_acme_dnsapi_state 2>&1)" =~ "was not found" ]] && ifileexists=false
         if ($ifileexists)
         then
            ## iFile exists - update iFile and delete local file
            tmsh modify sys file ifile f5_acme_dnsapi_state source-path "file://${ACMEDIR}/dnsapi.b64"
            rm -f dnsapi.b64
         else
            ## iFile doesn't exist - create iFile and delete local file
            tmsh create sys file ifile f5_acme_dnsapi_state source-path "file://${ACMEDIR}/dnsapi.b64"
            rm -f dnsapi.b64
         fi 
      else
         f5_process_errors "DEBUG START/END dnsapi checksums detects no changes - not pushing dnsapi state data to iFile central store\n"
      fi
   fi
}


## Function: process_revocation_check --> consume BIG-IP certificate object name as input and attempt to perform a direct OCSP revocation check
f5_process_revocation_check() {
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
f5_process_listaccounts() {
   printf "\nThe following ACME providers are registered:\n\n"
   for acct in ${ACMEDIR}/accounts/*
   do
      acct_tmp=$(echo $acct | sed -E 's/.*\/accounts\///')
      printf "   PROVIDER: $(f5_process_base64_decode $acct_tmp)\n"
      printf "   LOCATION: ${ACMEDIR}/accounts/$acct_tmp\n\n"
   done
}


## Function: process_schedule --> accept a cron string value and create a crontab entry for this utility
f5_process_schedule() {
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
f5_process_uninstall() {
   ## Clear out any existing script entry
   crontab -l |grep -v f5acmehandler | crontab
}


## Function: process_handler_main --> loop through config data group and pass DOMAIN and COMMAND values to client handlers
f5_process_handler_main() {
   ## Test for and only run on active BIG-IP
   ACTIVE=$(tmsh show cm failover-status | grep ACTIVE | wc -l)
   if [[ "${ACTIVE}" = "1" ]]
   then
      echo "\n  Processing renewals:" >> ${REPORT}

      ## Call process_get_configs to retrieve centrally stored iFile state data into the local folder
      f5_process_get_configs

      ## Create wellknown folder
      mkdir -p /tmp/wellknown > /dev/null 2>&1
      
      ## Read from the config data group and loop through keys:values
      config=true && [[ "$(tmsh list ltm data-group internal ${DGCONFIG} 2>&1)" =~ "was not found" ]] && config=false
      if ($config)
      then
         IFS=";" && for v in $(tmsh list ltm data-group internal ${DGCONFIG} one-line | sed -e 's/^.* records { //;s/ \} type string \}//;s/ { data /=/g;s/ \} /;/g;s/ \}//'); do f5_process_handler_config $v; done
      else
         f5_process_errors "PANIC: There was an error accessing the ${DGCONFIG} data group. Please re-install.\n"
         echo "    PANIC: There was an error accessing the ${DGCONFIG} data group" >> ${REPORT}
         f5_process_report "${REPORT}"
         exit 1
      fi

      ## Call process_put_configs to push local state data into central iFile store
      f5_process_put_configs

      f5_process_report "${REPORT}"
      # echo -e "$(cat ${REPORT})"
   else
      f5_process_errors "DEBUG START/END The BIG-IP node is not in an ACTIVE state. No renewals processed.\n"
      echo -e "\nThe BIG-IP node is not in an ACTIVE state. No renewals processed.\n" >> ${LOGFILE}
      exit 1
   fi
   return 0
}


## Function: command_help --> display help information in stdout
## Usage: --help
f5_command_help() {
  printf "\nUsage: %s [--help]\n"
  printf "Usage: %s [--force] [--domain <domain>]\n"
  printf "Usage: %s [--listaccounts]\n"
  printf "Usage: %s [--schedule <cron>]\n"
  printf "Usage: %s [--testrevocation <domain>]\n"
  printf "Usage: %s [--uninstall]\n"
  printf "Usage: %s [--local]\n"
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
  printf " --local:\t\t\tForce use of local config in an HA environment\n"
  printf " --save:\t\t\tForce aave of local config to iFiles in non-HA environment\n"
  printf " --verbose:\t\t\tDump verbose output to stdout\n\n\n"
}


## Function: main --> process command line arguments
f5_main() {
   ## Test for interactive shell
   if [ "`tty`" != "not a tty" ]; then export INTERACTIVE=true; fi

   ## Process commandline
   while (( ${#} )); do
      case "${1}" in
         --help)
           f5_command_help >&2
           exit 0
           ;;

         --listaccounts)
           f5_process_listaccounts
           exit 0
           ;;

         --schedule)
           shift 1
           if [[ -z "${1:-}" ]]; then
             printf "\nThe specified command requires an additional parameter. Please see --help:" >&2
             echo >&2
             f5_command_help >&2
             exit 1
           fi
           f5_process_schedule "${1}"
           exit 0
           ;;

         --uninstall)
           f5_process_uninstall
           exit 0
           ;;

         --testrevocation)
           shift 1
           if [[ -z "${1:-}" ]]; then
             printf "\nThe specified command requires an additional parameter. Please see --help:" >&2
             echo >&2
             f5_command_help >&2
             exit 1
           fi
           f5_process_revocation_check "${1}"
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

         --local)
           echo "  Command Line Option Specified: --local" >> ${REPORT} 
           LOCALCONFIG="yes"
           ;;

         --verbose)
           echo "  Command Line Option Specified: --verbose" >> ${REPORT}
           export VERBOSE="yes"
           ;;

         --domain)
           shift 1
           if [[ -z "${1:-}" ]]; then
             printf "\nThe specified command requires additional an parameter. Please see --help:" >&2
             echo >&2
             f5_command_help >&2
             exit 1
           fi
           echo "  Command Line Option Specified: --domain ${1}" >> ${REPORT}
           SINGLEDOMAIN="${1}"
           ;;

         *)
           f5_process_errors "DEBUG (handler function: main)\n   Launching default renew operations\n"
           ;;
      esac
   shift 1
   done

   ## Call main function
   f5_process_handler_main
}

## Script entry
REPORT=$(mktemp)
echo "ACMEv2 Renewal Report: $(date)\n\n" > ${REPORT}
f5_main "${@:-}"






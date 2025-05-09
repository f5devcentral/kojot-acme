#!/usr/bin/env sh
## DNSAPI: RFC2136 (BIND)
## Gratuitously borrowed from acme.sh and modified for local use
## Maintainer: kevin-at-f5-dot-com
## Version: 1
## Issues: https://github.com/f5devcentral/kojot-acme/issues
## Add the following information to your provider config file:
##   DNSAPI=dns_nsupdate
##   NSUPDATE_SERVER="192.168.100.53"                           <-- points to RFC2136/BIND server IP
##   NSUPDATE_SERVER_PORT=53                                    <-- points to RFC2136/BIND server port
##   NSUPDATE_KEY="/shared/acme/extra/dns_nsupdate_creds.ini"   <-- points to RFC2136 credentials file

dns_nsupdate_info='nsupdate RFC 2136 DynDNS client
Site: bind9.readthedocs.io/en/v9.18.19/manpages.html#nsupdate-dynamic-dns-update-utility
Docs: github.com/acmesh-official/acme.sh/wiki/dnsapi#dns_nsupdate
Options:
 NSUPDATE_SERVER Server hostname. Default: "localhost".
 NSUPDATE_SERVER_PORT Server port. Default: "53".
 NSUPDATE_KEY File path to TSIG key.
 NSUPDATE_ZONE Domain zone to update. Optional.
'

#Usage: dns_nsupdate_add   _acme-challenge.www.domain.com   "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
dns_nsupdate_add() {
  fulldomain=$1
  txtvalue=$2

  _checkKeyFile || return 1

  [ -n "${NSUPDATE_SERVER}" ] || NSUPDATE_SERVER="localhost"
  [ -n "${NSUPDATE_SERVER_PORT}" ] || NSUPDATE_SERVER_PORT=53
  [ -n "${NSUPDATE_OPT}" ] || NSUPDATE_OPT=""

  f5_process_errors "DEBUG dns_nsupdate: adding ${fulldomain}. 60 in txt \"${txtvalue}\""
  if [ -z "${NSUPDATE_ZONE}" ]; then
    #shellcheck disable=SC2086
    echo "Setting up for nsupdate -k ${NSUPDATE_KEY} $nsdebug $NSUPDATE_OPT server ${NSUPDATE_SERVER}  ${NSUPDATE_SERVER_PORT} update add ${fulldomain}. 60 in txt ${txtvalue} send"
    nsupdate -k "${NSUPDATE_KEY}" $nsdebug $NSUPDATE_OPT <<EOF
server ${NSUPDATE_SERVER}  ${NSUPDATE_SERVER_PORT}
update add ${fulldomain}. 60 in txt "${txtvalue}"
send
EOF
  else
    #shellcheck disable=SC2086
    echo "Setting up for nsupdate -k ${NSUPDATE_KEY} $nsdebug $NSUPDATE_OPT server ${NSUPDATE_SERVER}  ${NSUPDATE_SERVER_PORT} update add ${fulldomain}. 60 in txt ${txtvalue} send"
    nsupdate -k "${NSUPDATE_KEY}" $nsdebug $NSUPDATE_OPT <<EOF
server ${NSUPDATE_SERVER}  ${NSUPDATE_SERVER_PORT}
zone ${NSUPDATE_ZONE}.
update add ${fulldomain}. 60 in txt "${txtvalue}"
send
EOF
  fi
  if [ $? -ne 0 ]; then
    _err "error updating domain"
    return 1
  fi

  return 0
}

#Usage: dns_nsupdate_rm   _acme-challenge.www.domain.com
dns_nsupdate_rm() {
  fulldomain=$1

  _checkKeyFile || return 1
  f5_process_errors "DEBUG dns_nsupdate: removing ${fulldomain}. txt"
  if [ -z "${NSUPDATE_ZONE}" ]; then
    #shellcheck disable=SC2086
    nsupdate -k "${NSUPDATE_KEY}" $nsdebug $NSUPDATE_OPT <<EOF
server ${NSUPDATE_SERVER}  ${NSUPDATE_SERVER_PORT}
update delete ${fulldomain}. txt
send
EOF
  else
    #shellcheck disable=SC2086
    nsupdate -k "${NSUPDATE_KEY}" $nsdebug $NSUPDATE_OPT <<EOF
server ${NSUPDATE_SERVER}  ${NSUPDATE_SERVER_PORT}
zone ${NSUPDATE_ZONE}.
update delete ${fulldomain}. txt
send
EOF
  fi
  if [ $? -ne 0 ]; then
    _err "error updating domain"
    return 1
  fi

  return 0
}

####################  Private functions below ##################################

_checkKeyFile() {
  if [ -z "${NSUPDATE_KEY}" ]; then
    _err "you must specify a path to the nsupdate key file"
    return 1
  fi
  if [ ! -r "${NSUPDATE_KEY}" ]; then
    _err "key ${NSUPDATE_KEY} is unreadable"
    return 1
  fi
}
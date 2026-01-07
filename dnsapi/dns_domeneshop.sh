#!/usr/bin/env sh
## DNSAPI: domeneshop
## Gratuitously borrowed from github.com/acmesh-official/acme.sh/wiki/dnsapi2#dns_domeneshop and modified for local use
## Maintainer:
## Version: 1
## Issues: https://github.com/f5devcentral/kojot-acme/issues
## Add the following information to your provider config file:
##   DOMENESHOP_Token=token
##   DOMENESHOP_Secret=secret

DOMENESHOP_Api_Endpoint="https://api.domeneshop.no/v0"

#####################  Public functions #####################

# Usage: dns_domeneshop_add <full domain> <txt record>
# Example: dns_domeneshop_add _acme-challenge.www.example.com "1234567890"

dns_domeneshop_add() {
  fulldomain=$1
  txtvalue=$2

  if [ -z "$DOMENESHOP_Token" ] || [ -z "$DOMENESHOP_Secret" ]; then
    DOMENESHOP_Token=""
    DOMENESHOP_Secret=""
    f5_process_errors "ERROR dns_domeneshop: You need to specify a API Token and Secret."
    return 1
  fi

  # Get the domain name id
  if ! _get_domainid "$fulldomain"; then
    f5_process_errors "ERROR dns_domeneshop: Did not find domainname"
    return 1
  fi

  # Create record
  _domeneshop_rest POST "domains/$_domainid/dns" "{\"type\":\"TXT\",\"host\":\"$_sub_domain\",\"data\":\"$txtvalue\",\"ttl\":120}"
}

# Usage: dns_domeneshop_rm <full domain> <txt record>
# Example: dns_domeneshop_rm _acme-challenge.www.example.com "1234567890"

dns_domeneshop_rm() {
  fulldomain=$1
  txtvalue=$2

  if [ -z "$DOMENESHOP_Token" ] || [ -z "$DOMENESHOP_Secret" ]; then
    DOMENESHOP_Token=""
    DOMENESHOP_Secret=""
    f5_process_errors "ERROR dns_domeneshop: You need to spesify a Domeneshop/Domainnameshop API Token and Secret."
    return 1
  fi

  # Get the domain name id
  if ! _get_domainid "$fulldomain"; then
    f5_process_errors "ERROR dns_domeneshop: Did not find domainname"
    return 1
  fi

  # Find record
  if ! _get_recordid "$_domainid" "$_sub_domain" "$txtvalue"; then
    f5_process_errors "ERROR dns_domeneshop: Did not find dns record"
    return 1
  fi

  # Remove record
  _domeneshop_rest DELETE "domains/$_domainid/dns/$_recordid"
}

#####################  Private functions #####################

_get_domainid() {
  domain=$1

  # Get domains
  _domeneshop_rest GET "domains"

  if ! _contains "$response" "\"id\":"; then
    f5_process_errors "ERROR dns_domeneshop: failed to get domain names"
    return 1
  fi

  i=2
  p=1
  while true; do
    h=$(printf "%s" "$domain" | cut -d . -f "$i"-100)
    if [ -z "$h" ]; then
      #not valid
      return 1
    fi

    if _contains "$response" "\"$h\"" >/dev/null; then
      # We have found the domain name.
      
      _sub_domain=$(printf "%s" "$domain" | cut -d . -f 1-"$p")
      _domain=$h
      _domainid=$(printf "%s" "$response" | _egrep_o "[^{]*\"domain\":\"$_domain\"[^}]*" | _egrep_o "\"id\":[0-9]+" | cut -d : -f 2)
      return 0
    fi
    p=$i
    i=$(_math "$i" + 1)
  done
  return 1
}

_get_recordid() {
  domainid=$1
  subdomain=$2
  txtvalue=$3

  # Get all dns records for the domainname
  _domeneshop_rest GET "domains/$domainid/dns"

  if ! _contains "$response" "\"id\":"; then
    f5_process_errors "DEBUG dns_domeneshop: No records in dns"
    return 1
  fi

  if ! _contains "$response" "\"host\":\"$subdomain\""; then
    f5_process_errors "DEBUG dns_domeneshop: Record does not exist"
    return 1
  fi

  # Get the id of the record in question
  _recordid=$(printf "%s" "$response" | _egrep_o "[^{]*\"host\":\"$subdomain\"[^}]*" | _egrep_o "[^{]*\"data\":\"$txtvalue\"[^}]*" | _egrep_o "\"id\":[0-9]+" | cut -d : -f 2)
  if [ -z "$_recordid" ]; then
    return 1
  fi
  return 0
}

_domeneshop_rest() {
  method=$1
  endpoint=$2
  data=$3
  credentials=$(printf "%b" "$DOMENESHOP_Token:$DOMENESHOP_Secret")
  export _H1="Authorization: Basic $credentials"
  export _H2="Content-Type: application/json"

  if [ "$method" = "GET" ]; then
    f5_process_errors "DEBUG GET $DOMENESHOP_Api_Endpoint/$endpoint $_H2"
    response="$(curl -sk -H "$_H1" -H "$_H2" "$DOMENESHOP_Api_Endpoint/$endpoint")"
    f5_process_errors "DEBUG GET response=$response"
  fi

  if [ "$method" = "POST" ]; then
    f5_process_errors "DEBUG POST curl -sk -H $_H2 -X POST -d '$data' $DOMENESHOP_Api_Endpoint/$endpoint"
    response="$(curl -sk -H "$_H1" -H "$_H2" -X POST "$DOMENESHOP_Api_Endpoint/$endpoint" -d "$data")"
    f5_process_errors "DEBUG POST response=$response"
    f5_process_errors "DEBUG sleep 10 after adding dns record"
    sleep 10
  fi

  if [ "$method" = "DELETE" ]; then
    f5_process_errors "DEBUG DELETE curl -sk -H $_H2 -X DELETE -d '$data' $DOMENESHOP_Api_Endpoint/$endpoint"
    response="$(curl -sk -H "$_H1" -H "$_H2" -X DELETE "$DOMENESHOP_Api_Endpoint/$endpoint")"
  fi

  if [ "$?" != "0" ]; then
    f5_process_errors "ERROR dns_domeneshop: error $endpoint"
    return 1
  fi

  return 0
}

_contains() {
  _str="$1"
  _sub="$2"
  echo "$_str" | grep -- "$_sub" >/dev/null 2>&1
}

_math() {
  _m_opts="$@"
  printf "%s" "$(($_m_opts))"
}

_egrep_o() {
  egrep -o -- "$1" 2>/dev/null
}


#!/usr/bin/env sh
## DNSAPI: Dynu DNS
## Gratuitously borrowed from acme.sh and modified for local use
## Maintainer: kevin-at-f5-dot-com
## Version: 1
## Issues: https://github.com/f5devcentral/kojot-acme/issues
## Add the following information to your provider config file:
##   DNSAPI=dns_dynu
##   Dynu_ClientId='37afffe3fd091a2e8bede63addsdaq23d3'   <-- Your DYNU Client ID
##   Dynu_Secret="37afffe3fd091a2e8bede63addsdaq23d3"     <-- YOur DYNU Secret

dns_dynu_info='Dynu.com
Site: Dynu.com
Docs: https://www.dynu.com/support/api
Docs: github.com/acmesh-official/acme.sh/wiki/dnsapi#dns_dynu
Options:
 Dynu_ClientId Client ID
 Dynu_Secret Secret
Original Author: Dynu Systems Inc
'

#Token
Dynu_Token=""
#
#Endpoint
Dynu_EndPoint="https://api.dynu.com/v2"

########  Public functions #####################

#Usage: add _acme-challenge.www.domain.com "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
dns_dynu_add() {
  fulldomain=$1
  txtvalue=$2

  if [ -z "$Dynu_ClientId" ] || [ -z "$Dynu_Secret" ]; then
    Dynu_ClientId=""
    Dynu_Secret=""
    f5_process_errors "ERROR dns_dynu: Dynu client id and secret is not specified."
    f5_process_errors "ERROR dns_dynu: Please create you API client id and secret and try again."
    return 1
  fi

  if [ -z "$Dynu_Token" ]; then
    f5_process_errors "DEBUG dns_dynu: Getting Dynu token."
    if ! _dynu_authentication; then
      f5_process_errors "ERROR dns_dynu: Can not get token."
    fi
  fi

  f5_process_errors "DEBUG dns_dynu: Detect root zone"
  if ! _get_root "$fulldomain"; then
    f5_process_errors "ERROR dns_dynu: Invalid domain."
    return 1
  fi

  f5_process_errors "DEBUG dns_dynu: _node: $_node"
  f5_process_errors "DEBUG dns_dynu: _domain_name: $_domain_name"

  f5_process_errors "DEBUG dns_dynu: Creating TXT record."
  if ! _dynu_rest POST "dns/$dnsId/record" "{\"domainId\":\"$dnsId\",\"nodeName\":\"$_node\",\"recordType\":\"TXT\",\"textData\":\"$txtvalue\",\"state\":true,\"ttl\":90}"; then
    return 1
  fi

  if ! _contains "$response" "200"; then
    f5_process_errors "ERROR dns_dynu: Could not add TXT record."
    return 1
  fi

  return 0
}

#Usage: rm _acme-challenge.www.domain.com "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
dns_dynu_rm() {
  fulldomain=$1
  txtvalue=$2

  if [ -z "$Dynu_ClientId" ] || [ -z "$Dynu_Secret" ]; then
    Dynu_ClientId=""
    Dynu_Secret=""
    f5_process_errors "ERROR dns_dynu: Dynu client id and secret is not specified."
    f5_process_errors "ERROR dns_dynu: Please create you API client id and secret and try again."
    return 1
  fi

  if [ -z "$Dynu_Token" ]; then
    f5_process_errors "DEBUG dns_dynu: Getting Dynu token."
    if ! _dynu_authentication; then
      f5_process_errors "ERROR dns_dynu: Can not get token."
    fi
  fi

  f5_process_errors "DEBUG dns_dynu: Detect root zone."
  if ! _get_root "$fulldomain"; then
    f5_process_errors "ERROR dns_dynu: Invalid domain."
    return 1
  fi

  f5_process_errors "DEBUG dns_dynu: _node: $_node"
  f5_process_errors "DEBUG dns_dynu: _domain_name: $_domain_name"

  f5_process_errors "DEBUG dns_dynu: Checking for TXT record."
  if ! _get_recordid "$fulldomain" "$txtvalue"; then
    f5_process_errors "ERROR dns_dynu: Could not get TXT record id."
    return 1
  fi

  if [ "$_dns_record_id" = "" ]; then
    f5_process_errors "ERROR dns_dynu: TXT record not found."
    return 1
  fi

  f5_process_errors "DEBUG dns_dynu: Removing TXT record."
  if ! _delete_txt_record "$_dns_record_id"; then
    f5_process_errors "ERROR dns_dynu: Could not remove TXT record $_dns_record_id."
  fi

  return 0
}

########  Private functions below ##################################
#_acme-challenge.www.domain.com
#returns
# _node=_acme-challenge.www
# _domain_name=domain.com
_get_root() {
  domain=$1
  i=2
  p=1
  while true; do
    h=$(printf "%s" "$domain" | cut -d . -f "$i"-100)
    f5_process_errors "DEBUG dns_dynu: h: $h"
    if [ -z "$h" ]; then
      #not valid
      return 1
    fi

    if ! _dynu_rest GET "dns/getroot/$h"; then
      return 1
    fi

    if _contains "$response" "\"domainName\":\"$h\"" >/dev/null; then
      dnsId=$(printf "%s" "$response" | tr -d "{}" | cut -d , -f 2 | cut -d : -f 2)
      _domain_name=$h
      _node=$(printf "%s" "$domain" | cut -d . -f 1-"$p")
      return 0
    fi
    p=$i
    i=$(_math "$i" + 1)
  done
  return 1

}

_get_recordid() {
  fulldomain=$1
  txtvalue=$2

  if ! _dynu_rest GET "dns/$dnsId/record"; then
    return 1
  fi

  if ! _contains "$response" "$txtvalue"; then
    _dns_record_id=0
    return 0
  fi

  _dns_record_id=$(printf "%s" "$response" | sed -e 's/[^{]*\({[^}]*}\)[^{]*/\1\n/g' | grep "\"textData\":\"$txtvalue\"" | sed -e 's/.*"id":\([^,]*\).*/\1/')
  return 0
}

_delete_txt_record() {
  _dns_record_id=$1

  if ! _dynu_rest DELETE "dns/$dnsId/record/$_dns_record_id"; then
    return 1
  fi

  if ! _contains "$response" "200"; then
    return 1
  fi

  return 0
}

_dynu_rest() {
  m=$1
  ep="$2"
  data="$3"
  f5_process_errors "DEBUG dns_dynu: ep: $ep"

  export _H1="Authorization: Bearer $Dynu_Token"

  if [ "$m" == "POST" ]; then
    f5_process_errors "DEBUG dns_dynu: POST data: $data"
    response="$(curl -sk -X POST -H "Accept: application/json" -H "$_H1" -d "$data" "$Dynu_EndPoint/$ep")"
  elif [ "$m" == "DELETE" ]; then
    f5_process_errors "DEBUG dns_dynu: DELETE record: $ep"
    response="$(curl -sk -X DELETE -H "Accept: application/json" -H "$_H1" -d "$data" "$Dynu_EndPoint/$ep")"
  else
    response="$(curl -sk -X GET -H "Accept: application/json" -H "$_H1" "$Dynu_EndPoint/$ep")"
  fi

  if [ "$?" != "0" ]; then
    f5_process_errors "ERROR dns_dynu: error: $ep"
    return 1
  fi
  f5_process_errors "DEBUG dns_dynu: response: $response"
  return 0
}

_dynu_authentication() {
  realm="$(printf "%s" "$Dynu_ClientId:$Dynu_Secret" | _base64)"

  export _H1="Authorization: Basic $realm"

#   response="$(_get "$Dynu_EndPoint/oauth2/token")"
  response="$(curl -sk -X GET -H "Accept: application/json" -H "$_H1" "$Dynu_EndPoint/oauth2/token")"
  if [ "$?" != "0" ]; then
    f5_process_errors "ERROR dns_dynu: Authentication failed."
    return 1
  fi
  if _contains "$response" "Authentication Exception"; then
    f5_process_errors "ERROR dns_dynu: Authentication failed."
    return 1
  fi
  if _contains "$response" "access_token"; then
    Dynu_Token=$(printf "%s" "$response" | tr -d "{}" | cut -d , -f 1 | cut -d : -f 2 | cut -d '"' -f 2)
  fi
  if _contains "$Dynu_Token" "null"; then
    Dynu_Token=""
  fi

  f5_process_errors "DEBUG dns_dynu: response: $response"
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

_base64() {
  [ "" ] #urgly
  if [ "$1" ]; then
    openssl base64 -e
  else
    openssl base64 -e | tr -d '\r\n'
  fi
}
#!/usr/bin/env sh
## DNSAPI: PointHQ
## Gratuitously borrowed from acme.sh and modified for local use
## Maintainer: kevin-at-f5-dot-com
## Version: 1
## Issues: https://github.com/f5devcentral/kojot-acme/issues
## Add the following information to your provider config file:
##   DNSAPI=dns_pointhq
##   PointHQ_Key='37afffe3fd091a2e8bede63addsdaq23d3'   <-- Your PointHQ API Key
##   PointHQ_Email="admin@example.com"                  <-- YOur PointHQ email address

dns_pointhq_info='pointhq.com PointDNS
Site: pointhq.com
Docs: https://w.pointhq.com/api/docs
Docs: github.com/acmesh-official/acme.sh/wiki/dnsapi#dns_pointhq
Options:
 PointHQ_Key API Key
 PointHQ_Email Email
'

PointHQ_Api="https://api.pointhq.com"

########  Public functions #####################

#Usage: add  _acme-challenge.www.domain.com   "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
dns_pointhq_add() {
  fulldomain=$1
  txtvalue=$2

  if [ -z "$PointHQ_Key" ] || [ -z "$PointHQ_Email" ]; then
    PointHQ_Key=""
    PointHQ_Email=""
    f5_process_errors "ERROR dns_pointhq: You didn't specify a PointHQ API key and email yet."
    f5_process_errors "ERROR dns_pointhq: Please create the key and try again."
    return 1
  fi

  if ! _contains "$PointHQ_Email" "@"; then
    f5_process_errors "ERROR dns_pointhq: It seems that the PointHQ_Email=$PointHQ_Email is not a valid email address."
    f5_process_errors "ERROR dns_pointhq: Please check and retry."
    return 1
  fi

  f5_process_errors "DEBUG dns_pointhq: First detect the root zone"
  if ! _get_root "$fulldomain"; then
    f5_process_errors "ERROR dns_pointhq: invalid domain"
    return 1
  fi
  f5_process_errors "DEBUG dns_pointhq: _sub_domain: $_sub_domain"
  f5_process_errors "DEBUG dns_pointhq: _domain: $_domain"

  f5_process_errors "DEBUG dns_pointhq: Adding record"
  if _pointhq_rest POST "zones/$_domain/records" "{\"zone_record\": {\"name\":\"$_sub_domain\",\"record_type\":\"TXT\",\"data\":\"$txtvalue\",\"ttl\":3600}}"; then
    if printf -- "%s" "$response" | grep "$fulldomain" >/dev/null; then
      f5_process_errors "DEBUG dns_pointhq: Added, OK"
      return 0
    else
      f5_process_errors "ERROR dns_pointhq: Add txt record error."
      return 1
    fi
  fi
  f5_process_errors "ERROR dns_pointhq: Add txt record error."
  return 1
}

#fulldomain txtvalue
dns_pointhq_rm() {
  fulldomain=$1
  txtvalue=$2

  if [ -z "$PointHQ_Key" ] || [ -z "$PointHQ_Email" ]; then
    PointHQ_Key=""
    PointHQ_Email=""
    f5_process_errors "ERROR dns_pointhq: You didn't specify a PointHQ API key and email yet."
    f5_process_errors "ERROR dns_pointhq: Please create the key and try again."
    return 1
  fi

  f5_process_errors "DEBUG dns_pointhq: First detect the root zone"
  if ! _get_root "$fulldomain"; then
    f5_process_errors "ERROR dns_pointhq: invalid domain"
    return 1
  fi
  f5_process_errors "DEBUG dns_pointhq: _sub_domain: $_sub_domain"
  f5_process_errors "DEBUG dns_pointhq: _domain: $_domain"

  f5_process_errors "DEBUG dns_pointhq: Getting txt records"
  _pointhq_rest GET "zones/${_domain}/records?record_type=TXT&name=$_sub_domain"

  if ! printf "%s" "$response" | grep "^\[" >/dev/null; then
    f5_process_errors "ERROR dns_pointhq: Error"
    return 1
  fi

  if [ "$response" = "[]" ]; then
    f5_process_errors "DEBUG dns_pointhq: No records to remove."
  else
    record_id=$(printf "%s\n" "$response" | _egrep_o "\"id\":[^,]*" | cut -d : -f 2 | tr -d \" | head -n 1)
    f5_process_errors "DEBUG dns_pointhq: record_id: $record_id"
    if [ -z "$record_id" ]; then
      f5_process_errors "ERROR dns_pointhq: Can not get record id to remove."
      return 1
    fi
    if ! _pointhq_rest DELETE "zones/$_domain/records/$record_id"; then
      f5_process_errors "ERROR dns_pointhq: Delete record error."
      return 1
    fi
    _contains "$response" '"status":"OK"'
  fi
}

####################  Private functions below ##################################
#_acme-challenge.www.domain.com
#returns
# _sub_domain=_acme-challenge.www
# _domain=domain.com
_get_root() {
  domain=$1
  i=2
  p=1
  while true; do
    h=$(printf "%s" "$domain" | cut -d . -f "$i"-100)
    f5_process_errors "DEBUG dns_pointhq: h: $h"
    if [ -z "$h" ]; then
      #not valid
      return 1
    fi

    if ! _pointhq_rest GET "zones"; then
      return 1
    fi

    if _contains "$response" "\"name\":\"$h\"" >/dev/null; then
      _sub_domain=$(printf "%s" "$domain" | cut -d . -f 1-"$p")
      _domain=$h
      return 0
    fi
    p=$i
    i=$(_math "$i" + 1)
  done
  return 1
}

_pointhq_rest() {
  m=$1
  ep="$2"
  data="$3"
  f5_process_errors "DEBUG dns_pointhq: ep: $ep"

  _pointhq_auth=$(printf "%s:%s" "$PointHQ_Email" "$PointHQ_Key" | _base64)

  export _H1="Authorization: Basic $_pointhq_auth"

  if [ "$m" == "POST" ]; then
    f5_process_errors "DEBUG dns_pointhq: data: $data"
    response="$(curl -sk -X POST -H "Content-Type: application/json" -H "Accept: application/json" -H "$_H1" "$PointHQ_Api/$ep" -d "$data")"
  elif [ "$m" == "DELETE" ]; then
    response="$(curl -sk -X DELETE -H "Content-Type: application/json" -H "Accept: application/json" -H "$_H1" "$PointHQ_Api/$ep")"
  else
    response="$(curl -sk -X GET -H "Accept: application/json" -H "$_H1" "$PointHQ_Api/$ep")"
  fi

  if [ "$?" != "0" ]; then
    f5_process_errors "ERROR dns_pointhq: error: $ep"
    return 1
  fi
  f5_process_errors "DEBUG dns_pointhq: response: $response"
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

_base64() {
  [ "" ] #urgly
  if [ "$1" ]; then
    openssl base64 -e
  else
    openssl base64 -e | tr -d '\r\n'
  fi
}
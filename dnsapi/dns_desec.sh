#!/usr/bin/env sh
## DNSAPI: deSEC.io
## Gratuitously borrowed from acme.sh and modified for local use
## Maintainer: kevin-at-f5-dot-com
## Version: 1
## Issues: https://github.com/f5devcentral/kojot-acme/issues
## Add the following information to your provider config file:
##   DNSAPI=dns_desec
##   DDNSS_Token='jqOSwe32erx23dc34fdcscxverg4513d'      <-- Your deSEC.io token

dns_desec_info='deSEC.io
Site: desec.readthedocs.io/en/latest/
Docs: https://desec.readthedocs.io/en/latest/index.html
Docs: github.com/acmesh-official/acme.sh/wiki/dnsapi#dns_desec
Options:
 DESEC_TOKEN API Token
Original Author: Zheng Qian
'

REST_API="https://desec.io/api/v1/domains"

########  Public functions #####################

#Usage: dns_desec_add   _acme-challenge.foobar.dedyn.io   "d41d8cd98f00b204e9800998ecf8427e"
dns_desec_add() {
  fulldomain=$1
  txtvalue=$2
  f5_process_errors "DEBUG dns_desec: Using desec.io api"
  f5_process_errors "DEBUG dns_desec: fulldomain: $fulldomain"
  f5_process_errors "DEBUG dns_desec: txtvalue: $txtvalue"

  if [ -z "$DESEC_TOKEN" ]; then
    DESEC_TOKEN=""
    f5_process_errors "ERROR dns_desec: You did not specify DESEC_TOKEN yet."
    f5_process_errors "ERROR dns_desec: Please create your key and try again."
    f5_process_errors "ERROR dns_desec: e.g."
    f5_process_errors "ERROR dns_desec: export DESEC_TOKEN=d41d8cd98f00b204e9800998ecf8427e"
    return 1
  fi

  f5_process_errors "DEBUG dns_desec: First detect the root zone"
  if ! _get_root "$fulldomain" "$REST_API/"; then
    f5_process_errors "ERROR dns_desec: invalid domain"
    return 1
  fi
  f5_process_errors "DEBUG dns_desec: _sub_domain: $_sub_domain"
  f5_process_errors "DEBUG dns_desec: _domain: $_domain"

  # Get existing TXT record
  f5_process_errors "DEBUG dns_desec: Getting txt records"
  txtvalues="\"\\\"$txtvalue\\\"\""
  _desec_rest GET "$REST_API/$_domain/rrsets/$_sub_domain/TXT/"

  if [ "$_code" = "200" ]; then
    oldtxtvalues="$(echo "$response" | _egrep_o "\"records\":\\[\"\\S*\"\\]" | cut -d : -f 2 | tr -d "[]\\\\\"" | sed "s/,/ /g")"
    f5_process_errors "DEBUG dns_desec: existing TXT found"
    f5_process_errors "DEBUG dns_desec: oldtxtvalues: $oldtxtvalues"
    if [ -n "$oldtxtvalues" ]; then
      for oldtxtvalue in $oldtxtvalues; do
        txtvalues="$txtvalues, \"\\\"$oldtxtvalue\\\"\""
      done
    fi
  fi
  f5_process_errors "DEBUG dns_desec: txtvalues: $txtvalues"
  f5_process_errors "DEBUG dns_desec: Adding record"
  body="[{\"subname\":\"$_sub_domain\", \"type\":\"TXT\", \"records\":[$txtvalues], \"ttl\":3600}]"

  if _desec_rest PUT "$REST_API/$_domain/rrsets/" "$body"; then
    if _contains "$response" "$txtvalue"; then
      f5_process_errors "DEBUG dns_desec: Added, OK"
      return 0
    else
      f5_process_errors "ERROR dns_desec: Add txt record error."
      return 1
    fi
  fi

  f5_process_errors "ERROR dns_desec: Add txt record error."
  return 1
}

#Usage: fulldomain txtvalue
#Remove the txt record after validation.
dns_desec_rm() {
  fulldomain=$1
  txtvalue=$2
  f5_process_errors "DEBUG dns_desec: Using desec.io api"
  f5_process_errors "DEBUG dns_desec: fulldomain: $fulldomain"
  f5_process_errors "DEBUG dns_desec: txtvalue: $txtvalue"

  if [ -z "$DESEC_TOKEN" ]; then
    DESEC_TOKEN=""
    f5_process_errors "ERROR dns_desec: You did not specify DESEC_TOKEN yet."
    f5_process_errors "ERROR dns_desec: Please create your key and try again."
    f5_process_errors "ERROR dns_desec: e.g."
    f5_process_errors "ERROR dns_desec: export DESEC_TOKEN=d41d8cd98f00b204e9800998ecf8427e"
    return 1
  fi

  f5_process_errors "DEBUG dns_desec: First detect the root zone"
  if ! _get_root "$fulldomain" "$REST_API/"; then
    f5_process_errors "ERROR dns_desec: invalid domain"
    return 1
  fi

  f5_process_errors "DEBUG dns_desec: _sub_domain: $_sub_domain"
  f5_process_errors "DEBUG dns_desec: _domain: $_domain"

  # Get existing TXT record
  f5_process_errors "DEBUG dns_desec: Getting txt records"
  txtvalues=""
  _desec_rest GET "$REST_API/$_domain/rrsets/$_sub_domain/TXT/"

  if [ "$_code" = "200" ]; then
    oldtxtvalues="$(echo "$response" | _egrep_o "\"records\":\\[\"\\S*\"\\]" | cut -d : -f 2 | tr -d "[]\\\\\"" | sed "s/,/ /g")"
    f5_process_errors "DEBUG dns_desec: existing TXT found"
    f5_process_errors "DEBUG dns_desec: oldtxtvalues: $oldtxtvalues"
    if [ -n "$oldtxtvalues" ]; then
      for oldtxtvalue in $oldtxtvalues; do
        if [ "$txtvalue" != "$oldtxtvalue" ]; then
          txtvalues="$txtvalues, \"\\\"$oldtxtvalue\\\"\""
        fi
      done
    fi
  fi
  txtvalues="$(echo "$txtvalues" | cut -c3-)"
  f5_process_errors "DEBUG dns_desec: txtvalues: $txtvalues"

  f5_process_errors "DEBUG dns_desec: Deleting record"
  body="[{\"subname\":\"$_sub_domain\", \"type\":\"TXT\", \"records\":[$txtvalues], \"ttl\":3600}]"
  _desec_rest PATCH "$REST_API/$_domain/rrsets/" "$body"
  # if _contains "$response" "[]"; then
  if [ "$_code" = "200" ]; then
    f5_process_errors "DEBUG dns_desec: Deleted, OK"
    return 0
  fi

  f5_process_errors "ERROR dns_desec: Delete txt record error."
  return 1
}

####################  Private functions below ##################################

_desec_rest() {
  m="$1"
  ep="$2"
  data="$3"

  export _H1="Authorization: Token $DESEC_TOKEN"

  if [ "$m" == "POST" ]; then
    f5_process_errors "DEBUG dns_desec: POST data: $data"
    _content="$(curl -sk -w "%{http_code}" -X POST -H "Content-Type: application/json" -H "Accept: application/json" -H "$_H1" "$ep" -d "$data")"
    _code=${_content: -3}
    response=$(echo ${_content} | head -c-4)
  elif [ "$m" == "PUT" ]; then
    f5_process_errors "DEBUG dns_desec: PUT record: $ep"
    _content="$(curl -sk -w "%{http_code}" -X PUT -H "Content-Type: application/json" -H "Accept: application/json" -H "$_H1" "$ep" -d "$data")"
    _code=${_content: -3}
    response=$(echo ${_content} | head -c-4)
  elif [ "$m" == "PATCH" ]; then
    f5_process_errors "DEBUG dns_desec: PATCH record: $ep"
    _content=$(curl -sk -w "%{http_code}" -X PATCH -H "Content-Type: application/json" -H "Accept: application/json" -H "$_H1" "$ep" --data @- <<EOF
${data}
EOF
    )
    _code=${_content: -3}
    response=$(echo ${_content} | head -c-4)
  else
    f5_process_errors "DEBUG dns_desec: GET record: $ep"
    _content="$(curl -sk -w "%{http_code}" -X GET -H "Accept: application/json" -H "$_H1" "$ep")"
    _code=${_content: -3}
    response=$(echo ${_content} | head -c-4)
  fi

  _ret="$?"
  # _code="$(grep "^HTTP" "$HTTP_HEADER" | _tail_n 1 | cut -d " " -f 2 | tr -d "\\r\\n")"
  f5_process_errors "DEBUG dns_desec: http response code: $_code"
  f5_process_errors "DEBUG dns_desec: response: $response"
  if [ "$_ret" != "0" ]; then
    f5_process_errors "ERROR dns_desec: error: $ep"
    return 1
  fi

  response="$(printf "%s" "$response" | _normalizeJson)"
  return 0
}

#_acme-challenge.www.domain.com
#returns
# _sub_domain=_acme-challenge.www
# _domain=domain.com
_get_root() {
  domain="$1"
  ep="$2"
  i=2
  p=1
  while true; do
    h=$(printf "%s" "$domain" | cut -d . -f "$i"-100)
    f5_process_errors "DEBUG dns_desec: h: $h"
    if [ -z "$h" ]; then
      #not valid
      return 1
    fi

    if ! _desec_rest GET "$ep"; then
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

_egrep_o() {
  egrep -o -- "$1" 2>/dev/null
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

_tail_n() {
  tail -n "$1"
}

_normalizeJson() {
  sed "s/\" *: *\([\"{\[]\)/\":\1/g" | sed "s/^ *\([^ ]\)/\1/" | tr -d "\r\n"
}
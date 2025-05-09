#!/usr/bin/env sh
## DNSAPI: LUADNS
## Gratuitously borrowed from acme.sh and modified for local use
## Maintainer: kevin-at-f5-dot-com
## Version: 1
## Issues: https://github.com/f5devcentral/kojot-acme/issues
## Add the following information to your provider config file:
##   DNSAPI=dns_lua
##   LUA_Key='37afffe3fd091a2e8bede63addsdaq23d3'   <-- Your LUA API Key
##   LUA_Email="admin@example.com"                  <-- YOur LUA email address

dns_lua_info='LuaDNS.com
Domains: LuaDNS.net
Site: LuaDNS.com
Docs: https://www.luadns.com/api.html
Docs: github.com/acmesh-official/acme.sh/wiki/dnsapi#dns_lua
Options:
 LUA_Key API key
 LUA_Email Email
Original Author: <dev@1e.ca>
'

LUA_Api="https://api.luadns.com/v1"


#Usage: add  _acme-challenge.www.domain.com   "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
dns_lua_add() {
  fulldomain=$1
  txtvalue=$2

  if [ -z "$LUA_Key" ] || [ -z "$LUA_Email" ]; then
    LUA_Key=""
    LUA_Email=""
    f5_process_errors "ERROR dns_lua: You don't specify luadns api key and email yet."
    f5_process_errors "ERROR dns_lua: Please create you key and try again."
    return 1
  fi

  f5_process_errors "DEBUG dns_lua: First detect the root zone"
  if ! _get_root "$fulldomain"; then
    f5_process_errors "ERROR dns_lua: invalid domain"
    return 1
  fi
  f5_process_errors "DEBUG dns_lua: _domain_id: $_domain_id"
  f5_process_errors "DEBUG dns_lua: _sub_domain: $_sub_domain"
  f5_process_errors "DEBUG dns_lua: _domain: $_domain"

  f5_process_errors "DEBUG dns_lua: Adding record"
  if _LUA_rest POST "zones/$_domain_id/records" "{\"type\":\"TXT\",\"name\":\"$fulldomain.\",\"content\":\"$txtvalue\",\"ttl\":120}"; then
    if _contains "$response" "$fulldomain"; then
      f5_process_errors "DEBUG dns_lua: Added"
      #todo: check if the record takes effect
      return 0
    else
      f5_process_errors "ERROR dns_lua: Add txt record error."
      return 1
    fi
  fi
}

#fulldomain
dns_lua_rm() {
  fulldomain=$1
  txtvalue=$2

  f5_process_errors "DEBUG dns_lua: First detect the root zone"
  if ! _get_root "$fulldomain"; then
    f5_process_errors "ERROR dns_lua: invalid domain"
    return 1
  fi
  f5_process_errors "DEBUG dns_lua: _domain_id: $_domain_id"
  f5_process_errors "DEBUG dns_lua: _sub_domain: $_sub_domain"
  f5_process_errors "DEBUG dns_lua: _domain: $_domain"

  f5_process_errors "DEBUG dns_lua: Getting txt records"
  _LUA_rest GET "zones/${_domain_id}/records"

  count=$(printf "%s\n" "$response" | _egrep_o "\"name\":\"$fulldomain.\",\"type\":\"TXT\"" | wc -l | tr -d " ")
  f5_process_errors "DEBUG dns_lua: count: $count"
  if [ "$count" = "0" ]; then
    f5_process_errors "DEBUG dns_lua: Don't need to remove."
  else
    record_id=$(printf "%s\n" "$response" | _egrep_o "\"id\":[^,]*,\"name\":\"$fulldomain.\",\"type\":\"TXT\"" | _head_n 1 | cut -d: -f2 | cut -d, -f1)
    f5_process_errors "DEBUG dns_lua: record_id: $record_id"
    if [ -z "$record_id" ]; then
      f5_process_errors "ERROR dns_lua: Can not get record id to remove."
      return 1
    fi
    if ! _LUA_rest DELETE "/zones/$_domain_id/records/$record_id"; then
      f5_process_errors "ERROR dns_lua: Delete record error."
      return 1
    fi
    _contains "$response" "$record_id"
  fi
}

####################  Private functions below ##################################
#_acme-challenge.www.domain.com
#returns
# _sub_domain=_acme-challenge.www
# _domain=domain.com
# _domain_id=sdjkglgdfewsdfg
_get_root() {
  domain=$1
  i=2
  p=1

  if ! _LUA_rest GET "zones"; then
    return 1
  fi
  while true; do
    h=$(printf "%s" "$domain" | cut -d . -f "$i"-100)
    f5_process_errors "DEBUG dns_lua: h: $h"
    if [ -z "$h" ]; then
      #not valid
      return 1
    fi

    if _contains "$response" "\"name\":\"$h\""; then
      _domain_id=$(printf "%s\n" "$response" | _egrep_o "\"id\":[^,]*,\"name\":\"$h\"" | cut -d : -f 2 | cut -d , -f 1)
      f5_process_errors "DEBUG dns_lua: _domain_id: $_domain_id"
      if [ "$_domain_id" ]; then
        _sub_domain=$(printf "%s" "$domain" | cut -d . -f 1-"$p")
        _domain="$h"
        return 0
      fi
      return 1
    fi
    p=$i
    i=$(_math "$i" + 1)
  done
  return 1
}

_LUA_rest() {
  m=$1
  ep="$2"
  data="$3"
  f5_process_errors "DEBUG dns_lua: REST ep: $ep"
  f5_process_errors "DEBUG dns_lua: REST m: $m"
  f5_process_errors "DEBUG dns_lua: REST data: $data"

  if [ "$m" == "POST" ]; then
    f5_process_errors "DEBUG dns_lua: POST data: $data"
    response="$(curl -sk -X POST -H "Accept: application/json" -u "${LUA_Email}:${LUA_Key}" -d "$data" "$LUA_Api/$ep")"
  elif [ "$m" == "DELETE" ]; then
    f5_process_errors "DEBUG dns_lua: DELETE record: $ep"
    response="$(curl -sk -X DELETE -H "Accept: application/json" -u "${LUA_Email}:${LUA_Key}" "${LUA_Api}${ep}")"
  else
    response="$(curl -sk -X GET -H "Accept: application/json" -u "${LUA_Email}:${LUA_Key}" "$LUA_Api/$ep")"
  fi

  if [ "$?" != "0" ]; then
    f5_process_errors "ERROR dns_lua: error $ep"
    return 1
  fi
  f5_process_errors "DEBUG dns_lua: response: $response"
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

_head_n() {
  head -n "$1"
}
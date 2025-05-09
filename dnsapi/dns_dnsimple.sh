#!/usr/bin/env sh
## DNSAPI: DNSimple
## Gratuitously borrowed from acme.sh and modified for local use
## Maintainer: kevin-at-f5-dot-com
## Version: 1
## Issues: https://github.com/f5devcentral/kojot-acme/issues
## Add the following information to your provider config file:
##   DNSAPI=dns_dnsimple
##   DNSimple_OAUTH_TOKEN='dnsimple_o_jqOSwe32erx23dc34fdcscxverg4513d'      <-- Your DNSimple OAuth token

dns_dnsimple_info='DNSimple.com
Site: DNSimple.com
Docs: https://developer.dnsimple.com/v2/
Docs: github.com/acmesh-official/acme.sh/wiki/dnsapi#dns_dnsimple
Options:
 DNSimple_OAUTH_TOKEN OAuth Token
'

DNSimple_API="https://api.dnsimple.com/v2"

########  Public functions #####################

# Usage: add  _acme-challenge.www.domain.com   "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
dns_dnsimple_add() {
  fulldomain=$1
  txtvalue=$2

  if [ -z "$DNSimple_OAUTH_TOKEN" ]; then
    DNSimple_OAUTH_TOKEN=""
    f5_process_errors "ERROR dns_dnsimple: You have not set the dnsimple oauth token yet."
    f5_process_errors "ERROR dns_dnsimple: Please visit https://dnsimple.com/user to generate it."
    return 1
  fi

  if ! _get_account_id; then
    f5_process_errors "ERROR dns_dnsimple: failed to retrive account id"
    return 1
  fi

  if ! _get_root "$fulldomain"; then
    f5_process_errors "ERROR dns_dnsimple: invalid domain"
    return 1
  fi

  _get_records "$_account_id" "$_domain" "$_sub_domain"

  f5_process_errors "DEBUG dns_dnsimple: Adding record"
  if _dnsimple_rest POST "$_account_id/zones/$_domain/records" "{\"type\":\"TXT\",\"name\":\"$_sub_domain\",\"content\":\"$txtvalue\",\"ttl\":120}"; then
    if printf -- "%s" "$response" | grep "\"name\":\"$_sub_domain\"" >/dev/null; then
      f5_process_errors "DEBUG dns_dnsimple: Added"
      return 0
    else
      f5_process_errors "ERROR dns_dnsimple: Unexpected response while adding text record. Response: $response"
      return 1
    fi
  fi
  f5_process_errors "ERROR dns_dnsimple: Add txt record error."
}

# fulldomain
dns_dnsimple_rm() {
  fulldomain=$1

  if ! _get_account_id; then
    f5_process_errors "ERROR dns_dnsimple: failed to retrive account id"
    return 1
  fi

  if ! _get_root "$fulldomain"; then
    f5_process_errors "ERROR dns_dnsimple: invalid domain"
    return 1
  fi

  _get_records "$_account_id" "$_domain" "$_sub_domain"

  _extract_record_id "$_records" "$_sub_domain"
  if [ "$_record_id" ]; then
    echo "$_record_id" | while read -r item; do
      if _dnsimple_rest DELETE "$_account_id/zones/$_domain/records/$item"; then
        f5_process_errors "DEBUG dns_dnsimple: removed record: $item"
        return 0
      else
        f5_process_errors "ERROR dns_dnsimple: failed to remove record: $item"
        return 1
      fi
    done
  fi
}

####################  Private functions bellow ##################################
# _acme-challenge.www.domain.com
# returns
#   _sub_domain=_acme-challenge.www
#   _domain=domain.com
_get_root() {
  domain=$1
  i=2
  previous=1
  while true; do
    h=$(printf "%s" "$domain" | cut -d . -f "$i"-100)
    if [ -z "$h" ]; then
      # not valid
      return 1
    fi

    if ! _dnsimple_rest GET "$_account_id/zones/$h"; then
      return 1
    fi

    if _contains "$response" 'not found'; then
      f5_process_errors "DEBUG dns_dnsimple: $h: not found"
    else
      _sub_domain=$(printf "%s" "$domain" | cut -d . -f 1-"$previous")
      _domain="$h"

      f5_process_errors "DEBUG dns_dnsimple: _domain: $_domain"
      f5_process_errors "DEBUG dns_dnsimple: _sub_domain: $_sub_domain"

      return 0
    fi

    previous="$i"
    i=$(_math "$i" + 1)
  done
  return 1
}

# returns _account_id
_get_account_id() {
  f5_process_errors "DEBUG dns_dnsimple: retrive account id"
  if ! _dnsimple_rest GET "whoami"; then
    return 1
  fi

  if _contains "$response" "\"account\":null"; then
    f5_process_errors "ERROR dns_dnsimple: no account associated with this token"
    return 1
  fi

  if _contains "$response" "timeout"; then
    f5_process_errors "ERROR dns_dnsimple: timeout retrieving account id"
    return 1
  fi

  _account_id=$(printf "%s" "$response" | _egrep_o "\"id\":[^,]*,\"email\":" | cut -d: -f2 | cut -d, -f1)
  f5_process_errors "DEBUG dns_dnsimple: account_id: $_account_id"

  return 0
}

# returns
#   _records
#   _records_count
_get_records() {
  account_id=$1
  domain=$2
  sub_domain=$3

  f5_process_errors "DEBUG dns_dnsimple: fetching txt records"
  _dnsimple_rest GET "$account_id/zones/$domain/records?per_page=5000&sort=id:desc"

  if ! _contains "$response" "\"id\":"; then
    f5_process_errors "ERROR dns_dnsimple: failed to retrieve records"
    return 1
  fi

  _records_count=$(printf "%s" "$response" | _egrep_o "\"name\":\"$sub_domain\"" | wc -l | _egrep_o "[0-9]+")
  _records=$response
  f5_process_errors "DEBUG dns_dnsimple: _records_count: $_records_count"
}

# returns _record_id
_extract_record_id() {
  _record_id=$(printf "%s" "$_records" | _egrep_o "\"id\":[^,]*,\"zone_id\":\"[^,]*\",\"parent_id\":null,\"name\":\"$_sub_domain\"" | cut -d: -f2 | cut -d, -f1)
  f5_process_errors "DEBUG dns_dnsimple: _record_id: $_record_id"
}

# returns response
_dnsimple_rest() {
  method=$1
  path="$2"
  data="$3"
  f5_process_errors "DEBUG dns_dnsimple: path: $path"

  export _H1="Authorization: Bearer $DNSimple_OAUTH_TOKEN"

  if [ "$method" == "POST" ]; then
    f5_process_errors "DEBUG dns_dnsimple: POST data: $data"
    response="$(curl -sk -X POST -H "Content-Type: application/json" -H "Accept: application/json" -H "$_H1" "${DNSimple_API}/${path}" -d $data)"
  elif [ "$method" == "DELETE" ]; then
    f5_process_errors "DEBUG dns_dnsimple: DELETE record: $ep"
    response="$(curl -sk -X DELETE -H "Accept: application/json" -H "$_H1" "${DNSimple_API}/${path}")"
  else
    response="$(curl -sk -X GET -H "Accept: application/json" -H "$_H1" "${DNSimple_API}/${path}")"
  fi

  if [ "$?" != "0" ]; then
    f5_process_errors "ERROR dns_dnsimple: error: $request_url"
    return 1
  fi
  f5_process_errors "DEBUG dns_dnsimple: response: $response"
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
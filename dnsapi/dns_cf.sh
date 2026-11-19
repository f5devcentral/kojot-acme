#!/usr/bin/env sh
## DNSAPI: CloudFlare
## Gratuitously borrowed from acme.sh and modified for local use
## Maintainer: kevin-at-f5-dot-com
## Version: 1
## Issues: https://github.com/f5devcentral/kojot-acme/issues
## Add the following information to your provider config file:
##  DNSAPI=dns_cf
## And either:
##  CF_Key=<your_key>
##  CF_Email=<youremail@domain.com>
## Or:
##  CF_Token=<account_token>
##  CF_Account_ID=<your_account_id>
##  CF_Zone_ID=<your_zone_id> # Optional

dns_cf_info='CloudFlare
Site: CloudFlare.com
Docs: https://developers.cloudflare.com/api/resources/dns/
Docs: github.com/acmesh-official/acme.sh/wiki/dnsapi#dns_cf
Options:
 CF_Key API Key
 CF_Email Your account email
OptionsAlt:
 CF_Token API Token
 CF_Account_ID Account ID
 CF_Zone_ID Zone ID. Optional.
'

CF_Api="https://api.cloudflare.com/client/v4"

########  Public functions #####################

#Usage: add _acme-challenge.www.domain.com "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
dns_cf_add() {
  fulldomain=$1
  txtvalue=$2

  if ! [ "$CF_Token" ]; then
    if [ -z "$CF_Key" ] || [ -z "$CF_Email" ]; then
      CF_Key=""
      CF_Email=""
      f5_process_errors "ERROR dns_cf (dns_cf_add): You didn't specify a Cloudflare api key and email yet."
      f5_process_errors "ERROR dns_cf (dns_cf_add): You can get yours from here https://dash.cloudflare.com/profile."
      return 1
    fi

    if ! _contains "$CF_Email" "@"; then
      f5_process_errors "ERROR dns_cf (dns_cf_add): It seems that the CF_Email=$CF_Email is not a valid email address."
      f5_process_errors "ERROR dns_cf (dns_cf_add): Please check and retry."
      return 1
    fi
  fi

  f5_process_errors "DEBUG dns_cf (dns_cf_add): First detect the root zone"
  if ! _get_root "$fulldomain"; then
    f5_process_errors "ERROR dns_cf (dns_cf_add): invalid domain"
    return 1
  fi
  f5_process_errors "DEBUG dns_cf (dns_cf_add): _domain_id: $_domain_id"
  f5_process_errors "DEBUG dns_cf (dns_cf_add): _sub_domain: $_sub_domain"
  f5_process_errors "DEBUG dns_cf (dns_cf_add): _domain: $_domain"
  
  f5_process_errors "DEBUG dns_cf (dns_cf_add): Getting txt records"
  _cf_rest GET "zones/${_domain_id}/dns_records?type=TXT&name=$fulldomain"

  if ! echo "$response" | tr -d " " | grep \"success\":true >/dev/null; then
    f5_process_errors "ERROR dns_cf (dns_cf_add): Error"
    return 1
  fi

  # For wildcard cert, the main root domain and the wildcard domain have the same txt subdomain name, so
  # we can not use updating anymore.
  #  count=$(printf "%s\n" "$response" | _egrep_o "\"count\":[^,]*" | cut -d : -f 2)
  #  f5_process_errors "DEBUG dns_cf (_cf_rest): count $count"
  #  if [ "$count" = "0" ]; then
  f5_process_errors "INFO dns_cf (dns_cf_add): Adding record"
  if _cf_rest POST "zones/$_domain_id/dns_records" "{\"type\":\"TXT\",\"name\":\"$fulldomain\",\"content\":\"$txtvalue\",\"ttl\":120}"; then
    if _contains "$response" "$txtvalue"; then
      f5_process_errors "INFO dns_cf (dns_cf_add): Added, OK"
      return 0
    elif _contains "$response" "The record already exists" ||
      _contains "$response" "An identical record already exists." ||
      _contains "$response" '"code":81058'; then
      f5_process_errors "INFO dns_cf (dns_cf_add): Already exists, OK"
      return 0
    else
      f5_process_errors "ERROR dns_cf (dns_cf_add): Add txt record error."
      return 1
    fi
  fi
  f5_process_errors "ERROR dns_cf (dns_cf_add): Add txt record error."
  return 1
}

#fulldomain txtvalue
dns_cf_rm() {
  fulldomain=$1
  txtvalue=$2

  f5_process_errors "DEBUG dns_cf (dns_cf_rm): First detect the root zone"
  if ! _get_root "$fulldomain"; then
    f5_process_errors "ERROR dns_cf (dns_cf_rm): invalid domain"
    return 1
  fi
  f5_process_errors "DEBUG dns_cf (dns_cf_rm): _domain_id: $_domain_id"
  f5_process_errors "DEBUG dns_cf (dns_cf_rm): _sub_domain: $_sub_domain"
  f5_process_errors "DEBUG dns_cf (dns_cf_rm): _domain: $_domain"

  f5_process_errors "DEBUG dns_cf (dns_cf_rm): Getting txt records"
  _cf_rest GET "zones/${_domain_id}/dns_records?type=TXT&name=$fulldomain&content=$txtvalue"

  if ! echo "$response" | tr -d " " | grep \"success\":true >/dev/null; then
    f5_process_errors "ERROR dns_cf (dns_cf_rm): Error: $response"
    return 1
  fi

  count=$(echo "$response" | _egrep_o "\"count\": *[^,]*" | cut -d : -f 2 | tr -d " ")
  f5_process_errors "DEBUG dns_cf (dns_cf_rm): count $count"
  if [ "$count" = "0" ]; then
    f5_process_errors "DEBUG dns_cf (dns_cf_rm): Don't need to remove."
  else
    record_id=$(echo "$response" | _egrep_o "\"id\": *\"[^\"]*\"" | cut -d : -f 2 | tr -d \" | _head_n 1 | tr -d " ")
    f5_process_errors "DEBUG dns_cf (dns_cf_rm): record_id $record_id"
    if [ -z "$record_id" ]; then
      f5_process_errors "ERROR dns_cf (dns_cf_rm): Can not get record id to remove."
      return 1
    fi
    if ! _cf_rest DELETE "zones/$_domain_id/dns_records/$record_id"; then
      f5_process_errors "ERROR dns_cf (dns_cf_rm): Delete record error."
      return 1
    fi
    echo "$response" | tr -d " " | grep \"success\":true >/dev/null
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
  i=1
  p=1

  # Use Zone ID directly if provided
  if [ "$CF_Zone_ID" ]; then
    if ! _cf_rest GET "zones/$CF_Zone_ID"; then
      return 1
    else
      if echo "$response" | tr -d " " | grep \"success\":true >/dev/null; then
        _domain=$(echo "$response" | _egrep_o "\"name\": *\"[^\"]*\"" | cut -d : -f 2 | tr -d \" | _head_n 1 | tr -d " ")
        if [ "$_domain" ]; then
          _cutlength=$((${#domain} - ${#_domain} - 1))
          _sub_domain=$(printf "%s" "$domain" | cut -c "1-$_cutlength")
          _domain_id=$CF_Zone_ID
          return 0
        else
          return 1
        fi
      else
        return 1
      fi
    fi
  fi

  while true; do
    h=$(printf "%s" "$domain" | cut -d . -f "$i"-100)
    f5_process_errors "DEBUG dns_cf (_get_root): h $h"
    if [ -z "$h" ]; then
      #not valid
      return 1
    fi

    if [ "$CF_Account_ID" ]; then
      if ! _cf_rest GET "zones?name=$h&account.id=$CF_Account_ID"; then
        return 1
      fi
    else
      if ! _cf_rest GET "zones?name=$h"; then
        return 1
      fi
    fi

    if _contains "$response" "\"name\":\"$h\"" || _contains "$response" '"total_count":1'; then
      _domain_id=$(echo "$response" | _egrep_o "\[.\"id\": *\"[^\"]*\"" | _head_n 1 | cut -d : -f 2 | tr -d \" | tr -d " ")
      if [ "$_domain_id" ]; then
        _sub_domain=$(printf "%s" "$domain" | cut -d . -f 1-"$p")
        _domain=$h
        return 0
      fi
      return 1
    fi
    p=$i
    i=$(_math "$i" + 1)
  done
  return 1
}

_cf_rest() {
  m=$1
  ep="$2"
  data="$3"
  f5_process_errors "DEBUG dns_cf (_cf_rest): $ep"

  email_trimmed=$(echo "$CF_Email" | tr -d '"')
  key_trimmed=$(echo "$CF_Key" | tr -d '"')
  token_trimmed=$(echo "$CF_Token" | tr -d '"')

  export _H1="Content-Type: application/json"
  if [ "$token_trimmed" ]; then
    export _H2="Authorization: Bearer $token_trimmed"
    if [ "$m" == "POST" ]; then
      f5_process_errors "DEBUG dns_cf (_cf_rest): POST data: $data"
      response="$(curl -sk -X POST -H "$_H1" -H "$_H2" "$CF_Api/$ep" -d "$data")"
    elif [ "$m" == "DELETE" ]; then
      f5_process_errors "DEBUG dns_cf (_cf_rest): DELETE"
      response="$(curl -sk -X DELETE -H "$_H1" -H "$_H2" "$CF_Api/$ep")"
    else
      f5_process_errors "DEBUG dns_cf (_cf_rest): GET"
      response="$(curl -sk -H "$_H1" -H "$_H2" "$CF_Api/$ep")"
    fi
  else
    export _H2="X-Auth-Email: $email_trimmed"
    export _H3="X-Auth-Key: $key_trimmed"
    if [ "$m" == "POST" ]; then
      f5_process_errors "DEBUG dns_cf (_cf_rest): POST data: $data"
      response="$(curl -sk -X POST -H "$_H1" -H "$_H2" -H "$_H3" "$CF_Api/$ep" -d "$data")"
    elif [ "$m" == "DELETE" ]; then
      f5_process_errors "DEBUG dns_cf (_cf_rest): DELETE"
      response="$(curl -sk -X DELETE -H "$_H1" -H "$_H2" -H "$_H3" "$CF_Api/$ep")"
    else
      f5_process_errors "DEBUG dns_cf (_cf_rest): GET"
      response="$(curl -sk -H "$_H1" -H "$_H2" -H "$_H3" "$CF_Api/$ep")"
    fi
  fi

  if [ "$?" != "0" ]; then
    f5_process_errors "ERROR dns_cf (_cf_rest): error $ep"
    return 1
  fi
  f5_process_errors "DEBUG dns_cf (_cf_rest): response $response"
  return 0
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

_head_n() {
  head -n "$1"
}
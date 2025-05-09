#!/usr/bin/env sh
## DNSAPI: DuckDNS
## Gratuitously borrowed from acme.sh and modified for local use
## Maintainer: kevin-at-f5-dot-com
## Version: 1
## Issues: https://github.com/f5devcentral/kojot-acme/issues
## Add the following information to your provider config file:
##   DNSAPI=dns_duckdns
##   DuckDNS_Token='dnsimple_o_jqOSwe32erx23dc34fdcscxverg4513d'      <-- Your DuckDNS API token

dns_duckdns_info='DuckDNS.org
Site: www.DuckDNS.org
Docs: https://www.duckdns.org/spec.jsp
Docs: github.com/acmesh-official/acme.sh/wiki/dnsapi#dns_duckdns
Options:
 DuckDNS_Token API Token
Original Author: RaidenII
'

DuckDNS_API="https://www.duckdns.org/update"

########  Public functions ######################

#Usage: dns_duckdns_add _acme-challenge.domain.duckdns.org "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
dns_duckdns_add() {
  fulldomain=$1
  txtvalue=$2

  if [ -z "$DuckDNS_Token" ]; then
    f5_process_errors "ERROR dns_duckdns: You must export variable: DuckDNS_Token"
    f5_process_errors "ERROR dns_duckdns: The token for your DuckDNS account is necessary."
    f5_process_errors "ERROR dns_duckdns: You can look it up in your DuckDNS account."
    return 1
  fi

  # Unfortunately, DuckDNS does not seems to support lookup domain through API
  # So I assume your credentials (which are your domain and token) are correct
  # If something goes wrong, we will get a KO response from DuckDNS

  if ! _duckdns_get_domain; then
    return 1
  fi

  # Now add the TXT record to DuckDNS
  f5_process_errors "DEBUG dns_duckdns: Trying to add TXT record"
  if _duckdns_rest GET "domains=$_duckdns_domain&token=$DuckDNS_Token&txt=$txtvalue"; then
    if [ "$response" = "OK" ]; then
      f5_process_errors "DEBUG dns_duckdns: TXT record has been successfully added to your DuckDNS domain."
      f5_process_errors "DEBUG dns_duckdns: Note that all subdomains under this domain uses the same TXT record."
      return 0
    else
      f5_process_errors "ERROR dns_duckdns: Errors happened during adding the TXT record, response=$response"
      return 1
    fi
  else
    f5_process_errors "ERROR dns_duckdns: Errors happened during adding the TXT record."
    return 1
  fi
}

#Usage: fulldomain txtvalue
#Remove the txt record after validation.
dns_duckdns_rm() {
  fulldomain=$1
  txtvalue=$2

  DuckDNS_Token="${DuckDNS_Token:-$(_readaccountconf_mutable DuckDNS_Token)}"
  if [ -z "$DuckDNS_Token" ]; then
    f5_process_errors "ERROR dns_duckdns: You must export variable: DuckDNS_Token"
    f5_process_errors "ERROR dns_duckdns: The token for your DuckDNS account is necessary."
    f5_process_errors "ERROR dns_duckdns: You can look it up in your DuckDNS account."
    return 1
  fi

  if ! _duckdns_get_domain; then
    return 1
  fi

  # Now remove the TXT record from DuckDNS
  f5_process_errors "DEBUG dns_duckdns: Trying to remove TXT record"
  if _duckdns_rest GET "domains=$_duckdns_domain&token=$DuckDNS_Token&txt=&clear=true"; then
    if [ "$response" = "OK" ]; then
      f5_process_errors "DEBUG dns_duckdns: TXT record has been successfully removed from your DuckDNS domain."
      return 0
    else
      f5_process_errors "ERROR dns_duckdns: Errors happened during removing the TXT record, response=$response"
      return 1
    fi
  else
    f5_process_errors "ERROR dns_duckdns: Errors happened during removing the TXT record."
    return 1
  fi
}

####################  Private functions below ##################################

# fulldomain may be 'domain.duckdns.org' (if using --domain-alias) or '_acme-challenge.domain.duckdns.org'
# either way, return 'domain'. (duckdns does not allow further subdomains and restricts domains to [a-z0-9-].)
_duckdns_get_domain() {

  # We'll extract the domain/username from full domain
  _duckdns_domain="$(printf "%s" "$fulldomain" | _lower_case | _egrep_o '^(_acme-challenge\.)?([a-z0-9-]+\.)+duckdns\.org' | sed -n 's/^\([^.]\{1,\}\.\)*\([a-z0-9-]\{1,\}\)\.duckdns\.org$/\2/p;')"

  if [ -z "$_duckdns_domain" ]; then
    f5_process_errors "ERROR dns_duckdns: Error extracting the domain."
    return 1
  fi

  return 0
}

#Usage: method URI
_duckdns_rest() {
  method=$1
  param="$2"
  f5_process_errors "DEBUG dns_duckdns: param: $param"
  url="$DuckDNS_API?$param"
  f5_process_errors "DEBUG dns_duckdns: url: $url"

  # DuckDNS uses GET to update domain info
  if [ "$method" = "GET" ]; then
    response="$(curl -sk -X GET "$url")"
    f5_process_errors "DEBUG dns_duckdns: response: $response"
  else
    f5_process_errors "ERROR dns_duckdns: Unsupported method"
    return 1
  fi
  return 0
}

_lower_case() {
  tr '[A-Z]' '[a-z]'
}

_egrep_o() {
  egrep -o -- "$1" 2>/dev/null
}
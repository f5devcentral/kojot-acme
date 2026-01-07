#!/usr/bin/env sh
## DNSAPI: dns_azure
## Gratuitiously borrowed from acme.sh and modified for local use
## Maintainer: kevin-at-f5-dot-com
## Version: 1
## Issues: https://github.com/f5devcentral/kojot-acme/issues
## Add the following information to your provider config file:
##  AZUREDNS_SUBSCRIPTIONID Subscription ID
##  AZUREDNS_TENANTID Tenant ID
##  AZUREDNS_APPID App ID. App ID of the service principal
##  AZUREDNS_CLIENTSECRET Client Secret. Secret from creating the service principal
##  AZUREDNS_MANAGEDIDENTITY Use Managed Identity. Use Managed Identity assigned to a resource instead of a service principal. "true"/"false"
##  AZUREDNS_BEARERTOKEN Bearer Token. Used instead of service principal credentials or managed identity. Optional.

## Follow the wiki for instructions on setting up a service principal in Azure: https://github.com/acmesh-official/acme.sh/wiki/How-to-use-Azure-DNS
## However, it is still required to separately add the role assignment to the resource group.
## -- From the Azure WebUI, add the AcmeDnsValidator service principal to the resource group (Access Control (IAM) -> Role Assignments)
## -- From the Azure CLI, you can use –scope for a resource group and object-id for principal to add role assignment:
##    az role assignment create --role "DNS Zone Contributor" --scope "/subscriptions/<subscription id>/resourceGroups/<resource-group-name>" --assignee "<service principal object id>"

dns_azure_info='Azure
Site: Azure.microsoft.com
Docs: github.com/acmesh-official/acme.sh/wiki/dnsapi#dns_azure
Options:
 AZUREDNS_SUBSCRIPTIONID Subscription ID
 AZUREDNS_TENANTID Tenant ID
 AZUREDNS_APPID App ID. App ID of the service principal
 AZUREDNS_CLIENTSECRET Client Secret. Secret from creating the service principal
 AZUREDNS_MANAGEDIDENTITY Use Managed Identity. Use Managed Identity assigned to a resource instead of a service principal. "true"/"false"
 AZUREDNS_BEARERTOKEN Bearer Token. Used instead of service principal credentials or managed identity. Optional.
'

wiki=https://github.com/acmesh-official/acme.sh/wiki/How-to-use-Azure-DNS

########  Public functions #####################

# Usage: add  _acme-challenge.www.domain.com   "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
# Used to add txt record
#
# Ref: https://learn.microsoft.com/en-us/rest/api/dns/record-sets/create-or-update?view=rest-dns-2018-05-01&tabs=HTTP
#

dns_azure_add() {
  f5_process_errors "DEBUG dns_azure (dns_azure_add)"
  fulldomain=$1
  txtvalue=$2

  if [ -z "$AZUREDNS_BEARERTOKEN" ]; then
    accesstoken="$(_azure_getaccess_token "$AZUREDNS_MANAGEDIDENTITY" "$AZUREDNS_TENANTID" "$AZUREDNS_APPID" "$AZUREDNS_CLIENTSECRET")"
  else
    accesstoken=$(echo "$AZUREDNS_BEARERTOKEN" | sed "s/Bearer //g")
  fi

  if ! _get_root "$fulldomain" "$AZUREDNS_SUBSCRIPTIONID" "$accesstoken"; then
    f5_process_errors "ERROR dns_azure (dns_azure_add): invalid domain"
    return 1
  fi
  f5_process_errors "DEBUG dns_azure (dns_azure_add): _domain_id: $_domain_id"
  f5_process_errors "DEBUG dns_azure (dns_azure_add): _sub_domain: $_sub_domain"
  f5_process_errors "DEBUG dns_azure (dns_azure_add): _domain: $_domain"

  acmeRecordURI="https://management.azure.com$(printf '%s' "$_domain_id" | sed 's/\\//g')/TXT/$_sub_domain?api-version=2017-09-01"
  f5_process_errors "DEBUG dns_azure (dns_azure_add): $acmeRecordURI"
  # Get existing TXT record
  _azure_rest GET "$acmeRecordURI" "" "$accesstoken"
  values="{\"value\":[\"$txtvalue\"]}"
  timestamp="$(_time)"
  if [ "$_code" = "200" ]; then
    vlist="$(echo "$response" | _egrep_o "\"value\"\\s*:\\s*\\[\\s*\"[^\"]*\"\\s*]" | cut -d : -f 2 | tr -d "[]\"")"
    f5_process_errors "DEBUG dns_azure (dns_azure_add): existing TXT found"
    f5_process_errors "DEBUG dns_azure (dns_azure_add): $vlist"
    existingts="$(echo "$response" | _egrep_o "\"acmetscheck\"\\s*:\\s*\"[^\"]*\"" | _head_n 1 | cut -d : -f 2 | tr -d "\"")"
    if [ -z "$existingts" ]; then
      # the record was not created by acme.sh. Copy the exisiting entires
      existingts=$timestamp
    fi
    _diff="$(_math "$timestamp - $existingts")"
    f5_process_errors "DEBUG dns_azure (dns_azure_add): existing txt age: $_diff"
    # only use recently added records and discard if older than 2 hours because they are probably orphaned
    if [ "$_diff" -lt 7200 ]; then
      f5_process_errors "DEBUG dns_azure (dns_azure_add): existing txt value: $vlist"
      for v in $vlist; do
        values="$values ,{\"value\":[\"$v\"]}"
      done
    fi
  fi
  # Add the txtvalue TXT Record
  body="{\"properties\":{\"metadata\":{\"acmetscheck\":\"$timestamp\"},\"TTL\":10, \"TXTRecords\":[$values]}}"
  _azure_rest PUT "$acmeRecordURI" "$body" "$accesstoken"
  if [ "$_code" = "200" ] || [ "$_code" = '201' ]; then
    f5_process_errors "DEBUG dns_azure (dns_azure_add): validation value added"
    return 0
  else
    f5_process_errors "ERROR dns_azure (dns_azure_add): error adding validation value ($_code)"
    return 1
  fi
}

# Usage: fulldomain txtvalue
# Used to remove the txt record after validation
#
# Ref: https://learn.microsoft.com/en-us/rest/api/dns/record-sets/delete?view=rest-dns-2018-05-01&tabs=HTTP
#
dns_azure_rm() {
  f5_process_errors "DEBUG dns_azure (dns_azure_rm)"
  fulldomain=$1
  txtvalue=$2

  if [ -z "$AZUREDNS_BEARERTOKEN" ]; then
    accesstoken="$(_azure_getaccess_token "$AZUREDNS_MANAGEDIDENTITY" "$AZUREDNS_TENANTID" "$AZUREDNS_APPID" "$AZUREDNS_CLIENTSECRET")"
  else
    accesstoken=$(echo "$AZUREDNS_BEARERTOKEN" | sed "s/Bearer //g")
  fi

  if ! _get_root "$fulldomain" "$AZUREDNS_SUBSCRIPTIONID" "$accesstoken"; then
    f5_process_errors "ERROR dns_azure (dns_azure_rm): invalid domain"
    return 1
  fi
  f5_process_errors "DEBUG dns_azure (dns_azure_rm): _domain_id: $_domain_id"
  f5_process_errors "DEBUG dns_azure (dns_azure_rm): _sub_domain: $_sub_domain"
  f5_process_errors "DEBUG dns_azure (dns_azure_rm): _domain: $_domain"

  acmeRecordURI="https://management.azure.com$(printf '%s' "$_domain_id" | sed 's/\\//g')/TXT/$_sub_domain?api-version=2017-09-01"
  f5_process_errors "DEBUG dns_azure (dns_azure_rm): $acmeRecordURI"
  # Get existing TXT record
  _azure_rest GET "$acmeRecordURI" "" "$accesstoken"
  timestamp="$(_time)"
  if [ "$_code" = "200" ]; then
    vlist="$(echo "$response" | _egrep_o "\"value\"\\s*:\\s*\\[\\s*\"[^\"]*\"\\s*]" | cut -d : -f 2 | tr -d "[]\"" | grep -v -- "$txtvalue")"
    values=""
    comma=""
    for v in $vlist; do
      values="$values$comma{\"value\":[\"$v\"]}"
      comma=","
    done
    if [ -z "$values" ]; then
      # No values left remove record
      f5_process_errors "DEBUG dns_azure (dns_azure_rm): removing validation record completely $acmeRecordURI"
      _azure_rest DELETE "$acmeRecordURI" "" "$accesstoken"
      if [ "$_code" = "200" ] || [ "$_code" = '204' ]; then
        f5_process_errors "DEBUG dns_azure (dns_azure_rm): validation record removed"
      else
        f5_process_errors "ERROR dns_azure (dns_azure_rm): error removing validation record ($_code)"
        return 1
      fi
    else
      # Remove only txtvalue from the TXT Record
      body="{\"properties\":{\"metadata\":{\"acmetscheck\":\"$timestamp\"},\"TTL\":10, \"TXTRecords\":[$values]}}"
      _azure_rest PUT "$acmeRecordURI" "$body" "$accesstoken"
      if [ "$_code" = "200" ] || [ "$_code" = '201' ]; then
        f5_process_errors "DEBUG dns_azure (dns_azure_rm): validation value removed"
        return 0
      else
        f5_process_errors "ERROR dns_azure (dns_azure_rm): error removing validation value ($_code)"
        return 1
      fi
    fi
  fi
}

###################  Private functions below ##################################

_azure_rest() {
  f5_process_errors "DEBUG dns_azure (_azure_rest)"
  m=$1
  ep="$2"
  data="$3"
  accesstoken="$4"
  f5_process_errors "DEBUG dns_azure (_azure_rest): m: $m"
  f5_process_errors "DEBUG dns_azure (_azure_rest): ep: $ep"
  f5_process_errors "DEBUG dns_azure (_azure_rest): data: $data"

  MAX_REQUEST_RETRY_TIMES=5
  _request_retry_times=0
  while [ "${_request_retry_times}" -lt "$MAX_REQUEST_RETRY_TIMES" ]; do
    f5_process_errors "DEBUG dns_azure (_azure_rest): _request_retry_times: $_request_retry_times"
    export _H1="authorization: Bearer $accesstoken"
    export _H2="accept: application/json"
    export _H3="Content-Type: application/json"
    # clear headers from previous request to avoid getting wrong http code on timeouts
    # : >"$HTTP_HEADER"
    # echo "m = $m"
    # echo "_H1 = $_H1"
    if [ "$m" == "POST" ]; then
      f5_process_errors "DEBUG dns_azure (_azure_rest): POST data: $data"
      response="$(curl -sk -w "%{http_code}" -X POST -H "Content-Type: application/json" -H "Accept: application/json" -H "$_H1" "$ep" -d "$data")"
    elif [ "$m" == "PUT" ]; then
      f5_process_errors "DEBUG dns_azure (_azure_rest): PUT data: $data"
      response="$(curl -sk -w "%{http_code}" -X PUT -H "Content-Type: application/json" -H "Accept: application/json" -H "$_H1" "$ep" -d "$data")"
    elif [ "$m" == "DELETE" ]; then
      f5_process_errors "DEBUG dns_azure (_azure_rest): DELETE"
      response="$(curl -sk -w "%{http_code}" -X DELETE -H "Content-Type: application/json" -H "Accept: application/json" -H "$_H1" "$ep")"
    else
      f5_process_errors "DEBUG dns_azure (_azure_rest): GET"
      response="$(curl -sk -w "%{http_code}" -X GET -H "Accept: application/json" -H "$_H1" "$ep")"
      if [ "$response" = "{\"value\":[]}" ]; then
        f5_process_errors "ERROR dns_azure (_azure_getaccess_token): Azure returned empty dns zone list, check Azure IAM Role Assignments for resource group"
      fi
    fi
    _ret="$?"
    _code=${response: -3}
    f5_process_errors "DEBUG dns_azure (_azure_rest): http response code: $_code"
    if [ "$_code" = "401" ]; then
      # we have an invalid access token set to expired
      f5_process_errors "ERROR dns_azure (_azure_rest): Access denied. Invalid access token. Make sure your Azure settings are correct. See: $wiki"
      return 1
    fi
    # See https://learn.microsoft.com/en-us/azure/architecture/best-practices/retry-service-specific#general-rest-and-retry-guidelines for retryable HTTP codes
    if [ "$_ret" != "0" ] || [ -z "$_code" ] || [ "$_code" = "408" ] || [ "$_code" = "500" ] || [ "$_code" = "503" ] || [ "$_code" = "504" ]; then
      _request_retry_times="$(_math "$_request_retry_times" + 1)"
      f5_process_errors "ERROR dns_azure (_azure_rest): REST call error $_code retrying $ep in $_request_retry_times s"
      _sleep "$_request_retry_times"
      continue
    fi
    break
  done
  if [ "$_request_retry_times" = "$MAX_REQUEST_RETRY_TIMES" ]; then
    f5_process_errors "ERROR dns_azure (_azure_rest): Error Azure REST called was retried $MAX_REQUEST_RETRY_TIMES times."
    f5_process_errors "ERROR dns_azure (_azure_rest): Calling $ep failed."
    return 1
  fi
  response="$(echo "$response" | _normalizeJson)"
  return 0
}

## Ref: https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow#request-an-access-token
_azure_getaccess_token() {
  managedIdentity="$1"
  tenantID="$2"
  clientID="$3"
  clientSecret="$4"

  #   accesstoken="${AZUREDNS_ACCESSTOKEN}"
  #   expires_on="${AZUREDNS_TOKENVALIDTO}"

  # can we reuse the bearer token?
  if [ -n "$accesstoken" ] && [ -n "$expires_on" ]; then
    if [ "$(_time)" -lt "$expires_on" ]; then
      # brearer token is still valid - reuse it
      printf "%s" "$accesstoken"
      return 0
    fi
  fi

  if [ "$managedIdentity" = true ]; then
    # https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/how-to-use-vm-token#get-a-token-using-http
    if [ -n "$IDENTITY_ENDPOINT" ]; then
      # Some Azure environments may set IDENTITY_ENDPOINT (formerly MSI_ENDPOINT) to have an alternative metadata endpoint
      url="$IDENTITY_ENDPOINT?api-version=2019-08-01&resource=https://management.azure.com/"
      headers="X-IDENTITY-HEADER: $IDENTITY_HEADER"
    else
      url="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/"
      headers="Metadata: true"
    fi

    export _H1="$headers"
    response="$(curl -sk -X GET "$url")"
    response="$(echo "$response" | _normalizeJson)"
    accesstoken=$(echo "$response" | _egrep_o "\"access_token\":\"[^\"]*\"" | _head_n 1 | cut -d : -f 2 | tr -d \")
    expires_on=$(echo "$response" | _egrep_o "\"expires_on\":\"[^\"]*\"" | _head_n 1 | cut -d : -f 2 | tr -d \")
  else
    export _H1="accept: application/json"
    export _H2="Content-Type: application/x-www-form-urlencoded"
    body="resource=$(printf "%s" 'https://management.core.windows.net/' | _url_encode)&client_id=$(printf "%s" "$clientID" | _url_encode)&client_secret=$(printf "%s" "$clientSecret" | _url_encode)&grant_type=client_credentials"
    # body="client_id=$(printf "%s" "$clientID" | _url_encode)&client_secret=$(printf "%s" "$clientSecret" | _url_encode)&grant_type=client_credentials&scope=https://management.azure.com/.default"
    # echo "body :::: $body"
    # f5_process_errors "DEBUG dns_azure: data $body"
    # response="$(_post "$body" "https://login.microsoftonline.com/$tenantID/oauth2/token" "" "POST")"
    # echo "https://login.microsoftonline.com/$tenantID/oauth2/token"
    response="$(curl -sk -X POST -H "$_H1" -H "$_H2" "https://login.microsoftonline.com/$tenantID/oauth2/token" -d "$body")"
    _ret="$?"
    response="$(echo "$response" | _normalizeJson)"
    accesstoken=$(echo "$response" | _egrep_o "\"access_token\":\"[^\"]*\"" | _head_n 1 | cut -d : -f 2 | tr -d \")
    expires_on=$(echo "$response" | _egrep_o "\"expires_on\":\"[^\"]*\"" | _head_n 1 | cut -d : -f 2 | tr -d \")
  fi

  if [ -z "$accesstoken" ]; then
    f5_process_errors "ERROR dns_azure (_azure_getaccess_token): No acccess token received. Check your Azure settings. See: $wiki"
    return 1
  fi
  if [ "$_ret" != "0" ]; then
    f5_process_errors "ERROR dns_azure (_azure_getaccess_token): error $response"
    return 1
  fi
  printf "%s" "$accesstoken"
  return 0
}

_get_root() {
  f5_process_errors "DEBUG dns_azure (_get_root)"
  domain=$1
  subscriptionId=$2
  accesstoken=$3

  i=1
  p=1

  ## Ref: https://learn.microsoft.com/en-us/rest/api/dns/zones/list?view=rest-dns-2018-05-01&tabs=HTTP
  ## returns up to 100 zones in one response. Handling more results is not implemented
  ## (ZoneListResult with continuation token for the next page of results)
  ##
  ## TODO: handle more than 100 results, as per:
  ## https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits#azure-dns-limits
  ## The new limit is 250 Public DNS zones per subscription, while the old limit was only 100
  ##

  response="$(curl -sk -X GET -H "Content-Type: application/json" -H "Accept: application/json" -H "Authorization: Bearer ${accesstoken}" "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Network/dnszones?api-version=2018-05-01")"

  # Find matching domain name in Json response
  h=$(printf "%s" "$domain" | cut -d . -f "$i"-100)
  while true; do
    h=$(printf "%s" "$domain" | cut -d . -f "$i"-100)
    f5_process_errors "DEBUG dns_azure (_get_root): Checking domain: $h"
    if [ -z "$h" ]; then
      #not valid
      return 1
    fi

    if _contains "$response" "\"name\":\"$h\"" >/dev/null; then
      _domain_id=$(echo "$response" | _egrep_o "\\{\"id\":\"[^\"]*\\/$h\"" | head -n 1 | cut -d : -f 2 | tr -d \")
      if [ "$_domain_id" ]; then
        if [ "$i" = 1 ]; then
          #create the record at the domain apex (@) if only the domain name was provided as --domain-alias
          _sub_domain="@"
        else
          _sub_domain=$(echo "$domain" | cut -d . -f 1-"$p")
        fi
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

_head_n() {
  head -n "$1"
}

_normalizeJson() {
  sed "s/\" *: *\([\"{\[]\)/\":\1/g" | sed "s/^ *\([^ ]\)/\1/" | tr -d "\r\n"
}

_time() {
  date -u "+%s"
}

_url_encode() {
  _upper_hex=$1
  _hex_str=$(_hex_dump)
  for _hex_code in $_hex_str; do
    #upper case
    case "${_hex_code}" in
    "41")
      printf "%s" "A"
      ;;
    "42")
      printf "%s" "B"
      ;;
    "43")
      printf "%s" "C"
      ;;
    "44")
      printf "%s" "D"
      ;;
    "45")
      printf "%s" "E"
      ;;
    "46")
      printf "%s" "F"
      ;;
    "47")
      printf "%s" "G"
      ;;
    "48")
      printf "%s" "H"
      ;;
    "49")
      printf "%s" "I"
      ;;
    "4a")
      printf "%s" "J"
      ;;
    "4b")
      printf "%s" "K"
      ;;
    "4c")
      printf "%s" "L"
      ;;
    "4d")
      printf "%s" "M"
      ;;
    "4e")
      printf "%s" "N"
      ;;
    "4f")
      printf "%s" "O"
      ;;
    "50")
      printf "%s" "P"
      ;;
    "51")
      printf "%s" "Q"
      ;;
    "52")
      printf "%s" "R"
      ;;
    "53")
      printf "%s" "S"
      ;;
    "54")
      printf "%s" "T"
      ;;
    "55")
      printf "%s" "U"
      ;;
    "56")
      printf "%s" "V"
      ;;
    "57")
      printf "%s" "W"
      ;;
    "58")
      printf "%s" "X"
      ;;
    "59")
      printf "%s" "Y"
      ;;
    "5a")
      printf "%s" "Z"
      ;;

      #lower case
    "61")
      printf "%s" "a"
      ;;
    "62")
      printf "%s" "b"
      ;;
    "63")
      printf "%s" "c"
      ;;
    "64")
      printf "%s" "d"
      ;;
    "65")
      printf "%s" "e"
      ;;
    "66")
      printf "%s" "f"
      ;;
    "67")
      printf "%s" "g"
      ;;
    "68")
      printf "%s" "h"
      ;;
    "69")
      printf "%s" "i"
      ;;
    "6a")
      printf "%s" "j"
      ;;
    "6b")
      printf "%s" "k"
      ;;
    "6c")
      printf "%s" "l"
      ;;
    "6d")
      printf "%s" "m"
      ;;
    "6e")
      printf "%s" "n"
      ;;
    "6f")
      printf "%s" "o"
      ;;
    "70")
      printf "%s" "p"
      ;;
    "71")
      printf "%s" "q"
      ;;
    "72")
      printf "%s" "r"
      ;;
    "73")
      printf "%s" "s"
      ;;
    "74")
      printf "%s" "t"
      ;;
    "75")
      printf "%s" "u"
      ;;
    "76")
      printf "%s" "v"
      ;;
    "77")
      printf "%s" "w"
      ;;
    "78")
      printf "%s" "x"
      ;;
    "79")
      printf "%s" "y"
      ;;
    "7a")
      printf "%s" "z"
      ;;
      #numbers
    "30")
      printf "%s" "0"
      ;;
    "31")
      printf "%s" "1"
      ;;
    "32")
      printf "%s" "2"
      ;;
    "33")
      printf "%s" "3"
      ;;
    "34")
      printf "%s" "4"
      ;;
    "35")
      printf "%s" "5"
      ;;
    "36")
      printf "%s" "6"
      ;;
    "37")
      printf "%s" "7"
      ;;
    "38")
      printf "%s" "8"
      ;;
    "39")
      printf "%s" "9"
      ;;
    "2d")
      printf "%s" "-"
      ;;
    "5f")
      printf "%s" "_"
      ;;
    "2e")
      printf "%s" "."
      ;;
    "7e")
      printf "%s" "~"
      ;;
    #other hex
    *)
      if [ "$_upper_hex" = "upper-hex" ]; then
        _hex_code=$(printf "%s" "$_hex_code" | _upper_case)
      fi
      printf '%%%s' "$_hex_code"
      ;;
    esac
  done
}

_hex_dump() {
  if _exists od; then
    od -A n -v -t x1 | tr -s " " | sed 's/ $//' | tr -d "\r\t\n"
  elif _exists hexdump; then
    hexdump -v -e '/1 ""' -e '/1 " %02x" ""'
  elif _exists xxd; then
    xxd -ps -c 20 -i | sed "s/ 0x/ /g" | tr -d ",\n" | tr -s " "
  else
    str=$(cat)
    _ascii_hex "$str"
  fi
}

_exists() {
  cmd="$1"
  if [ -z "$cmd" ]; then
    return 1
  fi

  if eval type type >/dev/null 2>&1; then
    eval type "$cmd" >/dev/null 2>&1
  elif command >/dev/null 2>&1; then
    command -v "$cmd" >/dev/null 2>&1
  else
    which "$cmd" >/dev/null 2>&1
  fi
  ret="$?"
  return $ret
}

_ascii_hex() {
  _str="$1"
  _str_len=${#_str}
  _h_i=1
  while [ "$_h_i" -le "$_str_len" ]; do
    _str_c="$(printf "%s" "$_str" | cut -c "$_h_i")"
    printf " %02x" "'$_str_c"
    _h_i="$(_math "$_h_i" + 1)"
  done
}

_sleep() {
  _sleep_sec="$1"
  if [ "$__INTERACTIVE" ]; then
    _sleep_c="$_sleep_sec"
    while [ "$_sleep_c" -ge "0" ]; do
      printf "\r      \r"
      __green "$_sleep_c"
      _sleep_c="$(_math "$_sleep_c" - 1)"
      sleep 1
    done
    printf "\r"
  else
    sleep "$_sleep_sec"
  fi
}

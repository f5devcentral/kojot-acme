#!/usr/bin/env sh
## DNSAPI: dns_aws
## Gratuitiously borrowed from acme.sh and modified for local use
## Maintainer: kevin-at-f5-dot-com
## Version: 1
## Issues: https://github.com/f5devcentral/kojot-acme/issues
## Add the following information to your provider config file:
##  AWS_ACCESS_KEY_ID API Key ID
##  AWS_SECRET_ACCESS_KEY API Secret
##  AWS_SESSION_TOKEN Session Token
##  AWS_DNS_SLOWRATE (optional) Sleep interval after TXT record update, in seconds (default: 10)

dns_aws_info='Amazon AWS Route53 domain API
Site: docs.aws.amazon.com/route53/
Docs: github.com/acmesh-official/acme.sh/wiki/dnsapi#dns_aws
Options:
 AWS_ACCESS_KEY_ID API Key ID
 AWS_SECRET_ACCESS_KEY API Secret
 AWS_SESSION_TOKEN Session Token
 AWS_DNS_SLOWRATE (optional) Sleep interval after TXT record update, in seconds (default: 1)
'

# All `_sleep` commands are included to avoid Route53 throttling, see
# https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/DNSLimitations.html#limits-api-requests

AWS_HOST="route53.amazonaws.com"
AWS_URL="https://$AWS_HOST"

AWS_WIKI="https://github.com/acmesh-official/acme.sh/wiki/How-to-use-Amazon-Route53-API"

########  Public functions #####################

#Usage: dns_myapi_add   _acme-challenge.www.domain.com   "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
dns_aws_add() {
  fulldomain=$1
  txtvalue=$2

  if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    _use_container_role || _use_instance_role
  fi

  if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    AWS_ACCESS_KEY_ID=""
    AWS_SECRET_ACCESS_KEY=""
    f5_process_errors "ERROR dns_aws (dns_aws_add): You haven't specified the aws route53 api key id and and api key secret yet."
    f5_process_errors "ERROR dns_aws (dns_aws_add): Please create your key and try again. see $($AWS_WIKI)"
    return 1
  fi

  f5_process_errors "DEBUG dns_aws (dns_aws_add): First detect the root zone"
  if ! _get_root "$fulldomain"; then
    _sleep 1
    return 1
  fi
  f5_process_errors "DEBUG dns_aws (dns_aws_add): _domain_id: $_domain_id"
  f5_process_errors "DEBUG dns_aws (dns_aws_add): _sub_domain: $_sub_domain"
  f5_process_errors "DEBUG dns_aws (dns_aws_add): _domain: $_domain"

  f5_process_errors "DEBUG dns_aws (dns_aws_add): Getting existing records for $fulldomain"
  if ! aws_rest GET "2013-04-01$_domain_id/rrset" "name=$fulldomain&type=TXT"; then
    _sleep 1
    return 1
  fi

  if _contains "$response" "<Name>$fulldomain.</Name>"; then
    _resource_record="$(echo "$response" | sed 's/<ResourceRecordSet>/"/g' | tr '"' "\n" | grep "<Name>$fulldomain.</Name>" | _egrep_o "<ResourceRecords.*</ResourceRecords>" | sed "s/<ResourceRecords>//" | sed "s#</ResourceRecords>##")"
    f5_process_errors "DEBUG dns_aws (dns_aws_add): _resource_record: $_resource_record"
  else
    f5_process_errors "DEBUG dns_aws (dns_aws_add): single new add"
  fi

  if [ "$_resource_record" ] && _contains "$response" "$txtvalue"; then
    _sleep 1
    return 0
  fi

  f5_process_errors "DEBUG dns_aws (dns_aws_add): Adding records"

  _aws_tmpl_xml="<ChangeResourceRecordSetsRequest xmlns=\"https://route53.amazonaws.com/doc/2013-04-01/\"><ChangeBatch><Changes><Change><Action>UPSERT</Action><ResourceRecordSet><Name>$fulldomain</Name><Type>TXT</Type><TTL>300</TTL><ResourceRecords>$_resource_record<ResourceRecord><Value>\"$txtvalue\"</Value></ResourceRecord></ResourceRecords></ResourceRecordSet></Change></Changes></ChangeBatch></ChangeResourceRecordSetsRequest>"

  if aws_rest POST "2013-04-01$_domain_id/rrset/" "" "$_aws_tmpl_xml" && _contains "$response" "ChangeResourceRecordSetsResponse"; then
    f5_process_errors "DEBUG dns_aws (dns_aws_add): TXT record updated successfully."
    if [ -n "$AWS_DNS_SLOWRATE" ]; then
      f5_process_errors "DEBUG dns_aws (dns_aws_add): Slow rate activated: sleeping for $AWS_DNS_SLOWRATE seconds"
      _sleep "$AWS_DNS_SLOWRATE"
    else
      _sleep 10
    fi

    return 0
  fi
  _sleep 1
  return 1
}

#fulldomain txtvalue
dns_aws_rm() {
  fulldomain=$1
  txtvalue=$2

  if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    _use_container_role || _use_instance_role
  fi

  f5_process_errors "DEBUG dns_aws (dns_aws_rm): First detect the root zone"
  if ! _get_root "$fulldomain"; then
    _sleep 1
    return 1
  fi
  f5_process_errors "DEBUG dns_aws (dns_aws_rm): _domain_id: $_domain_id"
  f5_process_errors "DEBUG dns_aws (dns_aws_rm): _sub_domain: $_sub_domain"
  f5_process_errors "DEBUG dns_aws (dns_aws_rm): _domain: $_domain"

  f5_process_errors "DEBUG dns_aws (dns_aws_rm): Getting existing records for $fulldomain"
  if ! aws_rest GET "2013-04-01$_domain_id/rrset" "name=$fulldomain&type=TXT"; then
    _sleep 1
    return 1
  fi

  if _contains "$response" "<Name>$fulldomain.</Name>"; then
    _resource_record="$(echo "$response" | sed 's/<ResourceRecordSet>/"/g' | tr '"' "\n" | grep "<Name>$fulldomain.</Name>" | _egrep_o "<ResourceRecords.*</ResourceRecords>" | sed "s/<ResourceRecords>//" | sed "s#</ResourceRecords>##")"
    f5_process_errors "DEBUG dns_aws (dns_aws_rm): _resource_record: $_resource_record"
  else
    _sleep 1
    return 0
  fi

  _aws_tmpl_xml="<ChangeResourceRecordSetsRequest xmlns=\"https://route53.amazonaws.com/doc/2013-04-01/\"><ChangeBatch><Changes><Change><Action>DELETE</Action><ResourceRecordSet><ResourceRecords>$_resource_record</ResourceRecords><Name>$fulldomain.</Name><Type>TXT</Type><TTL>300</TTL></ResourceRecordSet></Change></Changes></ChangeBatch></ChangeResourceRecordSetsRequest>"

  if aws_rest POST "2013-04-01$_domain_id/rrset/" "" "$_aws_tmpl_xml" && _contains "$response" "ChangeResourceRecordSetsResponse"; then
    f5_process_errors "DEBUG dns_aws (dns_aws_rm): TXT record deleted successfully."
    if [ -n "$AWS_DNS_SLOWRATE" ]; then
      f5_process_errors "DEBUG dns_aws (dns_aws_rm): Slow rate activated: sleeping for $AWS_DNS_SLOWRATE seconds"
      _sleep "$AWS_DNS_SLOWRATE"
    else
      _sleep 10
    fi

    return 0
  fi
  _sleep 1
  return 1
}

####################  Private functions below ##################################

_get_root() {
  domain=$1
  i=1
  p=1

  # iterate over names (a.b.c.d -> b.c.d -> c.d -> d)
  while true; do
    h=$(printf "%s" "$domain" | cut -d . -f "$i"-100 | sed 's/\./\\./g')
    f5_process_errors "DEBUG dns_aws (_get_root): Checking domain: $h"
    if [ -z "$h" ]; then
      return 1
    fi

    # iterate over paginated result for list_hosted_zones
    aws_rest GET "2013-04-01/hostedzone"
    while true; do
      if _contains "$response" "<Name>$h.</Name>"; then
        hostedzone="$(echo "$response" | tr -d '\n' | sed 's/<HostedZone>/#&/g' | tr '#' '\n' | _egrep_o "<HostedZone><Id>[^<]*<.Id><Name>$h.<.Name>.*<PrivateZone>false<.PrivateZone>.*<.HostedZone>")"
        f5_process_errors "DEBUG dns_aws (_get_root): hostedzone: $hostedzone"
        if [ "$hostedzone" ]; then
          _domain_id=$(printf "%s\n" "$hostedzone" | _egrep_o "<Id>.*<.Id>" | head -n 1 | _egrep_o ">.*<" | tr -d "<>")
          if [ "$_domain_id" ]; then
            _sub_domain=$(printf "%s" "$domain" | cut -d . -f 1-"$p")
            _domain=$h
            return 0
          fi
          return 1
        fi
      fi
      if _contains "$response" "<IsTruncated>true</IsTruncated>" && _contains "$response" "<NextMarker>"; then
        f5_process_errors "DEBUG dns_aws (_get_root): IsTruncated"
        _nextMarker="$(echo "$response" | _egrep_o "<NextMarker>.*</NextMarker>" | cut -d '>' -f 2 | cut -d '<' -f 1)"
        f5_process_errors "DEBUG dns_aws (_get_root): NextMarker: $_nextMarker"
      else
        break
      fi
      f5_process_errors "DEBUG dns_aws (_get_root): Checking domain: $h - Next Page "
      aws_rest GET "2013-04-01/hostedzone" "marker=$_nextMarker"
    done
    p=$i
    i=$(_math "$i" + 1)
  done
  return 1
}

_use_container_role() {
  # automatically set if running inside ECS
  if [ -z "$AWS_CONTAINER_CREDENTIALS_RELATIVE_URI" ]; then
    return 1
  fi
  _use_metadata "169.254.170.2$AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"
}

_use_instance_role() {
  _instance_role_name_url="http://169.254.169.254/latest/meta-data/iam/security-credentials/"

  if _get "$_instance_role_name_url" true 1 | _head_n 1 | grep -Fq 401; then
    f5_process_errors "DEBUG dns_aws (_use_instance_role): Using IMDSv2"
    _token_url="http://169.254.169.254/latest/api/token"
    export _H1="X-aws-ec2-metadata-token-ttl-seconds: 21600"
    _token="$(_post "" "$_token_url" "" "PUT")"
    f5_process_errors "DEBUG dns_aws (_use_instance_role): _token: $_token"
    if [ -z "$_token" ]; then
      return 1
    fi
    export _H1="X-aws-ec2-metadata-token: $_token"
  fi

  if ! _get "$_instance_role_name_url" true 1 | _head_n 1 | grep -Fq 200; then
    return 1
  fi

  _instance_role_name=$(_get "$_instance_role_name_url" "" 1)
  f5_process_errors "DEBUG dns_aws (_use_instance_role): _instance_role_name: $_instance_role_name"
  _use_metadata "$_instance_role_name_url$_instance_role_name" "$_token"

}

_use_metadata() {
  export _H1="X-aws-ec2-metadata-token: $2"
  _aws_creds="$(
    _get "$1" "" 1 |
      _normalizeJson |
      tr '{,}' '\n' |
      while read -r _line; do
        _key="$(echo "${_line%%:*}" | tr -d '\"')"
        _value="${_line#*:}"
        f5_process_errors "DEBUG dns_aws (_use_metadata): _key: $_key"
        f5_process_errors "DEBUG dns_aws (_use_metadata): _value: $_value"
        case "$_key" in
        AccessKeyId) echo "AWS_ACCESS_KEY_ID=$_value" ;;
        SecretAccessKey) echo "AWS_SECRET_ACCESS_KEY=$_value" ;;
        Token) echo "AWS_SESSION_TOKEN=$_value" ;;
        esac
      done |
      paste -sd' ' -
  )"
  f5_process_errors "DEBUG dns_aws (_use_metadata): _aws_creds: $_aws_creds"

  if [ -z "$_aws_creds" ]; then
    return 1
  fi

  eval "$_aws_creds"
  _using_role=true
}

#method uri qstr data
aws_rest() {
  mtd="$1"
  ep="$2"
  qsr="$3"
  data="$4"

  f5_process_errors "DEBUG dns_aws (aws_rest): mtd: $mtd"
  f5_process_errors "DEBUG dns_aws (aws_rest): ep: $ep"
  f5_process_errors "DEBUG dns_aws (aws_rest): qsr: $qsr"
  f5_process_errors "DEBUG dns_aws (aws_rest): data: $data"

  CanonicalURI="/$ep"
  CanonicalQueryString="$qsr"
  RequestDate="$(date -u +"%Y%m%dT%H%M%SZ")"
  #RequestDate="20161120T141056Z" ##############

  export _H1="x-amz-date: $RequestDate"

  aws_host="$AWS_HOST"
  CanonicalHeaders="host:$aws_host\nx-amz-date:$RequestDate\n"
  SignedHeaders="host;x-amz-date"
  if [ -n "$AWS_SESSION_TOKEN" ]; then
    export _H3="x-amz-security-token: $AWS_SESSION_TOKEN"
    CanonicalHeaders="${CanonicalHeaders}x-amz-security-token:$AWS_SESSION_TOKEN\n"
    SignedHeaders="${SignedHeaders};x-amz-security-token"
  fi

  RequestPayload="$data"

  Hash="sha256"

  CanonicalRequest="$mtd\n$CanonicalURI\n$CanonicalQueryString\n$CanonicalHeaders\n$SignedHeaders\n$(printf "%s" "$RequestPayload" | _digest "$Hash" hex)"
  HashedCanonicalRequest="$(printf "$CanonicalRequest%s" | _digest "$Hash" hex)"
  Algorithm="AWS4-HMAC-SHA256"
  RequestDateOnly="$(echo "$RequestDate" | cut -c 1-8)"

  Region="us-east-1"
  Service="route53"

  CredentialScope="$RequestDateOnly/$Region/$Service/aws4_request"
  StringToSign="$Algorithm\n$RequestDate\n$CredentialScope\n$HashedCanonicalRequest"
  kSecret="AWS4$AWS_SECRET_ACCESS_KEY"
  #kSecret="wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" ############################
  kSecretH="$(printf "%s" "$kSecret" | _hex_dump | tr -d " ")"
  kDateH="$(printf "$RequestDateOnly%s" | _hmac "$Hash" "$kSecretH" hex)"
  kRegionH="$(printf "$Region%s" | _hmac "$Hash" "$kDateH" hex)"
  kServiceH="$(printf "$Service%s" | _hmac "$Hash" "$kRegionH" hex)"
  kSigningH="$(printf "%s" "aws4_request" | _hmac "$Hash" "$kServiceH" hex)"
  signature="$(printf "$StringToSign%s" | _hmac "$Hash" "$kSigningH" hex)"
  Authorization="$Algorithm Credential=$AWS_ACCESS_KEY_ID/$CredentialScope, SignedHeaders=$SignedHeaders, Signature=$signature"

  _H2="Authorization: $Authorization"

  url="$AWS_URL/$ep"
  if [ "$qsr" ]; then
    url="$AWS_URL/$ep?$qsr"
  fi

  if [ "$mtd" = "GET" ]; then
    response="$(curl -sk -H "$_H1" -H "$_H2" -H "$_H3" "$url")"
  else
    response="$(curl -sk -X POST -H "$_H1" -H "$_H2" -H "$_H3" "$url" -d "$data")"
  fi

  _ret="$?"
  f5_process_errors "DEBUG dns_aws (aws_rest): response: $response"
  if [ "$_ret" = "0" ]; then
    if _contains "$response" "<ErrorResponse"; then
      f5_process_errors "ERROR dns_aws (aws_rest): Response error: $response"
      return 1
    fi
  fi

  return "$_ret"
}

_egrep_o() {
  egrep -o -- "$1" 2>/dev/null
}

_get() {
  url="$1"
  onlyheaders="$2"
  t="$3"

  ret="$(curl -sk -H "$_H1" -H "$_H2" -H "$_H3" "$url")"
  
  if [ -z "$3" ]; then
    return "$ret"
  else
    return 0
  fi
}

_head_n() {
  head -n "$1"
}

_normalizeJson() {
  sed "s/\" *: *\([\"{\[]\)/\":\1/g" | sed "s/^ *\([^ ]\)/\1/" | tr -d "\r\n"
}

_hmac() {
  alg="$1"
  secret_hex="$2"
  outputhex="$3"

  if [ -z "$secret_hex" ]; then
    return 1
  fi

  if [ "$alg" = "sha256" ] || [ "$alg" = "sha1" ]; then
    if [ "$outputhex" ]; then
      (${ACME_OPENSSL_BIN:-openssl} dgst -"$alg" -mac HMAC -macopt "hexkey:$secret_hex" 2>/dev/null || ${ACME_OPENSSL_BIN:-openssl} dgst -"$alg" -hmac "$(printf "%s" "$secret_hex" | _h2b)") | cut -d = -f 2 | tr -d ' '
    else
      ${ACME_OPENSSL_BIN:-openssl} dgst -"$alg" -mac HMAC -macopt "hexkey:$secret_hex" -binary 2>/dev/null || ${ACME_OPENSSL_BIN:-openssl} dgst -"$alg" -hmac "$(printf "%s" "$secret_hex" | _h2b)" -binary
    fi
  else
    return 1
  fi

}

_digest() {
  alg="$1"
  if [ -z "$alg" ]; then
    return 1
  fi

  outputhex="$2"

  if [ "$alg" = "sha3-256" ] || [ "$alg" = "sha256" ] || [ "$alg" = "sha1" ] || [ "$alg" = "md5" ]; then
    if [ "$outputhex" ]; then
      ${ACME_OPENSSL_BIN:-openssl} dgst -"$alg" -hex | cut -d = -f 2 | tr -d ' '
    else
      ${ACME_OPENSSL_BIN:-openssl} dgst -"$alg" -binary | _base64
    fi
  else
    return 1
  fi

}

_math() {
  _m_opts="$@"
  printf "%s" "$(($_m_opts))"
}

_contains() {
  _str="$1"
  _sub="$2"
  echo "$_str" | grep -- "$_sub" >/dev/null 2>&1
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

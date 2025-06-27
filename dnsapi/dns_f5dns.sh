#!/usr/bin/env sh
## DNSAPI: F5DNS
## Maintainer: kevin-at-f5-dot-com
## Version: 1
## Issues: https://github.com/f5devcentral/kojot-acme/issues
## Add the following information to your provider config file:
##   DNSAPI=dns_f5dns
##   F5DNS_Server='https://10.1.10.20'      <-- Your F5 DNS server
##   F5DNS_TOKEN='2345678987654345678987'   <-- Your shared token
##
## F5 DNS Configuration:
## - Add f5dns_dns_rule to the F5 BIG-IP DNS server
## - Add f5dns_api_rule to the F5 BIG-IP DNS server
## - Create a GTM listener on F5 BIG-IP DNS server
##      - DNS > Delivery > Listeners > GTM Listeners > GTM Listener List
##      - Destination: IP address accessible to the ACME server
##      - Add f5dns_dns_rule
## - Create an HTTP listener on F5 BIG-IP DNS server
##      - DNS > Delivery > Listeners > DoH Proxy Listeners
##      - Destination: IP address accessible to the BIG-IP ACME client
##      - Service Port: HTTPS:443
##      - Client SSL Profile: update accordingly to allow TLS/HTTPS communication from the BIG-IP ACME client (curl)
##      - Add f5dns_api_rule
## - Security & authentication considerations
##      - Update the F5DNS_TOKEN value in the ACME client config to match the BEARERTOKEN value in the f5dns_api_rule iRule
##      - Also consider updating the HTTP API listener and ACME DNS client script to use mutual (client cert) authentication


########## Public Functions ##########

# Usage: add  _acme-challenge.www.domain.com   "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
dns_f5dns_add() {
    fulldomain=$1
    txtvalue=$2

    ## sets subdmain variable
    _get_root "$fulldomain"

    ## Add code here to add the DNS TXT record to the zone.
    ## Return 1 on any errors
    ## Example: for zone .f5labs.com
    ##  _acme-challenge.www = TXT "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
    curl -sk -H "Authorization: Bearer ${F5DNS_TOKEN}" "${F5DNS_SERVER}/records/add" -d "domain=${_subdomain}&token=${txtvalue}"

    return 0
}
# Usage: rm  _acme-challenge.www.domain.com   "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
dns_f5dns_rm() {    
    return 0
}

########## Private Functions ##########

_get_root() {
    domain=$1
    _subdomain=$(printf "%s" "$domain" | cut -d . -f 2-)
    return 0
}

#!/usr/bin/env bash

## Simple Dehydrated Acme (F5 BIG-IP) - Install Utility
## Maintainer: kevin-at-f5-dot-com
## Version: 20231006-1
## Description: Wrapper for Dehydrated Acme client to simplify usage on F5 BIG-IP
##
## Usage:
## - Execute: curl -s https://<this-repo-url>/install.sh | bash


## Set download paths
acmeclient_url="https://raw.githubusercontent.com/dehydrated-io/dehydrated/master"
f5acmehandler_url="https://raw.githubusercontent.com/kevingstewart/simple-dehydrated-acme/main"


## Download and place files
mkdir -p /shared/acme
curl -s ${acmeclient_url}/dehydrated -o /shared/acme/dehydrated && chmod +x /shared/acme/dehydrated
curl -s ${f5acmehandler_url}/f5acmehandler.sh -o /shared/acme/f5acmehandler.sh && chmod +x /shared/acme/f5acmehandler.sh
curl -s ${f5acmehandler_url}/f5hook.sh -o /shared/acme/f5hook.sh && chmod +x /shared/acme/f5hook.sh
curl -s ${f5acmehandler_url}/config -o /shared/acme/config


## Create BIG-IP data groups (dg_acme_challenge, dg_acme_config)
tmsh create ltm data-group internal dg_acme_challenge type string > /dev/null 2>&1
tmsh create ltm data-group internal dg_acme_config type string > /dev/null 2>&1


## Create BIG-IP iRule (acme_handler_rule)
tmsh create ltm rule acme_handler_rule when RULE_INIT { set static::DEBUGACME 0 }\;when HTTP_REQUEST priority 2 {if { [string tolower [HTTP::uri]] starts_with \"/.well-known/acme-challenge/\" } {set response_content [class lookup [substr [HTTP::uri] 28] dg_acme_challenge]\;if { \$response_content ne \"\" } { if { \$static::DEBUGACME } { log local0. \"[IP::client_addr]:[TCP::client_port]-[IP::local_addr]:[TCP::local_port] Good ACME response: \$response_content\" }\;HTTP::respond 200 -version auto content \$response_content noserver Content-Type {text/plain} Content-Length [string length \$response_content] Cache-Control no-store } else { if { \$static::DEBUGACME } { log local0. \"[IP::client_addr]:[TCP::client_port]-[IP::local_addr]:[TCP::local_port] Bad ACME request\" }\;HTTP::respond 503 -version auto content \"\<html\>\<body\>\<h1\>503 - Error\<\/h1\>\<p\>Content not found.\<\/p\>\<\/body\>\<\/html\>\" noserver Content-Type {text/html} Cache-Control no-store }\;unset response_content\;event disable all\;return}} > /dev/null 2>&1


## Copy ca-bundle.crt to working directory
cp $(tmsh list sys file ssl-cert ca-bundle.crt -hidden |grep cache-path | sed -E 's/^\s+cache-path\s//') /shared/acme/ca-bundle.crt


## Create the log file
touch /var/log/acmehandler

return 0

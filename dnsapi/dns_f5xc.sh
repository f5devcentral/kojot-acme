#!/usr/bin/env sh
## DNSAPI: F5XC
## Contributor: fads@f5.com/fadly.tabrani@gmail.com
## Implements:
##  Full DNS-01 challenge support to F5XC
##  Support for both client certificate (P12) and API token authentication
##  Handles DNSSEC-enabled zones with DNS propagation polling
##  Robust error handling with retry logic and exponential backoff
##  Tested across multiple domain scenarios (root, nested, DNSSEC)
##
## Add the following information to your provider config file:
##   DNSAPI=dns_f5xc
##   F5XC_TENANT='your_tenant_name'                 <-- Your F5 XC tenant name
##   F5XC_CLIENT_CERT='path/to/client.p12'          <-- Client certificate file path (P12 format)
##   F5XC_CERT_PASSWORD='your_cert_password'        <-- Password for P12 certificate
##   F5XC_API_TOKEN='your_api_token_here'           <-- Optional: API token (fallback)
##   F5XC_RRSET_IDENTIFIER='your_custom_name'       <-- Optional: Custom RRSet identifier (defaults to hostname)

##
## F5 Distributed Cloud Configuration:
## - Generate API token from F5 XC Console: Settings > API Tokens
## - Ensure the API token has DNS Zone Management permissions
## - Authentication: Client certificates (P12 format, preferred) or API token (fallback)

dns_f5xc_info='F5 Distributed Cloud (F5 XC)
  F5XC_TENANT Tenant Name
  F5XC_CLIENT_CERT Client certificate file path (P12 format, preferred)
  F5XC_CERT_PASSWORD Password for P12 certificate (required if using certificates)
  F5XC_API_TOKEN API Token (fallback)
  F5XC_RRSET_IDENTIFIER Custom RRSet identifier (optional, defaults to hostname)
'

########## Public Functions ##########

# Usage: add  _acme-challenge.www.domain.com   "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
# ADD FUNCTION - UNIQUE IDENTIFIER
dns_f5xc_add() {
    fulldomain="$1"
    txtvalue="$2"
    
    # Configuration variables should be set by environment
    # No need to read from config file as they're passed by the hook script
    
    # Validate configuration early
    if ! _validate_config; then
        return 1
    fi
    
    process_errors "DEBUG dns_f5xc: Adding TXT record for $fulldomain"
    
    # Get root domain and subdomain
    if ! _get_root "$fulldomain"; then
        process_errors "ERROR dns_f5xc: Could not find zone for domain: $fulldomain"
        return 1
    fi
    
    # Use the global variables set by _get_root
    domain="$_domain"
    actual_subdomain="$_subdomain"
    
    process_errors "DEBUG dns_f5xc: Adding TXT record for $actual_subdomain in zone $domain"
    
    # Get current zone configuration
    if ! _f5xc_rest "GET" "/api/config/dns/namespaces/system/dns_zones/$domain"; then
        process_errors "ERROR dns_f5xc: Failed to get zone configuration"
        return 1
    fi
    
    # Use the global response variable
    zone_config="$_F5XC_LAST_RESPONSE"
    
    # Add TXT record to zone configuration
    if ! _add_txt_record_to_zone "$zone_config" "$actual_subdomain" "$txtvalue"; then
        process_errors "ERROR dns_f5xc: Failed to add TXT record to zone"
        return 1
    fi
    
    # Update the zone with the modified configuration
    put_result=$(_f5xc_rest "PUT" "/api/config/dns/namespaces/system/dns_zones/$domain" "$_zone_data")
    put_exit_code=$?
    
    if [ $put_exit_code -eq 2 ]; then
        # Special case: Duplicate TXT record detected
        process_errors "ERROR dns_f5xc: Duplicate TXT record detected - cannot add duplicate"
        return 1
    elif [ $put_exit_code -ne 0 ]; then
        process_errors "ERROR dns_f5xc: Failed to update zone"
        return 1
    fi
    
    # Wait for DNS propagation to authoritative nameservers
    if ! _wait_for_dns_propagation "$domain" "$actual_subdomain" "$txtvalue"; then
        process_errors "WARN dns_f5xc: TXT record not propagated to authoritative nameservers within timeout"
        # Continue anyway - ACME validation will fail if truly not propagated
    fi
    
    process_errors "DEBUG dns_f5xc: Successfully added TXT record"
    return 0
}

# Usage: rm  _acme-challenge.www.domain.com   "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
dns_f5xc_rm() {
    fulldomain="$1"
    txtvalue="$2"
    
    # Configuration variables should be set by environment
    # No need to read from config file as they're passed by the hook script
    
    # Validate configuration early
    if ! _validate_config; then
        return 1
    fi
    
    # Parse domain and subdomain
    if ! _get_root "$fulldomain"; then
        process_errors "ERROR dns_f5xc: invalid domain"
        return 1
    fi

    process_errors "DEBUG dns_f5xc: Removing TXT record for $_subdomain in zone $_domain"

    # Get the current zone configuration
    if ! _f5xc_rest GET "/api/config/dns/namespaces/system/dns_zones/$_domain"; then
        process_errors "ERROR dns_f5xc: Failed to get zone configuration"
        return 1
    fi

    # Parse the zone configuration and remove TXT record
    if ! _remove_txt_record_from_zone "$response" "$_subdomain" "$txtvalue"; then
        process_errors "DEBUG dns_f5xc: No TXT record found to remove for $_subdomain"
        return 0
    fi

    # Update the zone configuration
    put_result=$(_f5xc_rest PUT "/api/config/dns/namespaces/system/dns_zones/$_domain" "$_zone_data")
    put_exit_code=$?
    
    if [ $put_exit_code -eq 2 ]; then
        # Special case: Duplicate TXT record detected (shouldn't happen during removal)
        process_errors "ERROR dns_f5xc: Unexpected duplicate TXT record error during removal"
        return 1
    elif [ $put_exit_code -ne 0 ]; then
        process_errors "ERROR dns_f5xc: Failed to update zone configuration"
        return 1
    fi

    process_errors "DEBUG dns_f5xc: Successfully removed TXT record"
    return 0
}

########## Private Functions ##########

# Parse domain and subdomain from full domain
# _acme-challenge.www.domain.com
# returns
#   _subdomain=_acme-challenge.www
#   _domain=domain.com
_get_root() {
    fulldomain="$1"
    namespace="system" # Hardcode namespace to system
    
    process_errors "DEBUG dns_f5xc: Finding root zone for: $fulldomain"
    
    # Split domain into parts and try to find the zone
    domain="$fulldomain"
    
    while [ -n "$domain" ]; do
        process_errors "DEBUG dns_f5xc: Checking zone: $domain"
        
        # Check if this domain exists as a zone in F5 XC
        # Temporarily redirect stderr to suppress zone discovery errors
        if _f5xc_rest "GET" "/api/config/dns/namespaces/$namespace/dns_zones/$domain" 2>/dev/null; then
            response="$_F5XC_LAST_RESPONSE"
            if echo "$response" | grep -q '"name":\s*"'"$domain"'"' || echo "$response" | grep -q '"name": "'"$domain"'"'; then
                process_errors "DEBUG dns_f5xc: Zone found via API: $domain"
                
                # Extract subdomain (everything to the left of the zone)
                subdomain=""
                if [ "$domain" != "$fulldomain" ]; then
                    subdomain="${fulldomain%.$domain}"
                fi
                
                process_errors "DEBUG dns_f5xc: Subdomain: $subdomain"
                export _domain="$domain"
                export _subdomain="$subdomain"
                return 0
            fi
        fi
        
        # Remove the leftmost part and try again
        old_domain="$domain"
        domain="${domain#*.}"
        
        # Prevent infinite loop: if domain didn't change, break
        if [ "$old_domain" = "$domain" ]; then
            process_errors "DEBUG dns_f5xc: Domain unchanged, breaking loop: $domain"
            break
        fi
    done
    
    process_errors "DEBUG dns_f5xc: No zone found for: $fulldomain"
    return 1
}

# Add TXT record to zone configuration
_add_txt_record_to_zone() {
    zone_config="$1"
    subdomain="$2"
    txt_value="$3"
    
    # Create a machine-specific RRSet name
    machine_id=$(_get_machine_id 2>/dev/null)
    rrset_name="$machine_id"
    
    process_errors "DEBUG dns_f5xc: RRSet name: $rrset_name"
    
    # Parse the zone configuration and add TXT record
    if ! _parse_and_modify_zone "$zone_config" "$subdomain" "$txt_value" "$rrset_name" "add"; then
        return 1
    fi
    
    return 0
}

# Remove TXT record from zone configuration
_remove_txt_record_from_zone() {
    zone_config="$1"
    subdomain="$2"
    txt_value="$3"
    
    # Create a machine-specific RRSet name
    machine_id=$(_get_machine_id 2>/dev/null)
    rrset_name="$machine_id"
    
    process_errors "DEBUG dns_f5xc: RRSet name: $rrset_name"
    
    # Parse the zone configuration and remove TXT record
    if ! _parse_and_modify_zone "$zone_config" "$subdomain" "$txt_value" "$rrset_name" "remove"; then
        return 1
    fi
    
    return 0
}

# Parse zone configuration and modify TXT records
_parse_and_modify_zone() {
    zone_config="$1"
    subdomain="$2"
    txt_value="$3"
    rrset_name="$4"
    action="$5"
    
    # Use jq for zone modification
    if command -v jq >/dev/null 2>&1; then
        process_errors "DEBUG dns_f5xc: Using jq for zone modification"
        if ! _modify_zone_with_jq "$zone_config" "$subdomain" "$txt_value" "$rrset_name" "$action"; then
            return 1
        fi
    else
        process_errors "ERROR dns_f5xc: jq is required but not available"
        return 1
    fi
    
    return 0
}

# Modify zone using jq
_modify_zone_with_jq() {
    zone_config="$1"
    subdomain="$2"
    txt_value="$3"
    rrset_name="$4"
    action="$5"
    
    if [ "$action" = "add" ]; then
        # Check if RRSet already exists and update it, otherwise add new one
        # Get device name for descriptions
        machine_id=$(_get_machine_id 2>/dev/null)
        
        export _zone_data=$(printf "%s" "$zone_config" | jq --arg name "$rrset_name" --arg subdomain "$subdomain" --arg value "$txt_value" --arg machine "$machine_id" '
            # Ensure rr_set_group exists and is an array
            .spec.primary.rr_set_group = (.spec.primary.rr_set_group // []) |
            if (.spec.primary.rr_set_group | map(select(.metadata.name == $name)) | length) > 0 then
              .spec.primary.rr_set_group |= map(
                if .metadata.name == $name then
                  .rr_set += [{"ttl": 60, "txt_record": {"name": $subdomain, "values": [$value]}}]
                else . end)
            else
              .spec.primary.rr_set_group += [{"metadata":{"name":$name,"namespace":"system","description":("Managed by " + $machine)},"rr_set":[{"ttl":60,"txt_record":{"name":$subdomain,"values":[$value]}}]}]
            end')
        
        if [ $? -ne 0 ]; then
            process_errors "ERROR dns_f5xc: jq processing failed"
            return 1
        fi
    else
        # Remove TXT record from zone
        process_errors "DEBUG dns_f5xc: Removing TXT record"
        
        # Remove the specific TXT record and clean up empty RRSets
        export _zone_data=$(printf "%s" "$zone_config" | jq --arg name "$rrset_name" --arg subdomain "$subdomain" --arg value "$txt_value" '.spec.primary.rr_set_group |= map(if .metadata.name == $name then .rr_set |= map(select(.txt_record.name != $subdomain or (.txt_record.values | index($value) | not))) else . end) | .spec.primary.rr_set_group |= map(select(.rr_set | length > 0))')
        
        if [ $? -ne 0 ]; then
            process_errors "ERROR dns_f5xc: jq removal processing failed"
            return 1
        fi
    fi
    
    if [ -z "$_zone_data" ]; then
        return 1
    fi
    
    return 0
}

# Validate configuration files early
_validate_config() {
    process_errors "DEBUG dns_f5xc: Validating F5 XC configuration files"
    
    # Check required environment variables
    if [ -z "$F5XC_TENANT" ]; then
        process_errors "ERROR dns_f5xc: F5XC_TENANT is required"
        return 1
    fi
    
    # Check if we have either certificates or API token
    if [ -z "$F5XC_CLIENT_CERT" ] && [ -z "$F5XC_API_TOKEN" ]; then
        process_errors "ERROR dns_f5xc: Either F5XC_CLIENT_CERT or F5XC_API_TOKEN is required"
        return 1
    fi
    
    # Check if client certificate exists and is readable (if provided)
    if [ -n "$F5XC_CLIENT_CERT" ]; then
        if [ ! -f "$F5XC_CLIENT_CERT" ]; then
            process_errors "ERROR dns_f5xc: Client certificate file not found: $F5XC_CLIENT_CERT"
            return 1
        fi
        
        if [ ! -r "$F5XC_CLIENT_CERT" ]; then
            process_errors "ERROR dns_f5xc: Client certificate file not readable: $F5XC_CLIENT_CERT"
            return 1
        fi
        
        # Check if certificate password is provided for P12 certificates
        if [ "$F5XC_CLIENT_CERT" != "${F5XC_CLIENT_CERT%.p12}" ] || [ "$F5XC_CLIENT_CERT" != "${F5XC_CLIENT_CERT%.pfx}" ]; then
            if [ -z "$F5XC_CERT_PASSWORD" ]; then
                process_errors "ERROR dns_f5xc: Certificate password (F5XC_CERT_PASSWORD) is required for P12 certificates"
                return 1
            fi
        fi
        
        process_errors "DEBUG dns_f5xc: Client certificate file validated"
    elif [ -n "$F5XC_API_TOKEN" ]; then
        process_errors "DEBUG dns_f5xc: Using API token authentication"
    fi
    
    process_errors "DEBUG dns_f5xc: Configuration validated successfully"
    return 0
}

# F5 XC REST API helper function
_f5xc_rest() {
    method="$1"
    path="$2"
    data="$3"
    
    # Construct full URL directly from tenant
    full_url="https://${F5XC_TENANT}.console.ves.volterra.io${path}"
    
    process_errors "DEBUG dns_f5xc: API call: $method $path"
    
    # Check authentication method: Client certificates (preferred) or API token (fallback)
    if [ -n "$F5XC_CLIENT_CERT" ]; then
        # Use client certificate authentication
        process_errors "DEBUG dns_f5xc: Using client certificate authentication"
        
        # Convert P12 to PEM for better compatibility with modern OpenSSL
        cert_file="$F5XC_CLIENT_CERT"
        if [ "$F5XC_CLIENT_CERT" != "${F5XC_CLIENT_CERT%.p12}" ] || [ "$F5XC_CLIENT_CERT" != "${F5XC_CLIENT_CERT%.pfx}" ]; then
            cert_file=$(_convert_p12_to_pem "$F5XC_CLIENT_CERT" "$F5XC_CERT_PASSWORD")
            if [ $? -ne 0 ]; then
                process_errors "ERROR dns_f5xc: Failed to convert P12 certificate to PEM format"
                return 1
            fi
            process_errors "DEBUG dns_f5xc: Using PEM certificate"
        fi
        
        # Build curl command with certificate
        curl_cmd="curl -sk -X $method"
        
        # Add certificate (PEM format)
        curl_cmd="$curl_cmd --cert $cert_file"
        process_errors "DEBUG dns_f5xc: Using PEM certificate"
        
        # Add headers and URL
        curl_cmd="$curl_cmd -H 'Content-Type: application/json'"
        curl_cmd="$curl_cmd -H 'Accept: application/json'"
        curl_cmd="$curl_cmd '$full_url'"
        
        # Add data for POST/PUT requests
        if [ "$method" = "POST" ] || [ "$method" = "PUT" ]; then
            process_errors "DEBUG dns_f5xc: Request data included"
            curl_cmd="$curl_cmd -d '$data'"
        fi
        
        process_errors "DEBUG dns_k5xc: Executing curl command"
        process_errors "DEBUG dns_f5xc: Full curl command: $curl_cmd"
        response=$(eval "$curl_cmd")
        curl_exit_code=$?
        
        # Clean up temporary PEM file if we created one
        if [ "$cert_file" != "$F5XC_CLIENT_CERT" ]; then
            rm -f "$cert_file"
            process_errors "DEBUG dns_f5xc: Cleaned up temporary PEM file"
        fi
        
    elif [ -n "$F5XC_API_TOKEN" ]; then
        # Use API token authentication with direct curl
        process_errors "DEBUG dns_f5xc: Using API token authentication with direct curl"
        
        # Build curl command with API token
        curl_cmd="curl -sk -X $method"
        curl_cmd="$curl_cmd -H 'Authorization: APIToken $F5XC_API_TOKEN'"
        curl_cmd="$curl_cmd -H 'Content-Type: application/json'"
        curl_cmd="$curl_cmd -H 'Accept: application/json'"
        
        if [ -n "$data" ]; then
            process_errors "DEBUG dns_f5xc: Request data included"
            curl_cmd="$curl_cmd -d '$data'"
        fi
        
        curl_cmd="$curl_cmd '$full_url'"
        
        process_errors "DEBUG dns_f5xc: Executing curl command"
        response=$(eval "$curl_cmd")
        curl_exit_code=$?
    else
        process_errors "ERROR dns_f5xc: No valid authentication method found - credentials not properly validated"
        return 1
    fi
    
    # Check curl exit code
    if [ "$curl_exit_code" != "0" ]; then
        process_errors "ERROR dns_f5xc: curl error for $method $full_url (exit code: $curl_exit_code)"
        return 1
    fi
    
    process_errors "DEBUG dns_f5xc: API response received"
    
    # Check for F5 XC API errors in the response
    if echo "$response" | grep -q '"code":[0-9]'; then
        # Extract error code and message
        error_code=$(echo "$response" | jq -r '.code' 2>/dev/null || echo "unknown")
        error_message=$(echo "$response" | jq -r '.message' 2>/dev/null || echo "unknown error")
        
        # Check if this is an error response (code != 0)
        if [ "$error_code" != "0" ] && [ "$error_code" != "null" ] && [ "$error_code" != "unknown" ]; then
            process_errors "ERROR dns_f5xc: F5 XC API error (code: $error_code): $error_message"
            
            # Check for specific error types
            if echo "$response" | grep -q "duplicate.*TXT"; then
                process_errors "ERROR dns_f5xc: Duplicate TXT record detected - this is not allowed in F5 XC"
                return 2  # Special exit code for duplicate records
            fi
            
            return 1  # General API error
        fi
    fi
    
    # Store response in a global variable so calling functions can access it
    export _F5XC_LAST_RESPONSE="$response"
    
    return 0
}

# Get machine identifier for RRSet naming
_get_machine_id() {
    # Priority order:
    # 1. Configurable F5XC_RRSET_IDENTIFIER from config
    # 2. BIG-IP hostname from tmsh (required environment)
    # 3. Fallback to constant
    
    # First priority: Check for configurable F5XC_RRSET_IDENTIFIER
    if [ -n "$F5XC_RRSET_IDENTIFIER" ]; then
        _sanitize_name "$F5XC_RRSET_IDENTIFIER"
        return 0
    fi
    
    # Second priority: BIG-IP device name via tmsh
    if command -v tmsh >/dev/null 2>&1; then
        device_name=$(tmsh list sys global-settings hostname 2>/dev/null | awk '/hostname/ {print $2}')
        if [ -n "$device_name" ]; then
            _sanitize_name "$device_name"
            return 0
        fi
    fi
    
    # Fallback constant
    _sanitize_name "unknown-device"
}

# Sanitize name to follow F5 XC naming rules
_sanitize_name() {
    name="$1"
    
    # Convert to lowercase and replace invalid chars with hyphens
    sanitized=$(printf "%s" "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
    
    # Remove multiple consecutive hyphens
    sanitized=$(printf "%s" "$sanitized" | sed 's/--*/-/g')
    
    # Ensure it starts with a letter
    if [ -n "$sanitized" ] && ! printf "%s" "$sanitized" | grep -q '^[a-z]'; then
        sanitized="m-${sanitized}"
    fi
    
    # Ensure it ends with alphanumeric
    if [ -n "$sanitized" ] && ! printf "%s" "$sanitized" | grep -q '[a-z0-9]$'; then
        sanitized=$(printf "%s" "$sanitized" | sed 's/-*$//')
    fi
    
    # If empty after sanitization, use fallback
    if [ -z "$sanitized" ]; then
        sanitized="unknown-machine"
    fi
    
    printf "%s" "$sanitized"
}

# Wait for DNS propagation to authoritative nameservers
_wait_for_dns_propagation() {
    domain="$1"
    subdomain="$2"
    expected_value="$3"
    
    # Get authoritative nameservers for the domain
    nameservers=""
    if command -v dig >/dev/null 2>&1; then
        nameservers=$(dig +short NS "$domain" | head -n 2)
    elif command -v nslookup >/dev/null 2>&1; then
        nameservers=$(nslookup -type=NS "$domain" | awk '/nameserver/ {print $4}' | head -n 2)
    fi
    
    if [ -z "$nameservers" ]; then
        # Fallback to known F5 Cloud DNS nameservers
        nameservers="ns1.f5clouddns.com ns2.f5clouddns.com"
    fi
    
    process_errors "DEBUG dns_f5xc: Waiting for TXT propagation to nameservers: $nameservers"
    
    # Poll for up to 120 seconds with exponential backoff
    max_attempts=12
    attempt=1
    delay=2
    
    while [ $attempt -le $max_attempts ]; do
        process_errors "DEBUG dns_f5xc: Propagation check attempt $attempt/$max_attempts (delay: ${delay}s)"
        
        # Check each nameserver
        propagated=0
        total_ns=0
        for ns in $nameservers; do
            total_ns=$((total_ns + 1))
            if command -v dig >/dev/null 2>&1; then
                result=$(dig +short +norecurse TXT "$subdomain.$domain" "@$ns" 2>/dev/null)
            elif command -v nslookup >/dev/null 2>&1; then
                result=$(nslookup -type=TXT "$subdomain.$domain" "$ns" 2>/dev/null | grep -o '"[^"]*"' | tr -d '"')
            else
                process_errors "WARN dns_f5xc: No DNS query tools available"
                return 1
            fi
            
            # Check if the expected value is in the result
            if echo "$result" | grep -q "$expected_value"; then
                propagated=$((propagated + 1))
                process_errors "DEBUG dns_f5xc: TXT record found on $ns: $result"
            else
                process_errors "DEBUG dns_f5xc: TXT record not yet on $ns (got: $result)"
            fi
        done
        
        # Success if propagated to all nameservers
        if [ $propagated -eq $total_ns ] && [ $total_ns -gt 0 ]; then
            process_errors "DEBUG dns_f5xc: TXT record propagated to all $total_ns nameservers"
            return 0
        fi
        
        # Wait with exponential backoff
        if [ $attempt -lt $max_attempts ]; then
            process_errors "DEBUG dns_f5xc: Waiting ${delay}s before next check..."
            sleep $delay
            delay=$((delay * 2))
            if [ $delay -gt 30 ]; then
                delay=30  # Cap at 30 seconds
            fi
        fi
        
        attempt=$((attempt + 1))
    done
    
    process_errors "WARN dns_f5xc: TXT record propagation timeout after $max_attempts attempts"
    return 1
}

# Convert P12 certificate to PEM format for compatibility with modern OpenSSL
_convert_p12_to_pem() {
    p12_file="$1"
    password="$2"
    temp_pem="/tmp/f5xc_cert_$$.pem"
    
    # Use OpenSSL to extract P12
    if openssl pkcs12 -in "$p12_file" -out "$temp_pem" -nodes -passin "pass:$password" 2>/dev/null; then
        printf "%s" "$temp_pem"
        return 0
    else
        rm -f "$temp_pem" 2>/dev/null
        return 1
    fi
}

#!/usr/bin/env bash
## F5 BIG-IP Kojot ACME TLS-ALPN-01 Configuration Builder Utility
## Author: kevin-at-f5-dot-com
## Version: 20260508-1
## Description: This utility creates the BIG-IP configuration required to support TLS-ALPN-01 ACMEv2
##      validation with the Kojot ACME utility. The configuration generates a VIP-target architecture
##      (outer-vip --> original TLS app VIP) where the listening IP:port:VLANs are moved from the existing
##      TLS app VIP to a new outer VIP. The outer VIP targets the TLS app VIP and listens for TLS-ALPN-01
##      challenges. If a challenge is detected, a sharedvar signal is conveyed in the VIP target, triggering
##      the TLS app VIP to switch its client SSL profile for this TLS session to answer the ACME TLS challenge.
##  
## This utility has five parameters/options:
##  --verbose: Displays verbose logging to the console
##  --vip (required): Specifies the target TLS application VIP. This can be the short name if in /Common, or enter the full path
##  --build: Builds all of the configuration objects, but does not swap the IP:port:VLANs to the new outer VIP
##  --apply: Swaps the IP:port:VLANs to the new outer VIP
##  --undo: Swaps the IP:port:VLAns back to the TLS application VIP
##  --list: Lists all ACME layered VIPs that are actively listening on a VLAN
##
##  The --vip parameter is required. Either the --build or --apply options must also be supplied, and both can be supplied if build
##      and apply are desired in the same execution. The --undo option is mutually exclusive with build/apply.
##
##  Examples:
##      ./acme-tls-01-builder --verbose --vip app-vip --build
##      ./acme-tls-01-builder --verbose --vip app-vip --apply
##      ./acme-tls-01-builder --verbose --vip app-vip --build --apply
##      ./acme-tls-01-builder --verbose --vip app-vip --undo
##      ./acme-tls-01-builder --list
##

VERBOSE=false
DEST=""
PORT=""
VLANS=""
RULES=""
VIPNAME=""
PARTITION=""
HTTP2=""
LIST="no"

## Function: help
## - Generates help text to standard out
help() {
    echo -e "\nCommand line options:"
    echo -e "  --verbose: Displays verbose logging to the console"
    echo -e "  --vip: (required) Specifies the target TLS application VIP. This can be the short name if in /Common, or enter the full path"
    echo -e "  --build: Builds all of the configuration objects, but does not swap the IP:port:VLANs to the new outer VIP"
    echo -e "  --apply: Swaps the IP:port:VLANs to the new outer VIP"
    echo -e "  --undo: Swaps the IP:port:VLANs back to the TLS application VIP"
    echo -e "  --list: Lists all acme layered VIPs that are actively listening on a VLAN\n\n"
}

## Function: check_vip
## - Tests the supplied (tls app) VIP -- does it exist and does it contain a client SSL profile
## - Populates variables from supplied VIP: destination IP (DEST), destination port (PORT), VLANs (VLANS), iRules (RULES), VIPNAME, PARTITION, HTTP2 profile (HTTP2)
check_vip() {
    local vip="${1}"
    
    ## TEST: Fail if VIP doesn't exist
    vipexists=true && [[ "$(tmsh list ltm virtual ${vip} 2>&1)" =~ "was not found" ]] && vipexists=false
    if [ "$vipexists" == "false" ]; then return 1; fi
    
    ## TEST: Fail if VIP does not have a client SSL profile
    foundssl=0 && for prof in $(tmsh list ltm virtual ${vip} profiles | grep -B1 "context clientside" | grep -vE "context clientside|^--$" | awk -F" " '{print $1}'); do
        if [[ "$(tmsh list ltm profile client-ssl ${prof} 2>&1)" =~ "defaults-from" ]]; then foundssl=1; break; fi
    done
    if [ $foundssl == 0 ]; then return 1; fi

    ## GET destination IP (DEST), port (PORT), VLANs (VLANS), and rules (RULES) from the supplied VIP
    DEST=$(tmsh list ltm virtual ${vip} destination | grep "destination" | awk -F" " '{print $2}' | awk -F":" '{print $1}')
    PORT=$(tmsh list ltm virtual ${vip} destination | grep "destination" | awk -F" " '{print $2}' | awk -F":" '{print $2}')
    VLANS="" && for v in $(tmsh list ltm virtual ${vip} vlans | grep -vE "^ltm virtual|^    vlans|}"); do VLANS="$VLANS $v"; done
    RULES="" && for r in $(tmsh list ltm virtual ${vip} rules | grep -vE "^ltm virtual|^    rules|}"); do RULES="$RULES $r"; done

    ## GET the HTTP2 profile (HTTP2) from the supplied VIP
    for p in $(tmsh list ltm virtual ${vip} profiles | grep -B1 "context" | grep -vE "context.*|^--$" | awk -F " " '{print $1}'); do
        if [[ "$(tmsh list ltm profile http2 ${p} 2>&1)" =~ "defaults-from" ]]; then HTTP2=${p}; break; fi
    done

    ## GET separated (VIPNAME) and (PARTITION) from supplied VIP
    VIPNAME=${vip##*/}
    if [[ "$vip" =~ "/" ]]; then PARTITION=${vip%/*}; else PARTITION="/Common"; fi

    ## All good -- return success
    return 0
}

## Function: build
## - Builds the architecture components:
##   - Create Inner and Outer iRules
##   - Create the ACME HTTP2 profile (activation mode: always)
##   - Create the Outer VIP with Outer iRule and SSL persistence
##   - Add Inner iRule to origin VIP
build() {
    local vip="${1}"

    echo -e "Building ($vip)..."
    
    ## TEST: Fail if the supplied VIP does not exist or does not contain a client SSL profile (also collects DEST, PORT, VIPNAME, PARTITION variables)
    check_vip "$vip"
    if [[ $? == 1 ]]; then printf "Error: The specified VIP either does not exist or does not contain a client SSL profile. Stopping.\n"; exit 1; fi

    ## Create the OUTER iRule
    cat > "acme-tls-01-outer-rule" << 'EOF'
ltm rule acme-tls-01-outer-rule {
## Kojot ACMEv2 Utility - TLS-ALPN-01 - Outer VIP rule
## Author: kevin-at-f5-dot-com
## Version: 20260114-1

when CLIENT_ACCEPTED {
    ## VIP target to the TLS application VIP
    virtual [string map {"acme__" ""} [virtual name]]
}
when CLIENTSSL_CLIENTHELLO {
    catch {
        ## Do if SNI and ALPN values exist in the ClientHello
        if { ( [SSL::extensions exists -type 0] ne "" ) and ( [SSL::extensions -type 16] ne "" ) } {
            ## Set up sharedvar signal
            sharedvar acmechallenge
            
            ## Scan for SNI and "acme-tls/1" ALPN values in the TLS clienthello
            ## Pull the HEX value of the ALPN to address advertised combinations (ex. "h2,http/1.1")
            binary scan [SSL::extensions -type 0] @9a* ssl_ext_sni
            binary scan [SSL::extensions -type 16] @7H* ssl_ext_alpn
            
            if { $ssl_ext_alpn eq "61636d652d746c732f31" } {
                ## ALPN HEX == "acme-tls/1" - Populate sharedvar with object name (acmetmp__<sni-vale>)
                set acmechallenge "acmetmp__${ssl_ext_sni}"
            } else {
                ## Otherwise populate sharedvar with the ALPN HEX value
                set acmechallenge "${ssl_ext_alpn}"
            }
        }
    }
}
}

EOF
    tmsh load sys config merge file acme-tls-01-outer-rule > /dev/null 2>&1
    if [[ "$VERBOSE" == "true" ]]; then echo -e "  - Outer iRule created"; fi
    rm -f acme-tls-01-outer-rule

    ## Create the INNER iRule
    cat > "acme-tls-01-inner-rule" << 'EOF'
ltm rule acme-tls-01-inner-rule {
## Kojot ACMEv2 Utility - TLS-ALPN-01 - Inner (app) VIP rule
## Author: kevin-at-f5-dot-com
## Version: 20260114-1

when CLIENT_ACCEPTED priority 10 {
    ## Look for populated acmechallenge sharedvar variable
    ## If it exists, swap out the clientssl profile
    sharedvar acmechallenge ; set acmedo ""
    if { ( [info exists acmechallenge] ) and ( $acmechallenge ne "" ) } {
        if { $acmechallenge starts_with "acmetmp_" } {
            ## This is acme-tls/1 - Serve the ephemeral self-signed cert via ACME client SSL profile
            if { [catch { clientside { SSL::profile $acmechallenge } ; set acmedo "acme" } err] } {
                log local0. "ACME TLS-ALPN-01 CHALLENGE ERROR: $err"
            }
        } else {
            ## Set acmedo to the ALPN HEX value
            set acmedo $acmechallenge
        }
    }
}
when CLIENTSSL_CLIENTHELLO {
    ## Enable/disable HTTP2 and set ALPN response accordingly based on incoming ALPN
    if { ( [info exists acmechallenge] ) and ( $acmechallenge ne "" ) } {
        if { ${acmedo} eq "acme" } { SSL::alpn set "acme-tls/1" }
        elseif { ${acmedo} contains "6832" } { SSL::alpn set "h2" }
        else { set cmd "catch { HTTP2::disable }" ; eval $cmd }
    }
}
when CLIENTSSL_HANDSHAKE {
    ## Sever the connection at handshake completion if this an ACME handshake
    if { ${acmedo} eq "acme" } {
        reject
    }
}
}
EOF
    tmsh load sys config merge file acme-tls-01-inner-rule > /dev/null 2>&1
    if [[ "$VERBOSE" == "true" ]]; then echo -e "  - Inner iRule created"; fi
    rm -f acme-tls-01-inner-rule

    ## Create the ACME2 HTTP2 profile
    profexists=false && [[ "$(tmsh create ltm profile http2 "acme__http2-prof" activation-modes { always } 2>&1)" =~ "already exists" ]] && profexists=true
    if [[ "$VERBOSE" == "true" ]]; then if [[ "$profexists" == "true" ]]; then echo -e "  - HTTP2 Profile already exists"; else echo -e "  - HTTP2 Profile created"; fi; fi

    ## Create the OUTER VIP and attach OUTER iRule and SSL persistence
    outerexists=false && [[ "$(tmsh create ltm virtual "${PARTITION}/acme__${VIPNAME}" destination ${DEST}:${PORT} rules { acme-tls-01-outer-rule } profiles replace-all-with { tcp } persist replace-all-with { ssl } vlans-enabled 2>&1)" =~ "already exists" ]] && outerexists=true
    if [[ "$VERBOSE" == "true" ]]; then if [[ "$outerexists" == "true" ]]; then echo -e "  - Outer VIP already exists"; else echo -e "  - Outer VIP already exists"; fi; fi

    ## Add the INNER iRule to the INNER VIP
    tmsh modify ltm virtual "${PARTITION}/${VIPNAME}" rules { acme-tls-01-inner-rule $RULES}
    if [[ "$VERBOSE" == "true" ]]; then echo -e "  - Inner (app) VIP updated"; fi

    ## Build complete
    echo -e "  - Build complete."
}

## Function: apply
## - Uses a TMSH transaction to swap the interfaces from the origin VIP to the new outer ACME VIP
apply() {
    local vip="${1}"

    echo -e "Applying ($vip)..."

    ## TEST: Fail if the supplied VIP does not exist or does not contain a client SSL profile (also collects DEST, PORT, VIPNAME, PARTITION, HTTP2 variables)
    check_vip "$vip"
    if [[ $? == 1 ]]; then printf "Error: The specified VIP either does not exist or does not contain a client SSL profile. Stopping.\n"; exit 1; fi

    ## TEST: Fail if the Outer ACME VIP does not exist (build hasn't happened)
    acmevipexists=true && [[ "$(tmsh list ltm virtual "${PARTITION}/acme__${VIPNAME}" 2>&1)" =~ "was not found" ]] && acmevipexists=false
    if [ "${acmevipexists}" == "false" ]; then
        echo -e "Error: It appears the build process has not completed. Run the utility with the --build option before (or with) the --apply option.\n\n"
        exit 1
    fi

    ## Generate a TMSH transaction to swap the destination IP:port, and VLANs from the (inner) TLS app VIP to new outer ACME VIP
    ## Also add the ACME HTTP2 profile
    (echo create cli transaction
        echo modify ltm virtual "${PARTITION}/${VIPNAME}" vlans none
        echo modify ltm virtual "${PARTITION}/${VIPNAME}" vlans-enabled
        if [[ ! -z "${HTTP2}" ]]; then
            echo modify ltm virtual "${PARTITION}/${VIPNAME}" profiles delete { "${HTTP2}" }
            echo modify ltm virtual "${PARTITION}/acme__${VIPNAME}" metadata replace-all-with { orig_h2 { value ${HTTP2} } }
        else
            echo modify ltm virtual "${PARTITION}/acme__${VIPNAME}" metadata none
        fi
        echo modify ltm virtual "${PARTITION}/${VIPNAME}" profiles add { "acme__http2-prof" }
        echo modify ltm virtual "${PARTITION}/acme__${VIPNAME}" vlans replace-all-with { $VLANS }
        echo submit cli transaction
    ) | tmsh > /dev/null 2>&1
    
    echo -e "  - Apply complete. ACME Outer VIP is now listening in front of the origin ${vip}."
}

## Function: undo
## - Uses a TMSH transaction to swap the interfaces back from the outer ACME VIP to the inner origin VIP
undo() {
    local vip="${1}"

    echo -e "Undoing ($vip)..."

    ## TEST: Fail if the supplied VIP does not exist or does not contain a client SSL profile (also collects DEST, PORT, VIPNAME, PARTITION, HTTP2 variables)
    check_vip "$vip"
    if [[ $? == 1 ]]; then printf "The specified VIP either does not exist or does not contain a client SSL profile. Stopping.\n"; exit 1; fi

    ## TEST: Fail if the Outer ACME VIP does not exist (build hasn't happened)
    acmevipexists=true && [[ "$(tmsh list ltm virtual "${PARTITION}/acme__${VIPNAME}" 2>&1)" =~ "was not found" ]] && acmevipexists=false
    if [ "${acmevipexists}" == "false" ]; then
        echo -e "Error: It appears the build process has not completed. Run the utility with the --build option before (or with) the --apply option.\n\n"
        exit 1
    fi

    ## Get active VLANs
    ACMEVLANS="" && for av in $(tmsh list ltm virtual "${PARTITION}/acme__${VIPNAME}" vlans | grep -vE "^ltm virtual|^    vlans|}"); do ACMEVLANS="$ACMEVLANS $av"; done

    ## Get original HTTP2 from metadata if it exists
    ORIGH2="$(tmsh list ltm virtual "${PARTITION}/acme__${VIPNAME}" metadata { orig_h2 } | grep value | awk -F" " '{print $2}' 2>&1)"

    ## Generate a TMSH transaction to swap the destination IP:port, and VLANs from TLS app VIP to outer VIP
    ## Also re-add the original HTTP2 profile if required
    (echo create cli transaction
        echo modify ltm virtual "${PARTITION}/acme__${VIPNAME}" vlans none
        echo modify ltm virtual "${PARTITION}/acme__${VIPNAME}" vlans-enabled
        echo modify ltm virtual "${PARTITION}/${VIPNAME}" vlans replace-all-with { $ACMEVLANS }
        echo modify ltm virtual "${PARTITION}/${VIPNAME}" profiles delete { "acme__http2-prof" }
        if [[ ! -z "${ORIGH2}" ]]; then
            echo modify ltm virtual "${PARTITION}/${VIPNAME}" profiles add { "${ORIGH2}" }
        fi
        echo submit cli transaction
    ) | tmsh > /dev/null 2>&1
    
    echo -e "  - Undo complete. The origin ${vip} is now re-attached to client-facing VLANs."
}

list() {
    echo -e "\n"
    declare -a vip_array
    for vip in $(tmsh list ltm virtual | grep -e '^ltm virtual acme__.*$' | awk -F" " '{print $3}'); do
        if [[ $(tmsh list ltm virtual $vip vlans | grep vlans) =~ "none" ]]; then 
            test=1
            ## no vlans
        else
            # echo -e "$vip"
            vip_array+="$vip"
        fi
    done
    if (( ${#vip_array[@]} > 0 )); then
        echo -e "The following ACME overlay VIPs are active:"
        for v in "${vip_array[@]}"; do
            echo -e " - $v"
        done
    else
        echo -e "No ACME overlay VIPs are active"
    fi
    echo -e "\n"
    
}

## Function: main
## - process command line arguments
main() {
    while (( ${#} )); do
        case "${1}" in
            --help)
              help >&2
              exit 0
              ;;
            
            --vip)
              shift 1
              if [[ -z "${1:-}" ]]; then
                printf "\nError: The --vip option requires an additional parameter. Please see --help:" >&2
                echo >&2
                help >&2
                exit 1
              fi
              VIP="${1}"
              ;;
            
            --verbose)
              VERBOSE="true"
              ;;

            --build)
              BUILD="yes"
              ;;
            
            --apply)
              APPLY="yes"
              ;;

            --undo)
              UNDO="yes"
              ;;

            --list)
              LIST="yes"
              ;;

        esac
        shift 1
    done

    ## Validate inputs: --vip is required
    if [[ ( "${LIST}" == "no" ) && ( -z "$VIP" ) ]]; then
        printf "\nError: The --vip option is required. Please see --help:" >&2
        echo >&2
        help >&2
        exit 1
    fi

    ## Validate inputs: undo is mutually exclusive with build/apply
    if [[ ( "${LIST}" == "no" ) && (((-n "$BUILD") && (-n "$UNDO")) || ((-n "$APPLY") && (-n "$UNDO"))) ]]; then
        printf "\nError: The --undo option is mutually exclusive with the --build and --apply options. Please see --help:" >&2
        echo >&2
        help >&2
        exit 1
    fi

    ## Validate inputs: build or apply is required
    if [[ ( "${LIST}" == "no" ) && ((-z "$BUILD") && (-z "$APPLY") && (-z "$UNDO")) ]]; then
        printf "\nError: The utility requires the (--build and/or --apply options), or the --undo option. Please see --help:" >&2
        echo >&2
        help >&2
        exit 1
    fi

    if [ "$VERBOSE" == "true" ]; then
        echo -e "Options applied:"
        echo -e "  - VERBOSE:   $VERBOSE"
        echo -e "  - VIP:       $VIP"
        echo -e "  - BUILD:     $BUILD"
        echo -e "  - APPLY:     $APPLY"
        echo -e "  - UNDO:      $UNDO"
        echo -e "  - LIST:      $LIST"
    fi

    ## Run functions based on command inputs
    if [ -n "$BUILD" ]; then build $VIP; fi
    if [ -n "$APPLY" ]; then apply $VIP; fi
    if [ -n "$UNDO" ]; then undo $VIP; fi
    if [ "${LIST}" == "yes" ]; then list; fi
}

main "${@:-}"

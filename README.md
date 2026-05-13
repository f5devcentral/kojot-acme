KOJOT-ACME
An ACMEv2 client utility function for integration and advanced features on the F5 BIG-IP
Major Updates May 12, 2026 - See updates section at bottom for changes

This project defines a set of utility functions for the Dehydrated ACMEv2 client, supporting direct integration with F5 BIG-IP, and including additional advanced features:

Simple installation, configuration, and scheduling
Supports renewal with existing private keys to enable certificate automation in HSM/FIPS environments
Supports per-domain configurations, to multiple ACME providers
Supports both the HTTP-01, DNS-01, and TLS-ALPN-01 validation mechanisms
Supports wildcard certificates for DNS-01 and EAB providers
Supports OCSP and periodic revocation testing
Supports External Account Binding (EAB)
Supports device certificate management
Supports SAN certificate renewal
Supports explicit proxy egress
Supports granular scheduling
Supports DNS-01 alias mode
Supports SMTP Reporting
Supports high availability
Supports debug logging

Why Kojot? Often pronounce "koyot", this is a word for "coyote" that has origins in Czech, Hungarian, Polish, and Serbo-Croatian languages. But most important, a famous coyote you may know, Wile E. Coyote, was a great consumer of ACME services, so the name checks out. ;)


Installation
 
and
 
Configuration
Installation and Configuration

Installation to the BIG-IP is simple. The only constraint is that the certificate objects installed on the BIG-IP must be named after the certificate subject name (unless the --alias flag is used). For example, if the certificate subject name is www.foo.com, then the installed certificate and key must also be named www.foo.com. Certificate automation is predicated on this naming construct. To install the utility functions to the BIG-IP:


Step
 
1
Step 1 (Install): SSH to the BIG-IP shell and run the following command. This will install all required components to the /shared/acme folder on the BIG-IP. In an HA environment, perform this action on both BIG-IP instances.

curl -s https://raw.githubusercontent.com/f5devcentral/kojot-acme/main/install.sh | bash
Optionally to include a proxy server to access the installation, add the -x (proxy) and --proxy argument (note the double set of double-dashes in Bash argument). The -x is an argument to the command line to use a proxy to fetch the install.sh script, and the --proxy argument is passed to the script itself.

curl -ks -x 172.16.1.144:3128 https://raw.githubusercontent.com/f5devcentral/kojot-acme/main/install.sh | bash -s -- --proxy 172.16.1.144:3128
Step
 
2
Step 2 (Certificates Configuration): Update the new dg_acme_config data group and add entries for each managed domain (certificate subject). You must minimally include the subject/domain (key) and a corresponding --ca value. In an HA environment, this data group is synced between the peers. See the Certificates Configuration Options section below for additional details. Examples:

www.foo.com := --ca https://acme-v02.api.letsencrypt.org/directory
www.bar.com := --ca https://acme.zerossl.com/v2/DV90 --config /shared/acme/config_www_example_com
www.baz.com := --ca https://acme.locallab.com:9000/directory -a rsa
Step
 
3
Step 3 (Provider Configuration): Adjust the default provider configuration config file in the /shared/acme folder as needed for your specific provider. In most cases you will only need a single provider config file, but this utility allows for per-provider configurations. For example, you can define separate config files when EAB is needed for some provider(s), but not others. In an HA environment, the utility ensures these config files are available to the peer. See the ACME Provider Configuration Options section below for additional details.

Step
 
4
Step 4 (HTTP Virtual Servers): For HTTP-01 validation, minimally ensure that an HTTP virtual server exists on the BIG-IP that matches the DNS resolution of each target domain (certificate subject). As a function of the ACMEv2 http-01 challenge process, the ACME server will attempt to contact the requested domain IP address on port 80 (HTTP). Attach the acme_handler_rule iRule to each HTTP virtual server.

Step
 
5
Step 5 (Initial Fetch): Initiate an ACMEv2 fetch. This command will loop through the dg_acme_config certificates configuration data group and perform required ACMEv2 certificate renewal operations for each configured domain. By default, if no certificate and key exists for a domain, ACMEv2 renewal will generate a new certificate and key. If a private key exists, a CSR is generated from the existing key to renew the certificate only. This it to support HSM/FIPS environments, but can be disabled to always generate a new private key. See the Utility Command Line Options and ACME Povider Configuration Options sections below for additional details.

cd /shared/acme
./f5acmehandler.sh --verbose
Step
 
6
Step 6 (Schedule): Once all configuration updates have been made and the utility function is working as desired, define scheduling to automate the process. By default, each domain (certificate) is checked against the defined threshold (default: 30 days) and only continues if the threshold is exceeded. In an HA environment, perform this action on both BIG-IP instances. See the Scheduling section below for additional details. For example, to set a weekly schedule, to initiate an update check every Monday at 4am:

cd /shared/acme
./f5acmehandler.sh --schedule "00 04 * * 1"
Step
 
7
Step 7 (Client SSL Profile): The f5acmehandler.sh utility maintains the freshness of the certificates (and private keys) installed on the BIG-IP. Ultimately, these certificates and keys will then need to be applied to SSL profiles, and the SSL profiles applied to application virtual servers. Creating the SSL profiles and virtual servers is outside the scope of this utility, but optionally you can set the CREATEPROFILE option in the client config file to 'true' to have the utility create a client SSL profile if missing, and attach the certificate and key to that profile.


Configuration
 
Details
Configuration Details

The ACMEv2 configuration is broken into two components --> the provider configuration that describes the ACMEv2 server (including validation mode, authentication, and revocation & renewal settings), and the certificates configuration that describes each managed certificate. The provider configuration is stored in config files in the /shared/acme working folder. A default config file is included (/shared/acme/config), but others can be created if multiple ACMEv2 providers are needed and require different settings. The certificates configuration is stored in the dg_acme_config data group and must minimally include the provider URL, but may also point to a specific config file. If the config file is not specified, the default config file will be used.

Configuration options for this utility are found in the following locations:

Providers Configuration Options define the per-provider ACMEv2 attributes. These settings are maintained in a config text file stored in the "/shared/acme" folder on the BIG-IP.
Certificates Configuration Options define the set of certificates that are to be handled, the (CA) directory URL of the designated ACMEv2 provider, and any optional unique configuration settings. This list is maintained in a BIG-IP data group (dg_acme_config)

Certificate configuration options are specified in the dg_acme_config data group for each domain (certificate subject). Each entry in the data group must include a String: the domain name (ex. www.foo.com), and a Value consisting of a number of configuration options:


Value Options
Description	Examples	Required
--ca	Defines the ACME provider URL	--ca https://acme-v02.api.letsencrypt.org/directory (Let's Encrypt)

--ca https://acme-staging-v02.api.letsencrypt.org/directory (LE Staging)

--ca https://acme.zerossl.com/v2/DV90 (ZeroSSL)

--ca https://api.buypass.com/acme/directory (Buypass)

--ca https://api.test4.buypass.no/acme/directory (Buypass Test)	
Yes
Yes

--config	Defines an alternate config file (default: /shared/acme/config)	--config /shared/acme/config_www_foo_com	
No
No

-a	Overrides the required leaf certificate algorithm specified in the config file. (default: rsa)	-a rsa

-a prime256v1

-a secp384r1	
No
No

-d	Includes additional DNS subject-alternative-name (SAN) values in the certificate. This option can be used multiple times.	-d foo.f5labs.com -d bar.f5labs.com	
No
No

--alias	Allows for wildcard certificate requests on dns-01 and EAB (authenticated http-01) validations. The --alias flag moves the name of the object to the alias context.	--alias wildcard_f5labs_com	
No
No

--ocsp	Adds OCSP monitoring properties to the imported certificate. The --ocsp option points to a predefined OCSP object on the BIG-IP (System > Certificate Management > Traffic Certificate Management > OCSP). When specifying the --ocsp option, the --issuer must also be included.	--ocsp my-ocsp-provider --issuer subca.f5labs.com	
No
No

--issuer	Adds OCSP monitoring properties to the imported certificate. The --ocsp option points to a predefined CA certificate on the BIG-IP (System > Certificate Management > Traffic Certificate Management > SSL Certificate List). When specifying the --issuer option, the --ocsp option must also be included.	--ocsp my-ocsp-provider --issuer subca.f5labs.com	
No
No

--dnsalias	Allows for DNS-01 alias mode, pointing to an alternate/alias domain name.	--dnsalias _acme-challenge.www.dnsaliastesting.com	
No
No


Examples:

www.foo.com := --ca https://acme-v02.api.letsencrypt.org/directory
www.bar.com := --ca https://acme.zerossl.com/v2/DV90 --config /shared/acme/config_www_example_com
www.baz.com := --ca https://acme.locallab.com:9000/directory -a rsa
www.baz.com := --ca https://acme.locallab.com:9000/directory -a rsa -d foo.baz.com -d bar.baz.com
*.baz.com   := --ca https://acme.locallab.com:9000/directory --alias wildcard_baz_com
www.bat.com := --ca https://acme-v02.api.letsencrypt.org/directory --ocsp my-ocsp --issuer subca.f5labs.com
www.bab.com := --ca https://acme-v02.api.letsencrypt.org/directory --dnsalias _acme-challenge.bab.dnsaliastesting.com
Note the following:

In using the -d option to include additional SAN values, ACME providers will typically also require validation of each hostnames as well. Ensure that DNS for each of these also resolve to an IP address on the BIG-IP that can answer the ACME challenge.
The -d option only applies to new certificates. Once a certificate has been created, the ACME renewal will retain the SAN values in the existing certificate.
The --alias option supports wilcard certificates using either dns-01 validation method, or EAB (pre-authenticated) http-01. In general practice and per RFCs, wildcard certificates are not supported for http-01 validation unless EAB pre-authentication is used.
The --dnsalias option only works with dns-01 mode, and does not work in conjuction with the --alias option. To support wildcard certificates with DNS alias mode, specify the wildcard domain in an -d [domain] option.
Utility Command Line Options are command line arguments for the f5acmehandler.sh script used in maintenance operations.
Scheduling Options

ACME
 
Protocol
 
Flow
ACME Protocol Flow

Provided below are detailed descriptions of the control flows. The ACME Utility Architecture section describes the files and folders in use. The ACME Functional Flow on BIG-IP section describes the interaction of f5acmehandler and ACME client processes. The ACME Protocol Flow Reference details the general ACMEv2 protocol flow per RFC8555.

ACME Utility Architecture
ACME Functional Flow on BIG-IP
ACME Protocol Flow Reference

Additional
 
Configuration
 
Options
Additional Configuration Options

Below are descriptions of additional features and environment options.

Working with External Account Binding (EAB)
Working with ACMEv2 DNS-01 validation
Working with ACMEv2 TLS-ALPN-01 validation
Working with wildcard certificates
Working with Syslog reporting
Working with ACMEv2 DNS-01 alias mode validation

In some environments you cannot or should not automate DNS changes on your primary/authoritative DNS zone because:

The authoritative DNS is managed by a third party or different team
The authoritative DNS has no API for automation
Security policy forbids giving certificate automation tools write access to production DNS zones
ACMEv2 DNS alias mode shifts the API update to a secondary DNS service by way of a static CNAME created in the authoritative zone, for each certificate domain name.

Instead of writing the challenge TXT record to primary DNS, create a CNAME record in the primary zone that points to your secondary DNS service. This is a manual step.

_acme-challenge.www.f5labs.com -> _acme-challenge.www.dnsaliastesting.com
For example, in a simple Bind zone file configuration:

www         IN  CNAME   _acme-challenge.www.dnsaliastesting.com.
The CNAME entry is completely arbitrary except for the zone suffix. It could be "foo.dnsaliastesting.com" or anything else.

Point the ACME client at this alias zone using the --dnsalias option in the certificate configuration data group entry. Include the name of the alias entry:

www.f5labs.com := --ca https://smallstep.f5labs.com:9000/acme/acme/directory --dnsalias _acme-challenge.www.dnsaliastesting.com
The Kojot ACME client will overwrite the origin domain (ex. www.f5labs.com) with the alias domain (ex. _acme-challenge.www.dnsaliastesting.com) in the call to the DNS API script, and the DNS API script will create a TXT entry in the secondary DNS zone. Ensure that the DNS variables in the config file are set to interact with the secondary zone API.

The CA follows the CNAME when doing its DNS lookup and will find the TXT record in the alias zone.

Note: The CNAME is permanent and only needs to be set up once. Every subsequent renewal is fully automated against the alias zone.


Working with DNS alias mode and wildcard certificates
To manage wildcard certificates with DNS alias mode, do not use the --alias option typically used for wildcards. Instead, specify the wildcard domain with a -d [domain] option in the certificate data group entry. Example:

www.f5labs.com := --ca https://pebble.f5labs.com:14000/dir -d *.f5labs.com --dnsalias _acme-www.dnsaliastesting.com
Ensure that your primary DNS zone contains a CNAME entry for the _acme-challenge record on the root of the zone (ex. _acme-challenge.f5labs.com) and that it points to your secondary DNS.


Working with certificate configs in alternate partitions
Working with multiple certificates with the same hostname
Working with OCSP and Periodic Revocation Testing
Using ACME to update device certificates
Working with High Availability
Working with BIG-IQ
Reporting
Upgrading
Uninstall
Troubleshooting
Troubleshooting

Error Messaging
General Troubleshooting

Testing
Testing

There are a number of ways to test the f5acmehandler utility, including validation against local ACME services. The acme-servers folder contains Docker-Compose options for spinning up local Smallstep Step-CA and Pebble ACME servers. The following describes a very simple testing scenario using one of these tools.

On the BIG-IP, install the f5acmehandler utility components on the BIG-IP instance. SSH to the BIG-IP shell and run the following command:

curl -s https://raw.githubusercontent.com/f5devcentral/kojot-acme/main/install.sh | bash
Install the Smallstep Step-CA ACME server instance on a local Linux machine. Adjust the local /etc/hosts DNS entries at the bottom of the docker-compose YAML file accordingly to allow the ACME server to locally resolve your ACME client instance (the set of BIG-IP HTTP virtual servers). This command will create an ACME service listening on HTTPS port 9000.

git clone https://github.com/f5devcentral/kojot-acme.git
cd kojot-acme/acme-servers/
docker-compose -f docker-compose-smallstep-ca.yaml up -d
On the BIG-IP, for each of the above /etc/hosts entries, ensure that a matching HTTP virtual server exists on the BIG-IP. Define the destination IP (same as /etc/hosts entry), port 80, a generic http profile, the proper listening VLAN, and attach the acme_handler_rule iRule.

On the BIG-IP, update the dg_acme_config data group and add an entry for each domain (certificate). This should match each /etc/hosts domain entry specified in the docker-compose file.

www.foo.com := --ca https://<acme-server-ip>:9000/acme/acme/directory
www.bar.com := --ca https://<acme-server-ip>:9000/acme/acme/directory -a rsa
To view DEBUG logs for the f5acmehandler processing, ensure that the DEBUGLOG entry in the config file is set to true. Then in a separate SSH window to the BIG-IP, tail the acmehandler log file:

tail -f /var/log/acmehandler
or use the --verbose option with the f5acmehandler.sh script:

./f5acmehandler.sh --verbose
Trigger an initial ACMEv2 certificate fetch. This will loop through the dg_acme_config data group and process ACME certificate renewal for each domain. In this case, it will create both the certificate and private key and install these to the BIG-IP. You can then use these in client SSL profiles that get attached to HTTPS virtual servers. In the BIG-IP, under System - Certificate Management - Traffic Certificate Management - SSL Certificate List, observe the installed certificate(s) and key(s).

Trigger a subsequent ACME certificate fetch, specifying a single domain and forcing renewal. Before launching the following command, open the properties of one of the certificates in the BIG-IP UI. After the command completes, refresh the certificate properties and observe the updated Serial Number and Fingerprint values.

./f5acmehandler.sh --domain www.foo.com --force

Credits
Credits

Special thanks to:

@f5-rahm and his lets-encrypt-python project for inspiration, and for coming up with the cool project name. ;)
@Lukas2511 for the dehydrated ACME client utility

Updates
Updates: 2025 May
Updates: 2025 June 3
Updates: 2025 June 16
Updates: 2025 June 27
Updates: 2025 August 01
Updates: 2025 August 06
Updates: 2025 September 10
Updates: 2025 September 23
Updates: 2025 October 20
Updates: 2025 December 17
Updates: 2026 May 08
Updates: 2026 May 11
Updates: 2026 May 12


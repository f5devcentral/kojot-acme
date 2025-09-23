## ACME Server Testing

This section describes the setup and configuration of local ACME services for testing. These can and should only be used to demonstrate the functionality of the [f5acmehandler-bash](https://github.com/kevingstewart/f5acmehandler-bash/tree/main) utility.

<br />

<details>
<summary><b>Smallstep Step-CA</b></summary>
  Reference: https://smallstep.com/blog/private-acme-server/
  
  <br />
  
  The minimum requirements for this ACME service are:
  
  * [Docker](https://www.docker.com/)
  * [Docker Compose](https://docs.docker.com/compose/)
  
  The Docker-Compose file creates all of the necessary objects and state, and starts an ACME service listener on port 9000. 
  Also note the following adjustable settings within the compose file:

  * **Rootca certificate and key** - The included self-signed root (f5labs.com) is for testing only, but can be replaced. On
    startup the Step-CA service will use this root CA to issue a new intermediate CA for use in signing the leaf certificates in
    the ACME protocol exchange.
    
  * **Configuration entries** - Ensure the following attributes are to your requirements:
    - --dns=localhost: create as many of these entries as needed to represent this ACME server instance
    - --provisioner="admin@f5labs.com": adjust according to define a provisioner admin user
    - --kty RSA - This specifies the key type for the generated intermediate certificate. If left as ECDSA (default), the ACME server
      can only issue ECC certificates. If set to create an RSA intermediate certificate, it can issue ECC _and_ RSA leaf certificates.
      
  * **Local DNS entries** - Near the bottom of the file is a set of echo statements that insert local DNS entries into /etc/hosts.
    As this is for local testing, and there might not be external DNS references to the URLs requested by the ACME client, this
    section allows you to define the set of URL-to-IP addresses the ACME server will access to complete ACME http-01 challenges

  To start the Step-CA service, execute the following:

  ```
  git clone https://github.com/kevingstewart/f5acmehandler-bash.git
  cd f5acmehandler-bash/acme-servers/
  docker-compose -f docker-compose-smallstep-ca.yaml up -d
  ```
  
  To test, point the ACME client at **https://\<server-ip\>:9000/acme/acme/directory**. In the f5acmehandler-bash configuration, add an entry to the 
  **acme_config_dg** data group for each domain, with the minimum following key and values:

  ```
  String: <domain>
  Value: --ca https://<server-ip>:9000/acme/acme/directory
  ```

  where \<domain\> is the certificate subject (ex. www.f5labs.com).

</details>

<details>
<summary><b>Pebble</b></summary>
  Reference: https://github.com/letsencrypt/pebble

  <br />
  
  The minimum requirements for this ACME service are:
  
  * [Docker](https://www.docker.com/)
  * [Docker Compose](https://docs.docker.com/compose/)
  
  The Docker-Compose file creates all of the necessary objects and state, and starts an ACME service listener on port 14000. 
  Also note the following adjustable settings within the compose file:

  * **Certificate and key** - The included certificate and key are only used in Pebble to host the HTTPS URL, but can be replaced. On
    startup the Pebble service will generate new root and intermediate CA certificates for use in the ACME protocol exchange.
      
  * **Local DNS entries** - Near the bottom of the file is a set of echo statements that insert local DNS entries into /etc/hosts.
    As this is for local testing, and there might not be external DNS references to the URLs requested by the ACME client, this
    section allows you to define the set of URL-to-IP addresses the ACME server will access to complete ACME http-01 challenges

  To start the Pebble service, execute the following:

  ```
  git clone https://github.com/kevingstewart/f5acmehandler-bash.git
  cd f5acmehandler-bash/acme-servers/
  docker-compose -f docker-compose-pebble-ca.yaml up -d
  ```
  
  To test, point the ACME client at **https://\<server-ip\>:14000/dir**. In the f5acmehandler-bash configuration, add an entry to the 
  **acme_config_dg** data group for each domain, with the minimum following key and values:

  ```
  String: <domain>
  Value: --ca https://<server-ip>:14000/dir
  ```

  where \<domain\> is the certificate subject (ex. www.f5labs.com).

  To support External Account Binding (EAB), modify the **externalAccountBindingRequired** value to _true_, and define the following additional data in the
  config.json section:

  ```
  "externalAccountBindingRequired": true,
  "externalAccountMACKeys": {
    "kid-1": "zWNDZM6eQGHWpSRTPal5eIUYFTu7EajVIoguysqZ9wG44nMEtx3MUAsUDkMTQ12W",
    "kid-2": "b10lLJs8l1GPIzsLP0s6pMt8O0XVGnfTaCeROxQM0BIt2XrJMDHJZBM5NuQmQJQH"
  }
  ```

  
</details>

<details>
<summary><b>Testing DNS-01 Validation Locally</b></summary>

This project includes a ```docker-compose-combined.yaml``` compose that deploys both ACME servers (Smallstep and Pebble), and a local DNS server instance preconfigured to support RFC2136 API support for Bind. To begin, copy the **dns_nsupdate.sh** and **dns_ndsupdate_creds.ini** files from the repo dnsapi folder into the /shared/acme/dnsapi folder on the BIG-IP. In your ```config``` file, ensure that **ACME_METHOD** is set to ```"dns-01"```, and then add the following entries:

```
DNSAPI=dns_nsupdate
NSUPDATE_SERVER="192.168.100.53"
NSUPDATE_SERVER_PORT=53
NSUPDATE_KEY="/shared/acme/dnsapi/dns_nsupdate_creds.ini"
```

Clone the repository on your Linux server with Docker installed:

```
git clone https://github.com/kevingstewart/f5acmehandler-bash.git
cd f5acmehandler-bash/acme-servers/
```

Edit the compose file as required to ensure interface and IP addresses are accessible to the BIG-IP, then start the compose environment:

```
docker-compose -f docker-compose-combined.yaml up -d
```

Update the ```dg_acme_config``` data group on the BIG-IP to assert a certificate name and either Smallstep or Pebble ACME servers. Then test from the BIG-IP console:

```
cd /shared/acme
./f5acmehandler.sh --verbose --force
```

The ```dns_nsupdate_creds.ini``` is preconfigured to match the keys in the Bind9 rndc key settings.

</details>

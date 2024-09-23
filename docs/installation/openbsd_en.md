# Installing on OpenBSD

{! backend/installation/otp_vs_from_source_source.include !}

This guide describes the installation and configuration of Pleroma (and the required software to run it) on a single OpenBSD 7.5 server.

For any additional information regarding commands and configuration files mentioned here, check the man pages [online](https://man.openbsd.org/) or directly on your server with the man command.

{! backend/installation/generic_dependencies.include !}

## Installation

### Preparing the system
#### Required software

To install required packages, run the following command:

```
# pkg_add elixir gmake git postgresql-server postgresql-contrib cmake libmagic libvips
```

Pleroma requires a reverse proxy, OpenBSD has relayd in base (and is used in this guide) and packages/ports are available for nginx (www/nginx) and apache (www/apache-httpd). Independently of the reverse proxy, [acme-client(1)](https://man.openbsd.org/acme-client) can be used to get a certificate from Let's Encrypt.

#### Optional software

  * ImageMagick
  * ffmpeg
  * exiftool

To install the above:

```
# pkg_add ImageMagick ffmpeg p5-Image-ExifTool
```

For more information read [`docs/installation/optional/media_graphics_packages.md`](../installation/optional/media_graphics_packages.md):

### PostgreSQL

Switch to the \_postgresql user and initialize PostgreSQL:

```
# su _postgresql
$ initdb -D /var/postgresql/data -U postgres
```

Running PostgreSQL in a different directory than `/var/postgresql/data` requires changing the `daemon_flags` variable in the `/etc/rc.d/postgresql` script.

Enable and start the postgresql service:

```
# rcctl enable postgresql
# rcctl start postgresql
```

To check that PostgreSQL started properly and didn't fail right after starting, you can run `ps aux | grep postgres`, there should be multiple lines of output. Or alternatively run `# rcctl check postgresql` which should return `postgresql(ok)`.

### Configuring Pleroma

Pleroma will be run by a dedicated \_pleroma user. Before creating it, insert the following lines in /etc/login.conf:

```
pleroma:\
	:datasize-max=1536M:\
	:datasize-cur=1536M:\
	:openfiles-max=4096:\
    :setenv=LC_ALL=en_US.UTF-8
```

This creates a "pleroma" login class and sets higher values than default for datasize and openfiles (see [login.conf(5)](https://man.openbsd.org/login.conf)), this is required to avoid having Pleroma crash some time after starting.

Create the \_pleroma user, assign it the pleroma login class and create its home directory (/home/\_pleroma/):

```
# useradd -m -L pleroma _pleroma
# echo 'export VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS' >> /home/_pleroma/.profile
```

Switch to the _pleroma user:

```
# su _pleroma
```

Change to the home directory (/home/\_pleroma) and clone the Pleroma repository:

```
$ cd
$ git clone -b stable https://git.pleroma.social/pleroma/pleroma.git
$ cd pleroma
```

Pleroma is now installed in /home/\_pleroma/pleroma/. To configure it run:

```
$ mix deps.get
$ MIX_ENV=prod mix pleroma.instance gen # You will be asked a few questions here.
$ cp config/generated_config.exs config/prod.secret.exs
```

Note: Answer yes when asked to install Hex and rebar3. This step might take some time as Pleroma gets compiled first.

Create the Pleroma database:

```
# psql -U postgres -f /home/_pleroma/pleroma/config/setup_db.psql
```

Switch back to the \_pleroma user and apply database migrations:

```
# su _pleroma
$ cd /home/_pleroma/pleroma
$ MIX_ENV=prod mix ecto.migrate
```

Note: You will need to run this step again when updating your instance to a newer version with `git pull` or `git checkout tags/NEW_VERSION`.

As \_pleroma in /home/\_pleroma/pleroma, you can now run `MIX_ENV=prod mix phx.server` to start your instance.
In another SSH session or a tmux window, check that it is working properly by running `ftp -MVo - http://127.0.0.1:4000/api/v1/instance`, you should get json output. Double-check that the *uri* value near the bottom is your instance's domain name and the instance *title* are correct.

### Configuring acme-client

acme-client is used to get SSL/TLS certificates from Let's Encrypt.
Insert the following configuration in /etc/acme-client.conf and replace `example.tld` with your domain:

```
#
# $OpenBSD: acme-client.conf,v 1.5 2023/05/10 07:34:57 tb Exp $
#

authority letsencrypt {
        api url "https://acme-v02.api.letsencrypt.org/directory"
        account key "/etc/acme/letsencrypt-privkey.pem"
}

domain example.tld {
        # Adds alternative names to the certificate. Useful when serving media on another domain. Comma or space separated list.
        # alternative names {  }

        domain key "/etc/ssl/private/example.tld.key"
        domain certificate "/etc/ssl/example.tld_cert-only.crt"
        domain full chain certificate "/etc/ssl/example.tld.crt"
        sign with letsencrypt
}
```

Check the configuration:

```
# acme-client -n
```

Add auto-renewal by adding acme-client to `/etc/weekly.local`, replace `example.tld` with your domain:

```
echo "acme-client example.tld >> /etc/weekly.local
```

### Configuring the Web server

Pleroma supports two Web servers:

  * nginx (recommended for most users)
  * OpenBSD's httpd and relayd (ONLY for advanced users, media proxy cache is NOT supported and will NOT work properly)

#### nginx

Since nginx is not installed by default, install it by running:

```
# pkg_add nginx
```

Add the following to `/etc/nginx/nginx.conf`, within the `server {}` block listening on port 80 and change `server_name`, as follows:

```
http {
    ...

    server {
        ...
        server_name example.tld; # Replace with your domain

        location ~ /.well-known/acme-challenge {
            root /var/www/acme;
        }
    }
}
```

Start the nginx service and acquire certificates:

```
# rcctl start nginx
# acme-client example.tld
```

OpenBSD's default nginx configuration does not contain an include directive, which is typically used for multiple sites.
Therefore, you will need to first create the required directory as follows:

```
# mkdir /etc/nginx/sites-available
# mkdir /etc/nginx/sites-enabled
```

Next add the `include` directive to `/etc/nginx/nginx.conf`, within the `http {}` block, as follows:

```
http {
    ...

    server {
        ...
    }

    include /etc/nginx/sites-enabled/*;
}
```

As root, copy `/home/_pleroma/pleroma/installation/pleroma.nginx` to `/etc/nginx/sites-available/pleroma.nginx`.

Edit default `/etc/nginx/sites-available/pleroma.nginx` settings and replace `example.tld` with your domain:

  * Change `ssl_trusted_certificate` to `/etc/ssl/example.tld_cert-only.crt`
  * Change `ssl_certificate` to `/etc/ssl/example.tld.crt`
  * Change `ssl_certificate_key` to `/etc/ssl/private/example.tld.key`

Symlink the Pleroma configuration to the enabled sites:

```
# ln -s /etc/nginx/sites-available/pleroma.nginx /etc/nginx/sites-enabled
```

Check nginx configuration syntax by running:

```
# nginx -t
```

If the configuration is correct, you can now enable and reload the nginx service:

```
# rcctl enable nginx
# rcctl reload nginx
```

#### httpd

httpd will have three functions:

  * redirect requests trying to reach the instance over http to the https URL
  * serve a robots.txt file
  * get Let's Encrypt certificates, with acme-client

Insert the following config in httpd.conf:

```
# $OpenBSD: httpd.conf,v 1.17 2017/04/16 08:50:49 ajacoutot Exp $

ext_inet="<IPv4 address>"
ext_inet6="<IPv6 address>"

server "default" {
	listen on $ext_inet port 80 # Comment to disable listening on IPv4
	listen on $ext_inet6 port 80 # Comment to disable listening on IPv6
	listen on 127.0.0.1 port 80 # Do NOT comment this line

	log syslog
	directory no index

	location "/.well-known/acme-challenge/*" {
		root "/acme"
		request strip 2
	}

	location "/robots.txt" { root "/htdocs/local/" }
	location "/*" { block return 302 "https://$HTTP_HOST$REQUEST_URI" }
}

types {
}
```

Do not forget to change *<IPv4/6 address\>* to your server's address(es). If httpd should only listen on one protocol family, comment one of the two first *listen* options.

Create the /var/www/htdocs/local/ folder and write the content of your robots.txt in /var/www/htdocs/local/robots.txt.
Check the configuration with `httpd -n`, if it is OK enable and start httpd (as root):

```
# rcctl enable httpd
# rcctl start httpd
```

#### relayd

relayd will be used as the reverse proxy sitting in front of pleroma.
Insert the following configuration in /etc/relayd.conf:

```
# $OpenBSD: relayd.conf,v 1.4 2018/03/23 09:55:06 claudio Exp $

ext_inet="<IPv4 address>"
ext_inet6="<IPv6 address>"

table <pleroma_server> { 127.0.0.1 }
table <httpd_server> { 127.0.0.1 }

http protocol plerup { # Protocol for upstream pleroma server
	#tcp { nodelay, sack, socket buffer 65536, backlog 128 } # Uncomment and adjust as you see fit
	tls ciphers "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305"
	tls ecdhe secp384r1

	# Forward some paths to the local server (as pleroma won't respond to them as you might want)
	pass request quick path "/robots.txt" forward to <httpd_server>

	# Append a bunch of headers
	match request header append "X-Forwarded-For" value "$REMOTE_ADDR" # This two header and the next one are not strictly required by pleroma but adding them won't hurt
	match request header append "X-Forwarded-By" value "$SERVER_ADDR:$SERVER_PORT"

	match response header append "X-XSS-Protection" value "1; mode=block"
	match response header append "X-Permitted-Cross-Domain-Policies" value "none"
	match response header append "X-Frame-Options" value "DENY"
	match response header append "X-Content-Type-Options" value "nosniff"
	match response header append "Referrer-Policy" value "same-origin"
	match response header append "X-Download-Options" value "noopen"
	match response header append "Content-Security-Policy" value "default-src 'none'; base-uri 'self'; form-action 'self'; img-src 'self' data: https:; media-src 'self' https:; style-src 'self' 'unsafe-inline'; font-src 'self'; script-src 'self'; connect-src 'self' wss://CHANGEME.tld; upgrade-insecure-requests;" # Modify "CHANGEME.tld" and set your instance's domain here
	match request header append "Connection" value "upgrade"
	#match response header append "Strict-Transport-Security" value "max-age=31536000; includeSubDomains" # Uncomment this only after you get HTTPS working.

	# If you do not want remote frontends to be able to access your Pleroma backend server, comment these lines
	match response header append "Access-Control-Allow-Origin" value "*"
	match response header append "Access-Control-Allow-Methods" value "POST, PUT, DELETE, GET, PATCH, OPTIONS"
	match response header append "Access-Control-Allow-Headers" value "Authorization, Content-Type, Idempotency-Key"
	match response header append "Access-Control-Expose-Headers" value "Link, X-RateLimit-Reset, X-RateLimit-Limit, X-RateLimit-Remaining, X-Request-Id"
	# Stop commenting lines here
}

relay wwwtls {
	listen on $ext_inet port https tls # Comment to disable listening on IPv4
	listen on $ext_inet6 port https tls # Comment to disable listening on IPv6

	protocol plerup

	forward to <pleroma_server> port 4000 check http "/" code 200
	forward to <httpd_server> port 80 check http "/robots.txt" code 200
}
```

Again, change *<IPv4/6 address\>* to your server's address(es) and comment one of the two *listen* options if needed. Also change *wss://CHANGEME.tld* to *wss://<your instance's domain name\>*.
Check the configuration with `relayd -n`, if it is OK enable and start relayd (as root):

```
rcctl enable relayd
rcctl start relayd
```

##### (Strongly recommended) serve media on another domain

Refer to the [Hardening your instance](../configuration/hardening.md) document on how to serve media on another domain. We STRONGLY RECOMMEND you to do this to minimize attack vectors.

#### pf
Enabling and configuring pf is highly recommended.
In /etc/pf.conf, insert the following configuration:
```
# Macros
if="<network interface>"
authorized_ssh_clients="any"

# Skip traffic on loopback interface
set skip on lo

# Default behavior
set block-policy drop
block in log all
pass out quick

# Security features
match in all scrub (no-df random-id)
block in log from urpf-failed

# Rules
pass in quick on $if inet proto icmp to ($if) icmp-type { echoreq unreach paramprob trace } # ICMP
pass in quick on $if inet6 proto icmp6 to ($if) icmp6-type { echoreq unreach paramprob timex toobig } # ICMPv6
pass in quick on $if proto tcp to ($if) port { http https } # relayd/httpd
pass in quick on $if proto tcp from $authorized_ssh_clients to ($if) port ssh
```

Replace *<network interface\>* by your server's network interface name (which you can get with ifconfig). Consider replacing the content of the authorized\_ssh\_clients macro by, for example, your home IP address, to avoid SSH connection attempts from bots.

Check pf's configuration by running `pfctl -nf /etc/pf.conf`, load it with `pfctl -f /etc/pf.conf` and enable pf at boot with `rcctl enable pf`.

### Starting pleroma at boot

Copy the startup script and make sure it's executable:

```
# cp /home/_pleroma/pleroma/installation/openbsd/rc.d/pleroma /etc/rc.d/pleroma
# chmod +x /etc/rc.d/pleroma
```

Enable and start the pleroma service:

```
# rcctl enable pleroma
# rcctl start pleroma
```

### Create administrative user

If your instance is up and running, you can create your first user with administrative rights with the following command as the \_pleroma user:

```
$ MIX_ENV=prod mix pleroma.user new <username> <your@emailaddress> --admin
```

### Further reading

{! backend/installation/further_reading.include !}

## Questions

Questions about the installation or didn’t it work as it should be, ask in [#pleroma:libera.chat](https://matrix.to/#/#pleroma:libera.chat) via Matrix or **#pleroma** on **libera.chat** via IRC.

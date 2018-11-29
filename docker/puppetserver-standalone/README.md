# Usage

## Environment variables

The following environment variables can be used at runtime:

* `PUPPETSERVER_HOSTNAME` (optional): the name to use as the Puppet
  server's `certname`
* `DNS_ALT_NAMES` (optional): the `dns_alt_names` to use for the server's
  certificate. Can not be changed once that certificate has been issued.
* `PUPPETDB_SERVER_URLS` (optional): the list of PuppetDB servers to talk
  to (see documentation for `server_urls` in `puppetdb.conf`)
* `AUTOSIGN` (optional): set Puppet's `autosign` setting to this
  value. Autosign is turned on by default.

# Example setup of trino gateway with kerberized SEP

The [create-example.sh](create-example.sh) script will
* Downloads [Kuberos](https://github.com/jeffgrunewald/kuberos/tree/master/kuberos), a Helm chart that sets up a KDC 
and admin server
* Creates a set of principals and keytabs
* Installs SEP, and configures it to use Kerberos authentication
* Tests connecting directly to the Kerberized SEP
* Installs Trino Gateway, reconfigures SEP to be connected to through the gateway, and configures the gateway to 
proxy requests to SEP
* Tests connecting to the Kerberized SEP through the Gateway

The key to using a reverse proxy such as Trino Gateway with Trino is to create a principal using the proxy's domain
for the host part of the principal. Then Trino must be configured to use this principal by setting 
`http-server.authentication.krb5.principal-hostname` to the proxy hostname.

## Requirements
* A valid Starburst license file name starburstdata.license in the root directory of this repo
* A `registry-credentials.yaml` containing your credentials for Starburst Helm charts of the form:
```yaml
registryCredentials:
  enabled: true
  password: passwd
  registry:  https://harbor.starburstdata.net/starburstdata
  username: user
```
* A kubernetes cluster
* `bash`, `kubectl`, `jq`, `helm`, `openssl` and `unzip`
* An internet connection for connecting to Github and Dockerhub

## Troubleshooting

The [create-example.sh](create-example.sh) script uses the `kubectl wait` command to ensure
services are ready before use. However, this is not foolproof, and connection timeouts, DNS errors and other 
issues may still occur. 

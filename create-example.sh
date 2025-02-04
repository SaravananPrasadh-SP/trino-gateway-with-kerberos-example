#!/usr/bin/env bash
set -e
#update the kdc hostname in krb5-conf-cm.yaml and the http-server.authentication.krb5.principal-hostname parameter of SEP if this is changed
NAMESPACE=starburst
# Check if the namespace exists
if ! kubectl get namespace ${NAMESPACE} &> /dev/null; then
  echo "Creating namespace ${NAMESPACE}"
  kubectl create namespace ${NAMESPACE}
fi
# Check if you want to enable debug for helm
if [[ ${DEBUG} ]] ; then
  DEBUGTXT="--debug"
fi
# Get kuberos
rm -rf kuberos
curl -L --output kuberos.zip https://github.com/jeffgrunewald/kuberos/archive/refs/heads/master.zip
unzip -o kuberos.zip
mv kuberos-master kuberos

#prepare env. Realm can be changed from EXAMPLE.COM and admin user set by modifying local-values.yaml
# Need the Storage Class to be changed to gp2 for EKS
helm -n ${NAMESPACE} upgrade --install kuberos kuberos/kuberos --values local-values.yaml ${DEBUGTXT}

shopt -s expand_aliases
alias kadmin_exec="kubectl -n ${NAMESPACE} exec kuberos-kuberos-kdc-0 -c kadmin -- /usr/sbin/kadmin.local -r EXAMPLE.COM -p admin/admin"
kadmin_exec addprinc -pw client client
kadmin_exec ktadd -k /tmp/client.keytab client
kadmin_exec addprinc -pw sep sep/coordinator.${NAMESPACE}.svc.cluster.local
kadmin_exec ktadd -k /tmp/sep.keytab sep/coordinator.${NAMESPACE}.svc.cluster.local
kadmin_exec addprinc -pw trino-gateway gateway/trino-gateway.${NAMESPACE}.svc.cluster.local
kadmin_exec ktadd -k /tmp/gateway.keytab gateway/trino-gateway.${NAMESPACE}.svc.cluster.local
unalias kadmin_exec
kubectl cp ${NAMESPACE}/kuberos-kuberos-kdc-0:/tmp/gateway.keytab -c kadmin ./gateway.keytab
kubectl cp ${NAMESPACE}/kuberos-kuberos-kdc-0:/tmp/sep.keytab -c kadmin ./sep.keytab
kubectl cp ${NAMESPACE}/kuberos-kuberos-kdc-0:/tmp/client.keytab -c kadmin ./client.keytab

kubectl create secret generic keytabs -n ${NAMESPACE} --from-file gateway.keytab --from-file client.keytab --from-file sep.keytab
kubectl apply -n ${NAMESPACE} -f krb5-conf-cm.yaml

# Create client node & test kinit
kubectl -n ${NAMESPACE} apply  -f kclient.yaml
kubectl -n ${NAMESPACE} wait --for=condition=Ready pod/kclient --timeout=60s
sleep 10 #sometimes kinit isn't found if the command is run immediately
kubectl -n ${NAMESPACE} exec kclient -- kinit -kt /etc/keytabs/client.keytab -p client

# Create certificate. We will create a single cert for both sep and the gateway for convenience
echo 1>&2 "Generating a self-signed TLS certificate"
openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
    -subj "/O=Trino Software Foundation" \
    -addext "subjectAltName=DNS:trino-gateway,DNS:coordinator,DNS:localhost,DNS:*.$NAMESPACE,DNS:*.$NAMESPACE.svc,DNS:*.$NAMESPACE.svc.cluster.local,IP:127.0.0.1" \
    -keyout cert.key -out cert.crt
cat cert.crt cert.key > cert.pem
kubectl -n "$NAMESPACE" create secret generic certificates --from-file cert.pem --from-file cert.crt --dry-run=client --output yaml | kubectl apply --filename -

## Install SEP
kubectl -n ${NAMESPACE} create secret generic mylicense --from-file ./starburstdata.license
helm -n ${NAMESPACE} upgrade starburst oci://harbor.starburstdata.net/starburstdata/charts/starburst-enterprise --install --wait --timeout 5m0s --version 464.0.0 \
  --values starburst-kustom-values-connect-directly-krb.yaml --values registry-credentials.yaml

# wait to ensure coordinator is available and ready to query.
kubectl wait pod --all --for=condition=Ready --namespace=${NAMESPACE} --timeout=120s

# Test direct connection to coordinator. If authentication is successful these requests will return json containing a `nextUri` field
response="$(kubectl -n ${NAMESPACE} exec kclient -- curl -ks --negotiate -u : https://coordinator:8443/v1/statement -d 'SELECT 1' --service-name sep | jq '.nextUri')"
if [ -z "${response}" ]; then
  echo "Query failed! Response: ${response}"
  exit 2
else
 echo 'Direct query succeeded!'
fi

## Install gateway

DB_NAMESPACE=default #update DB url in values yamls if you change this
DB_PASSWORD=pass0000

DB_INSTALLATION_NAME=gateway-backend-db
helm upgrade --install ${DB_INSTALLATION_NAME} oci://registry-1.docker.io/bitnamicharts/postgresql -n "$DB_NAMESPACE" \
    --create-namespace \
    --version "16.2.1" \
    --set common.resources.preset=micro \
    --set auth.username=gateway \
    --set auth.password=${DB_PASSWORD} \
    --set auth.database=gateway \
    --set primary.persistence.enabled=false
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql --timeout=300s -n "$DB_NAMESPACE"
kubectl --namespace "$NAMESPACE" create secret generic db-credentials --from-literal=PG_USER='gateway' --from-literal=PG_PASSWORD='pass0000'

kubectl -n ${DB_NAMESPACE} apply -f init-gateway-db.yaml

#Update SEP cluster to use trino gateway hostname & service name
helm -n ${NAMESPACE} upgrade starburst oci://harbor.starburstdata.net/starburstdata/charts/starburst-enterprise --install --wait --timeout 5m0s --version 464.0.0 \
  --values starburst-kustom-values-connect-thru-gateway.yaml --values registry-credentials.yaml
helm -n ${NAMESPACE} upgrade --install gateway trino/trino-gateway --wait --timeout 5m0s --values gateway-kustom-values.yaml

# wait again to ensure coordinator and gateway are available and ready to query.
kubectl wait pod --all --for=condition=Ready --namespace=${NAMESPACE} --timeout=300s

# Add SEP cluster to gateway
kubectl -n ${NAMESPACE} exec kclient -- curl -ks -X POST 'https://trino-gateway:8443/entity?entityType=GATEWAY_BACKEND' \
  -d '{"name": "sep", "proxyTo": "https://coordinator:8443","active": true,"routingGroup": "adhoc"}'

# Queries will fail until the gateway determines that the sep backend is healthy, which can take a minute or two
sleep 60
response="$(kubectl -n ${NAMESPACE} exec kclient -- curl -ks --negotiate -u : https://trino-gateway:8443/v1/statement -d 'SELECT 1' --service-name gateway)"
next_uri="$(echo -n "${response}" | jq '.nextUri')"
if [ -z "${next_uri}" ]; then
  echo "Query failed! Response: ${response}"
  exit 2
else
 echo 'Direct query succeeded!'
fi

echo "SUCCESS!!"

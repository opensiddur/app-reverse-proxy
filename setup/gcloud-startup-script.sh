#!/usr/bin/env bash
get_metadata() {
curl "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1?alt=text" -H "Metadata-Flavor: Google"
}

set -e

echo "Getting metadata..."
BRANCH=$(get_metadata BRANCH)
export INSTALL_DIR=/usr/local/app-reverse-proxy

echo "Setting up the opensiddur-client user..."
useradd -c "client"  client

echo "Downloading prerequisites..."
apt update
export DEBIAN_FRONTEND=noninteractive
apt-get install -yq nginx python3-certbot-nginx

echo "Obtaining app-reverse-proxy sources..."
mkdir -p /usr/local
cd /usr/local
git clone git://github.com/opensiddur/app-reverse-proxy.git
cd app-reverse-proxy
git checkout ${BRANCH}
export SRC=$(pwd)

chown -R client:client ${INSTALL_DIR}

# get some gcloud metadata:
PROJECT=$(gcloud config get-value project)
INSTANCE_NAME=$(hostname)
ZONE=$(gcloud compute instances list --filter="name=(${INSTANCE_NAME})" --format 'csv[no-heading](zone)')

export DNS_NAME="app.opensiddur.org"
export APP_DNS_NAME="app-prod.jewishliturgy.org"
# branch-specific environment settings
INSTANCE_BASE=${PROJECT}-proxy-${BRANCH//\//-}

echo "Configure nginx..."
cat conf/nginx.conf.tmpl | envsubst '$DNS_NAME $APP_DNS_NAME $INSTALL_DIR' > /etc/nginx/sites-enabled/app-proxy.conf

echo "Wait for DNS propagation..."
PUBLIC_IP=$(curl icanhazip.com)
gcloud logging -q write instance "${INSTANCE_NAME}: Running startup script from ${PUBLIC_IP}. Waiting for DNS change of ${DNS_NAME}." --severity=INFO
while [[ $(dig +short ${DNS_NAME} @resolver1.opendns.com) != "${PUBLIC_IP}" ]];
do
    echo "Waiting 1 min for ${DNS_NAME} to resolve to ${PUBLIC_IP}..."
    sleep 60;
done
gcloud logging -q write instance "${INSTANCE_NAME}: DNS propagation for ${DNS_NAME} to ${PUBLIC_IP} has completed successfully." --severity=INFO

echo "Get an SSL certificate..."
certbot --nginx -n --domain ${DNS_NAME} --email efraim@opensiddur.org --no-eff-email --agree-tos --redirect
gcloud logging -q write instance "${INSTANCE_NAME}: SSL certificate has been obtained." --severity=INFO

echo "Scheduling SSL Certificate renewal..."
cat << EOF > /etc/cron.daily/certbot_renewal
#!/bin/sh
certbot renew
EOF
chmod +x /etc/cron.daily/certbot_renewal

echo "Restarting nginx..."
systemctl restart nginx
gcloud logging -q write instance "${INSTANCE_NAME}: Web server is up." --severity=INFO

echo "Stopping prior instances..."
ALL_PRIOR_INSTANCES=$(gcloud compute instances list --filter="status=RUNNING AND name~'${INSTANCE_BASE}'" | \
       sed -n '1!p' | \
       cut -d " " -f 1 | \
       grep -v "${INSTANCE_NAME}" )
if [[ -n "${ALL_PRIOR_INSTANCES}" ]];
then
    gcloud compute instances stop ${ALL_PRIOR_INSTANCES} --zone ${ZONE};
else
    echo "No prior instances found for ${INSTANCE_BASE}";
fi
gcloud logging -q write instance "${INSTANCE_NAME}: startup script completed successfully." --severity=INFO
echo "Done"
#!/bin/bash

# Check if the required arguments are provided
if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <domain_name> <email_address> <webroot_path>"
  exit 1
fi

# Assign arguments to variables
DOMAIN_NAME=$1
EMAIL_ADDRESS=$2
WEBROOT_PATH=$3

# Run the Docker command to generate SSL certificate
docker compose -f docker-compose.yml run --rm certbot certonly \
    --webroot --webroot-path="$WEBROOT_PATH" \
    --email "$EMAIL_ADDRESS" --agree-tos --no-eff-email \
    -d "$DOMAIN_NAME"

# Check if the command was successful
if [ $? -eq 0 ]; then
  echo "SSL certificate generated successfully for $DOMAIN_NAME"
else
  echo "Failed to generate SSL certificate for $DOMAIN_NAME"
fi

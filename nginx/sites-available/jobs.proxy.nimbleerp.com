# Backend servers with sticky sessions
upstream mvc_backend {
    ip_hash;
    server backend.internal.nimbleteco.com:443 max_fails=3 fail_timeout=30s;
    server deploy.internal.nimbleteco.com:443 max_fails=3 fail_timeout=30s backup;
    keepalive 32;
}

# HTTP server
server {
    listen 80;
    server_name jobs.proxy.nimbleerp.com;

    # Let's Encrypt ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Redirect to HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl;
    server_name jobs.proxy.nimbleerp.com;

    # SSL configuration
    ssl_certificate /etc/letsencrypt/live/jobs.proxy.nimbleerp.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/jobs.proxy.nimbleerp.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    # File upload limit
    client_max_body_size 100M;

    # Reverse proxy
    location / {
        proxy_pass https://mvc_backend;
        
        # Standard headers
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $server_name;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        
        # Timeouts
        proxy_connect_timeout 10s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
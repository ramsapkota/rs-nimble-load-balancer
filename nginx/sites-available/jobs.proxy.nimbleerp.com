# MVC Backend servers with sticky sessions
upstream mvc_backend {
    ip_hash;
    server backend.internal.nimbleteco.com:443 max_fails=3 fail_timeout=30s;
    server deploy.internal.nimbleteco.com:443 max_fails=3 fail_timeout=30s backup;
    keepalive 32;
}

# HTTP server - handles Let's Encrypt challenges and redirects to HTTPS
server {
    listen 80;
    server_name jobs.proxy.nimbleerp.com;

    # Let's Encrypt ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files $uri $uri/ =404;
    }

    # Health check
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    # Redirect to HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS server - main application with SSL
server {
    listen 443 ssl http2;
    server_name jobs.proxy.nimbleerp.com;

    # SSL configuration
    ssl_certificate /etc/letsencrypt/live/jobs.proxy.nimbleerp.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/jobs.proxy.nimbleerp.com/privkey.pem;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    # Main application - sticky sessions reverse proxy
    location / {
        limit_req zone=web burst=10 nodelay;
        
        proxy_pass https://mvc_backend;
        include /etc/nginx/proxy_params.conf;
        
        proxy_connect_timeout 10s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
        
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503;
    }

    # Health check
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}

# Fallback server
server {
    listen 80 default_server;
    listen 443 ssl default_server;
    server_name _;
    
    ssl_certificate /etc/nginx/ssl/self-signed/nginx-selfsigned.crt;
    ssl_certificate_key /etc/nginx/ssl/self-signed/nginx-selfsigned.key;
    
    return 444;
}
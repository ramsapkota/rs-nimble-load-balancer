# Rate limiting zones
limit_req_zone $binary_remote_addr zone=web:10m rate=10r/s;

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

    # Let's Encrypt ACME challenge - must be accessible via HTTP
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files $uri $uri/ =404;
        
        # Allow access without SSL for certificate validation
        # Add headers to ensure proper access
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
    }

    # Health check endpoint (accessible via HTTP for load balancer checks)
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    # Redirect all other HTTP traffic to HTTPS
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
    
    # Modern SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA:ECDHE-RSA-AES128-SHA:DHE-RSA-AES256-SHA256:DHE-RSA-AES128-SHA256:DHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Main application - sticky sessions
    location / {
        limit_req zone=web burst=10 nodelay;
        
        proxy_pass https://mvc_backend;
        include /etc/nginx/proxy_params.conf;
        
        # Session affinity headers
        proxy_set_header X-Forwarded-Session $cookie_sessionid;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Port $server_port;
        
        # Longer timeouts for web requests
        proxy_connect_timeout 10s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
        
        # Health check and failover
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503;
        proxy_intercept_errors on;
    }

    # Health check endpoint (HTTPS version)
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    # Optional: Static files serving (if needed)
    location /static/ {
        alias /var/www/static/;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}

# Fallback server for unmatched domains (security measure)
server {
    listen 80 default_server;
    listen 443 ssl default_server;
    server_name _;
    
    # Dummy SSL certificate for default server
    ssl_certificate /etc/nginx/ssl/self-signed/nginx-selfsigned.crt;
    ssl_certificate_key /etc/nginx/ssl/self-signed/nginx-selfsigned.key;
    
    return 444; # Close connection without response
}
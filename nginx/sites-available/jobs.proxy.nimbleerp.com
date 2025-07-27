# MVC Backend servers with sticky sessions
upstream mvc_backend {
    ip_hash;
    server backend.internal.nimbleteco.com:443 max_fails=3 fail_timeout=30s;
    server deploy.internal.nimbleteco.com:443 max_fails=3 fail_timeout=30s backup;
    keepalive 32;
}

# Main application server
server {
    listen 443 ssl http2;
    server_name jobs.proxy.nimbleerp.com;

    # SSL configuration
    ssl_certificate /etc/letsencrypt/live/jobs.proxy.nimbleerp.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/jobs.proxy.nimbleerp.com/privkey.pem;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Main application - sticky sessions
    location / {
        limit_req zone=web burst=10 nodelay;
        
        proxy_pass http://mvc_backend;
        include /etc/nginx/proxy_params.conf;
        
        # Session affinity headers
        proxy_set_header X-Forwarded-Session $cookie_sessionid;
        
        # Longer timeouts for web requests
        proxy_connect_timeout 10s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
        
        # Health check
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503;
    }

    # Health check endpoint
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}

# HTTP to HTTPS redirect
server {
    listen 80;
    server_name jobs.proxy.nimbleerp.com;

    # Let's Encrypt challenge
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
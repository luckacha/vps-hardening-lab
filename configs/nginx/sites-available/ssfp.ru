server {
    listen 443 ssl;
    http2 on;
    server_name ssfp.ru www.ssfp.ru;

    ssl_certificate /etc/letsencrypt/live/ssfp.ru/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/ssfp.ru/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    include snippets/security-headers.conf;
    include snippets/deny-hidden.conf;

    location / {
        limit_req zone=perip burst=20 nodelay;
        limit_except GET { deny all; }
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 80;
    server_name ssfp.ru www.ssfp.ru;
    return 301 https://$host$request_uri;
}

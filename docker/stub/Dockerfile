FROM nginxinc/nginx-unprivileged:1.30.6-alpine
COPY default.conf /etc/nginx/conf.d/default.conf
COPY www/ /usr/share/nginx/html/
HEALTHCHECK --interval=30s --timeout=3s --retries=3 CMD wget -q --spider http://127.0.0.1:8080/ || exit 1

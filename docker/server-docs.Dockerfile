FROM nginx:1.29-alpine

RUN mkdir -p /usr/share/nginx/html
COPY services/server-docs /usr/share/nginx/html

RUN printf '%s\n' \
  'server {' \
  '  listen 80;' \
  '  server_name _;' \
  '  root /usr/share/nginx/html;' \
  '  index README.md index.html;' \
  '  location / {' \
  '    autoindex on;' \
  '    try_files $uri $uri/ =404;' \
  '  }' \
  '}' > /etc/nginx/conf.d/default.conf

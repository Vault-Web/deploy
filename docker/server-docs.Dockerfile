FROM nginx:1.31.9-alpine@sha256:fb4658584bd9a916ffb6f6e365f97c25cfdb2923801f551ea08356e695f14ff7

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

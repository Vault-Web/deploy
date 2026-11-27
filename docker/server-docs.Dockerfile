FROM nginx:1.31.1-alpine@sha256:8b1e78743a03dbb2c95171cc58639fef29abc8816598e27fb910ed2e621e589a

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

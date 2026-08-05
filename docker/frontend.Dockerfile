FROM node:26-alpine AS build
WORKDIR /workspace

COPY services/vault-web/frontend /workspace

# Build-time environment aligned to reverse proxy paths.
RUN cat > src/environments/environment.ts <<'EOT'
export const environment = {
  production: true,
  mainHostAddress: window.location.origin,
  mainApiUrl: '/api',
  cloudServiceApiUrl: '/cloud-api',
  passwordManagerApiUrl: '/password-api',
};
EOT

RUN npm ci
RUN npm run build

FROM nginx:1.27-alpine
COPY docker/nginx/default.conf /etc/nginx/templates/default.conf.template
COPY docker/nginx/entrypoint.sh /entrypoint.sh
COPY --from=build /workspace/dist/frontend/browser /usr/share/nginx/html
RUN chmod +x /entrypoint.sh

EXPOSE 80
ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]

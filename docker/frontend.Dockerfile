FROM node:22-alpine AS build
WORKDIR /workspace

COPY services/vault-web/frontend /workspace

# Build-time environment aligned to reverse proxy paths.
RUN cat > src/environments/environment.ts <<'EOT'
export const environment = {
  production: true,
  mainHostAddress: window.location.origin,
  mainApiUrl: '/api',
  cloudServiceApiUrl: '/cloud-api',
};
EOT

RUN npm ci
RUN npm run build

FROM nginx:1.31.10-alpine@sha256:7fc0fb4af7bf006aeb31aea88069976060f8f0a0a86b667126742cc17f4e31ae
COPY docker/nginx/default.conf /etc/nginx/templates/default.conf.template
COPY docker/nginx/entrypoint.sh /entrypoint.sh
COPY --from=build /workspace/dist/frontend/browser /usr/share/nginx/html
RUN chmod +x /entrypoint.sh

EXPOSE 80
ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]

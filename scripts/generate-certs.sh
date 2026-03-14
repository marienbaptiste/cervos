#!/usr/bin/env bash
# Cervos — Generate mTLS certificates for nginx
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$(dirname "$SCRIPT_DIR")/server/nginx/certs"

echo "=== Generating mTLS Certificates ==="

mkdir -p "$CERT_DIR"

# Generate CA
echo "Generating CA..."
openssl genrsa -out "$CERT_DIR/ca.key" 4096
openssl req -new -x509 -days 3650 -key "$CERT_DIR/ca.key" \
    -out "$CERT_DIR/ca.crt" \
    -subj "/CN=Cervos CA"

# Generate server certificate
echo "Generating server certificate..."
openssl genrsa -out "$CERT_DIR/server.key" 2048
openssl req -new -key "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.csr" \
    -subj "/CN=cervos"
openssl x509 -req -days 3650 \
    -in "$CERT_DIR/server.csr" \
    -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
    -out "$CERT_DIR/server.crt"

# Generate client certificate (for Flutter app)
echo "Generating client certificate..."
openssl genrsa -out "$CERT_DIR/client.key" 2048
openssl req -new -key "$CERT_DIR/client.key" \
    -out "$CERT_DIR/client.csr" \
    -subj "/CN=cervos-mobile"
openssl x509 -req -days 3650 \
    -in "$CERT_DIR/client.csr" \
    -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
    -out "$CERT_DIR/client.crt"

# Clean up CSRs
rm -f "$CERT_DIR"/*.csr "$CERT_DIR"/*.srl

# Generate QR code for phone pairing
echo ""
echo "Certificates generated in: $CERT_DIR"
echo "  ca.crt, server.crt, server.key, client.crt, client.key"

echo "=== Certificate generation complete ==="

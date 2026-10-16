#!/bin/bash
set -e

echo "=========================================="
echo "  AR Car Customizer - VPS Production Setup"
echo "=========================================="

if ! command -v docker &> /dev/null; then
    echo "Error: docker is not installed or not in PATH."
    exit 1
fi

echo "Building and starting production containers..."
docker compose -f docker-compose.prod.yml up -d --build

echo ""
echo "Waiting for services to become healthy..."
sleep 5

docker compose -f docker-compose.prod.yml ps

echo ""
echo "Checking backend health:"
curl -fsS http://localhost:3000/health || echo "Backend is still booting, please wait a few seconds..."

echo ""
echo "=========================================="
echo " AR Car Customizer Backend is live!"
echo " GraphQL: http://<YOUR_VPS_IP>:3000/graphql"
echo " Health:  http://<YOUR_VPS_IP>:3000/health"
echo "=========================================="

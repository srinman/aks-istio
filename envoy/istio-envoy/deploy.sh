#!/bin/bash

set -e

echo "🚀 Deploying Istio-Style Envoy with Direct Pod Endpoints"
echo "=========================================================="

# Get current pod IPs
echo ""
echo "📍 Current echo-service pod IPs:"
kubectl get pods -l app=echo-service -o custom-columns=NAME:.metadata.name,IP:.status.podIP --no-headers

# Check if pods exist
POD_COUNT=$(kubectl get pods -l app=echo-service --no-headers | wc -l)
if [ "$POD_COUNT" -lt 3 ]; then
  echo ""
  echo "⚠️  Warning: Expected 3 echo-service pods, found $POD_COUNT"
  echo "Make sure echo-service deployment is running:"
  echo "  kubectl get pods -l app=echo-service"
  exit 1
fi

# Deploy the configuration
echo ""
echo "📦 Applying Envoy configuration..."
kubectl apply -f envoy-config-direct-pods.yaml

echo ""
echo "🔧 Deploying Envoy proxy..."
kubectl apply -f envoy-deployment.yaml

# Wait for deployment
echo ""
echo "⏳ Waiting for Envoy pod to be ready..."
kubectl wait --for=condition=ready pod -l app=envoy-proxy-istio-style --timeout=120s

# Get service info
echo ""
echo "🌐 Service information:"
kubectl get svc envoy-proxy-istio-style

# Wait for LoadBalancer IP
echo ""
echo "⏳ Waiting for LoadBalancer IP assignment..."
echo "(This may take 1-2 minutes depending on your cloud provider)"

for i in {1..60}; do
  EXTERNAL_IP=$(kubectl get svc envoy-proxy-istio-style -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [ -n "$EXTERNAL_IP" ]; then
    break
  fi
  echo -n "."
  sleep 2
done

echo ""

if [ -z "$EXTERNAL_IP" ]; then
  echo "⚠️  LoadBalancer IP not assigned yet. Check with:"
  echo "  kubectl get svc envoy-proxy-istio-style -w"
  echo ""
  echo "Once IP is assigned, test with:"
  echo "  ./test-load-balancing.sh"
  exit 0
fi

echo ""
echo "✅ Deployment successful!"
echo ""
echo "📊 Testing load balancing across direct pod endpoints..."
echo ""

# Test load balancing
for i in {1..9}; do
  echo -n "Request $i: "
  HOSTNAME=$(curl -s http://$EXTERNAL_IP:8080/ 2>/dev/null | jq -r '.os.hostname' 2>/dev/null || echo "error")
  echo "$HOSTNAME"
  sleep 0.3
done

echo ""
echo "🔍 Verifying Envoy sees all 3 pod endpoints..."
kubectl exec deployment/envoy-proxy-istio-style -c envoy -- \
  curl -s localhost:9901/clusters 2>/dev/null | grep -A 20 "echo_cluster_direct_pods::" | grep "socket_address" || \
  kubectl exec deployment/envoy-proxy-istio-style -c envoy -- \
  curl -s localhost:9901/clusters 2>/dev/null | grep "echo_cluster_direct_pods::"

echo ""
echo "✨ Deployment complete!"
echo ""
echo "Access points:"
echo "  HTTP endpoint:  http://$EXTERNAL_IP:8080"
echo "  Admin console:  http://$EXTERNAL_IP:9901"
echo ""
echo "Useful commands:"
echo "  ./test-load-balancing.sh          # Test traffic distribution"
echo "  ./compare-with-basic-envoy.sh     # Compare with basic Envoy setup"
echo ""
echo "Next steps:"
echo "  - Read README.md for detailed explanation"
echo "  - Check admin console: kubectl port-forward svc/envoy-proxy-istio-style 9901:9901"
echo "  - View access logs: kubectl logs -f deployment/envoy-proxy-istio-style"

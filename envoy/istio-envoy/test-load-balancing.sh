#!/bin/bash

echo "🧪 Testing Istio-Style Envoy Load Balancing"
echo "============================================"

EXTERNAL_IP=$(kubectl get svc envoy-proxy-istio-style -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

if [ -z "$EXTERNAL_IP" ]; then
  echo "❌ LoadBalancer IP not found. Is the service deployed?"
  echo "Run: kubectl get svc envoy-proxy-istio-style"
  exit 1
fi

echo "Target: http://$EXTERNAL_IP:8080"
echo ""

# Test 1: Basic load balancing
echo "📊 Test 1: Load Balancing Distribution (30 requests)"
echo "-----------------------------------------------------"

RESULTS=$(mktemp)
for i in {1..30}; do
  curl -s http://$EXTERNAL_IP:8080/ 2>/dev/null | jq -r '.os.hostname' 2>/dev/null >> "$RESULTS" || echo "error" >> "$RESULTS"
done

echo "Distribution:"
sort "$RESULTS" | uniq -c | sort -rn

UNIQUE_PODS=$(sort "$RESULTS" | uniq | grep -v "error" | wc -l)
echo ""
echo "✅ Unique pods reached: $UNIQUE_PODS (expected: 3)"

# Test 2: Verify round-robin pattern
echo ""
echo "📊 Test 2: Round-Robin Pattern Verification (9 requests)"
echo "--------------------------------------------------------"

for i in {1..9}; do
  HOSTNAME=$(curl -s http://$EXTERNAL_IP:8080/ 2>/dev/null | jq -r '.os.hostname' 2>/dev/null || echo "error")
  echo "Request $i: $HOSTNAME"
  sleep 0.2
done

# Test 3: Check Envoy cluster status
echo ""
echo "📊 Test 3: Envoy Cluster Endpoint Status"
echo "-----------------------------------------"

kubectl exec deployment/envoy-proxy-istio-style -c envoy -- \
  curl -s localhost:9901/clusters 2>/dev/null | grep "echo_cluster_direct_pods::" | head -15

# Test 4: Response headers verification
echo ""
echo "📊 Test 4: Envoy-Added Headers"
echo "-------------------------------"

curl -s -D - http://$EXTERNAL_IP:8080/ 2>/dev/null | grep -E "(x-envoy|x-forwarded|x-request-id)" | head -10

# Cleanup
rm -f "$RESULTS"

echo ""
echo "✨ Testing complete!"
echo ""
echo "Key observations:"
echo "  1. Each pod should receive ~10 requests (exact round-robin)"
echo "  2. Pattern should be pod1 → pod2 → pod3 → pod1 → ..."
echo "  3. Envoy controls the load balancing (not Kubernetes Service)"
echo ""
echo "Compare with basic Envoy setup:"
echo "  ./compare-with-basic-envoy.sh"

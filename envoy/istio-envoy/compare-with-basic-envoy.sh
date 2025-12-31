#!/bin/bash

echo "🔍 Comparing Basic Envoy vs Istio-Style Envoy"
echo "=============================================="

# Get both external IPs
BASIC_IP=$(kubectl get svc envoy-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
ISTIO_IP=$(kubectl get svc envoy-proxy-istio-style -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

if [ -z "$BASIC_IP" ] || [ -z "$ISTIO_IP" ]; then
  echo "❌ One or both Envoy services not found"
  echo "Basic Envoy IP: ${BASIC_IP:-NOT FOUND}"
  echo "Istio-style Envoy IP: ${ISTIO_IP:-NOT FOUND}"
  echo ""
  echo "Deploy both services:"
  echo "  Basic: cd ../.. && kubectl apply -f envoy-config.yaml"
  echo "  Istio: cd istio-envoy && ./deploy.sh"
  exit 1
fi

echo ""
echo "Configuration Comparison"
echo "------------------------"
echo "Basic Envoy:       http://$BASIC_IP:8080"
echo "Istio-style Envoy: http://$ISTIO_IP:8080"
echo ""

# Compare cluster configurations
echo "📊 Cluster Endpoint Comparison"
echo "==============================="
echo ""
echo "Basic Envoy Clusters (via Kubernetes Service):"
echo "-----------------------------------------------"
kubectl exec deployment/envoy-proxy -c envoy -- \
  curl -s localhost:9901/clusters 2>/dev/null | grep "echo_cluster::" | head -5

echo ""
echo "Istio-style Envoy Clusters (Direct Pod IPs):"
echo "---------------------------------------------"
kubectl exec deployment/envoy-proxy-istio-style -c envoy -- \
  curl -s localhost:9901/clusters 2>/dev/null | grep "echo_cluster_direct_pods::" | head -15

echo ""
echo "📊 Load Balancing Test (12 requests each)"
echo "=========================================="

# Test basic Envoy
echo ""
echo "Basic Envoy Distribution:"
echo "-------------------------"
BASIC_RESULTS=$(mktemp)
for i in {1..12}; do
  curl -s http://$BASIC_IP:8080/ 2>/dev/null | jq -r '.os.hostname' 2>/dev/null >> "$BASIC_RESULTS" || echo "error" >> "$BASIC_RESULTS"
done
sort "$BASIC_RESULTS" | uniq -c | sort -rn

# Test Istio-style Envoy
echo ""
echo "Istio-style Envoy Distribution:"
echo "--------------------------------"
ISTIO_RESULTS=$(mktemp)
for i in {1..12}; do
  curl -s http://$ISTIO_IP:8080/ 2>/dev/null | jq -r '.os.hostname' 2>/dev/null >> "$ISTIO_RESULTS" || echo "error" >> "$ISTIO_RESULTS"
done
sort "$ISTIO_RESULTS" | uniq -c | sort -rn

# Analysis
echo ""
echo "📊 Analysis"
echo "==========="
echo ""

BASIC_UNIQUE=$(sort "$BASIC_RESULTS" | uniq | grep -v "error" | wc -l)
ISTIO_UNIQUE=$(sort "$ISTIO_RESULTS" | uniq | grep -v "error" | wc -l)

echo "Unique pods reached:"
echo "  Basic Envoy:       $BASIC_UNIQUE (may vary - Kubernetes Service controls LB)"
echo "  Istio-style Envoy: $ISTIO_UNIQUE (should be 3 - Envoy controls LB)"
echo ""

echo "Key Differences:"
echo "----------------"
echo ""
echo "Basic Envoy (via Kubernetes Service):"
echo "  • Envoy sees: 1 endpoint (Kubernetes Service ClusterIP)"
echo "  • Load balancing: Done by Kubernetes (kube-proxy/iptables)"
echo "  • Distribution: May be uneven due to connection reuse"
echo "  • Target: echo-service:3000 → ClusterIP → Pods"
echo ""
echo "Istio-style Envoy (Direct Pod IPs):"
echo "  • Envoy sees: 3 endpoints (individual pod IPs)"
echo "  • Load balancing: Done by Envoy (ROUND_ROBIN policy)"
echo "  • Distribution: Exact round-robin (4-4-4 for 12 requests)"
echo "  • Target: Direct to pod IPs (10.244.x.x:8080)"
echo ""

echo "Why Istio Uses Direct Pod Routing:"
echo "----------------------------------"
echo "  ✓ Fine-grained traffic control (per-pod circuit breaking)"
echo "  ✓ Advanced routing (weighted, header-based)"
echo "  ✓ Better observability (per-pod metrics)"
echo "  ✓ Sophisticated resilience (outlier detection, retries to different pods)"
echo "  ✓ No dependency on Kubernetes Service load balancing"
echo ""

# Cleanup
rm -f "$BASIC_RESULTS" "$ISTIO_RESULTS"

echo "🎓 Learning Resources:"
echo "  - README.md in this directory"
echo "  - ../simple-envoy.md for basic Envoy setup"
echo "  - ../../lab-istio/istio-traffic-management.md for Istio details"

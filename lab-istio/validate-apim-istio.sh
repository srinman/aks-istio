#!/bin/bash

# APIM-Istio Integration Validation Script
# This script validates the APIM to Istio integration and provides troubleshooting information

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_status() {
    if [ $1 -eq 0 ]; then
        log_success "$2"
    else
        log_error "$2"
    fi
}

echo "🔍 APIM-Istio Integration Validation"
echo "===================================="
echo ""

# Check 1: Internal Istio Gateway
log_info "Checking internal Istio gateway..."
kubectl get svc aks-istio-ingressgateway-internal -n aks-istio-ingress > /dev/null 2>&1
check_status $? "Internal Istio gateway service exists"

INTERNAL_IP=$(kubectl get svc aks-istio-ingressgateway-internal -n aks-istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [[ -n "$INTERNAL_IP" ]]; then
    log_success "Internal gateway IP: $INTERNAL_IP"
else
    log_error "Internal gateway IP not assigned"
fi

# Check 2: Gateway configuration
log_info "Checking Gateway configuration..."
kubectl get gateway apim-gateway-internal > /dev/null 2>&1
check_status $? "APIM Gateway exists"

# Check 3: VirtualService configuration
log_info "Checking VirtualService configuration..."
kubectl get virtualservice apim-bookinfo-vs > /dev/null 2>&1
check_status $? "APIM VirtualService exists"

# Check 4: TLS certificates
log_info "Checking TLS certificates..."
kubectl get secret istio-gateway-certs -n aks-istio-ingress > /dev/null 2>&1
check_status $? "TLS certificate secret exists"

# Check certificate expiration
if kubectl get secret istio-gateway-certs -n aks-istio-ingress > /dev/null 2>&1; then
    CERT_DATA=$(kubectl get secret istio-gateway-certs -n aks-istio-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d)
    EXPIRY_DATE=$(echo "$CERT_DATA" | openssl x509 -noout -enddate | cut -d= -f2)
    EXPIRY_TIMESTAMP=$(date -d "$EXPIRY_DATE" +%s)
    CURRENT_TIMESTAMP=$(date +%s)
    DAYS_UNTIL_EXPIRY=$(( (EXPIRY_TIMESTAMP - CURRENT_TIMESTAMP) / 86400 ))
    
    if [ $DAYS_UNTIL_EXPIRY -gt 30 ]; then
        log_success "Certificate expires in $DAYS_UNTIL_EXPIRY days"
    elif [ $DAYS_UNTIL_EXPIRY -gt 7 ]; then
        log_warning "Certificate expires in $DAYS_UNTIL_EXPIRY days - consider renewal soon"
    else
        log_error "Certificate expires in $DAYS_UNTIL_EXPIRY days - renewal required!"
    fi
fi

# Check 5: Istio proxy configuration
log_info "Checking Istio proxy configuration..."
GATEWAY_POD=$(kubectl get pods -n aks-istio-ingress -l app=aks-istio-ingressgateway-internal -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$GATEWAY_POD" ]]; then
    log_success "Gateway pod found: $GATEWAY_POD"
    
    # Check listeners
    log_info "Checking gateway listeners..."
    istioctl -n aks-istio-ingress proxy-config listener "$GATEWAY_POD" --port 443 > /dev/null 2>&1
    check_status $? "HTTPS listener configured on port 443"
    
    # Check certificate configuration
    log_info "Checking certificate configuration in proxy..."
    istioctl -n aks-istio-ingress proxy-config secret "$GATEWAY_POD" | grep -q "istio-gateway-certs"
    check_status $? "TLS certificate loaded in proxy"
    
else
    log_error "Gateway pod not found"
fi

# Check 6: Bookinfo application
log_info "Checking Bookinfo application..."
kubectl get pod -l app=productpage > /dev/null 2>&1
check_status $? "Productpage service exists"

kubectl get svc productpage > /dev/null 2>&1
check_status $? "Productpage service exists"

# Check 7: Connectivity test
log_info "Testing internal connectivity..."
if [[ -n "$INTERNAL_IP" ]]; then
    # Test HTTP to HTTPS redirect
    HTTP_RESPONSE=$(kubectl run test-connectivity --image=curlimages/curl:latest --rm -i --restart=Never -- \
        curl -s -o /dev/null -w "%{http_code}" -H "Host: bookinfo.istio.local" "http://$INTERNAL_IP/health" 2>/dev/null || echo "000")
    
    if [[ "$HTTP_RESPONSE" == "301" || "$HTTP_RESPONSE" == "302" ]]; then
        log_success "HTTP to HTTPS redirect working (status: $HTTP_RESPONSE)"
    else
        log_warning "HTTP redirect status: $HTTP_RESPONSE"
    fi
    
    # Test HTTPS endpoint
    HTTPS_RESPONSE=$(kubectl run test-https --image=curlimages/curl:latest --rm -i --restart=Never -- \
        curl -k -s -o /dev/null -w "%{http_code}" -H "Host: bookinfo.istio.local" "https://$INTERNAL_IP/health" 2>/dev/null || echo "000")
    
    if [[ "$HTTPS_RESPONSE" == "200" ]]; then
        log_success "HTTPS endpoint responding (status: $HTTPS_RESPONSE)"
    else
        log_error "HTTPS endpoint not responding (status: $HTTPS_RESPONSE)"
    fi
else
    log_warning "Skipping connectivity test - no internal IP available"
fi

# Check 8: Istio configuration validation
log_info "Validating Istio configuration..."
istioctl analyze > /dev/null 2>&1
check_status $? "Istio configuration validation passed"

# Check 9: Gateway resource allocation
log_info "Checking gateway resource allocation..."
if [[ -n "$GATEWAY_POD" ]]; then
    CPU_USAGE=$(kubectl top pod "$GATEWAY_POD" -n aks-istio-ingress --no-headers | awk '{print $2}' 2>/dev/null || echo "N/A")
    MEMORY_USAGE=$(kubectl top pod "$GATEWAY_POD" -n aks-istio-ingress --no-headers | awk '{print $3}' 2>/dev/null || echo "N/A")
    
    if [[ "$CPU_USAGE" != "N/A" ]]; then
        log_success "Gateway resource usage - CPU: $CPU_USAGE, Memory: $MEMORY_USAGE"
    else
        log_warning "Metrics server not available - cannot check resource usage"
    fi
fi

echo ""
echo "📊 Configuration Summary"
echo "========================"

# Display gateway configuration
if kubectl get gateway apim-gateway-internal > /dev/null 2>&1; then
    echo ""
    echo "🔧 Gateway Configuration:"
    kubectl get gateway apim-gateway-internal -o yaml | grep -A 20 "spec:" | sed 's/^/   /'
fi

# Display virtual service configuration
if kubectl get virtualservice apim-bookinfo-vs > /dev/null 2>&1; then
    echo ""
    echo "🔀 VirtualService Configuration:"
    kubectl get virtualservice apim-bookinfo-vs -o yaml | grep -A 30 "spec:" | sed 's/^/   /'
fi

echo ""
echo "🔍 Troubleshooting Commands"
echo "==========================="
echo ""
echo "View gateway logs:"
echo "  kubectl logs -n aks-istio-ingress -l app=aks-istio-ingressgateway-internal --tail=50"
echo ""
echo "Check gateway configuration:"
echo "  istioctl -n aks-istio-ingress proxy-config listener \$GATEWAY_POD"
echo ""
echo "Check certificate configuration:"
echo "  istioctl -n aks-istio-ingress proxy-config secret \$GATEWAY_POD"
echo ""
echo "Test internal connectivity:"
echo "  kubectl run test-pod --image=curlimages/curl:latest --rm -it --restart=Never -- \\"
echo "    curl -k -v -H 'Host: bookinfo.istio.local' https://$INTERNAL_IP/health"
echo ""
echo "Check Istio configuration:"
echo "  istioctl analyze"
echo ""
echo "View proxy configuration:"
echo "  istioctl proxy-config cluster \$GATEWAY_POD -n aks-istio-ingress"

echo ""
echo "✅ Validation completed!"
echo ""
echo "If you see any errors above, refer to the troubleshooting section"
echo "in the lab guide: istio-ingress-with-apim.md"

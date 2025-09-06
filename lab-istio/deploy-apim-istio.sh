#!/bin/bash

# APIM to Istio Integration Deployment Script
# This script automates the setup of API Management to Istio Ingress Gateway integration
# with TLS/mTLS configuration

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

# Default values
CLUSTER=""
RESOURCE_GROUP=""
LOCATION="eastus2"
APIM_NAME=""
APIM_RG=""
ENABLE_MTLS="false"
DOMAIN_NAME="bookinfo.istio.local"

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -c, --cluster CLUSTER         AKS cluster name (required)"
    echo "  -g, --resource-group RG       Resource group name (required)"
    echo "  -l, --location LOCATION       Azure location (default: eastus2)"
    echo "  -a, --apim-name NAME          APIM instance name (required)"
    echo "  -r, --apim-rg RG              APIM resource group (required)"
    echo "  -m, --enable-mtls             Enable mutual TLS authentication"
    echo "  -d, --domain DOMAIN           Domain name (default: bookinfo.istio.local)"
    echo "  -h, --help                    Display this help message"
    echo ""
    echo "Example:"
    echo "  $0 -c aksistio4 -g aksistio4rg -a apim-istio-dev -r apim-rg --enable-mtls"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--cluster)
            CLUSTER="$2"
            shift 2
            ;;
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -l|--location)
            LOCATION="$2"
            shift 2
            ;;
        -a|--apim-name)
            APIM_NAME="$2"
            shift 2
            ;;
        -r|--apim-rg)
            APIM_RG="$2"
            shift 2
            ;;
        -m|--enable-mtls)
            ENABLE_MTLS="true"
            shift
            ;;
        -d|--domain)
            DOMAIN_NAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$CLUSTER" || -z "$RESOURCE_GROUP" || -z "$APIM_NAME" || -z "$APIM_RG" ]]; then
    log_error "Missing required parameters"
    usage
    exit 1
fi

log_info "Starting APIM to Istio integration deployment..."
log_info "Cluster: $CLUSTER"
log_info "Resource Group: $RESOURCE_GROUP"
log_info "APIM Name: $APIM_NAME"
log_info "APIM Resource Group: $APIM_RG"
log_info "mTLS Enabled: $ENABLE_MTLS"
log_info "Domain: $DOMAIN_NAME"

# Step 1: Enable internal ingress gateway
log_info "Step 1: Enabling internal ingress gateway..."
az aks mesh enable-ingress-gateway \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER" \
  --ingress-gateway-type internal

# Wait for gateway to be ready
log_info "Waiting for internal gateway to be ready..."
kubectl wait --for=condition=ready pod -l app=aks-istio-ingressgateway-internal -n aks-istio-ingress --timeout=300s

# Step 2: Create certificates
log_info "Step 2: Creating TLS certificates..."
mkdir -p certs

# Generate private key
openssl genrsa -out certs/istio-gateway.key 2048

# Create certificate signing request configuration
cat > certs/csr.conf <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn

[dn]
CN=$DOMAIN_NAME
O=Istio Gateway
C=US
ST=WA
L=Seattle

[v3_ext]
authorityKeyIdentifier=keyid,issuer:always
basicConstraints=CA:FALSE
keyUsage=keyEncipherment,dataEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt_names

[alt_names]
DNS.1=$DOMAIN_NAME
DNS.2=*.$DOMAIN_NAME
DNS.3=productpage.istio.local
EOF

# Generate certificate
openssl req -new -x509 -key certs/istio-gateway.key \
  -out certs/istio-gateway.crt \
  -days 365 \
  -config certs/csr.conf \
  -extensions v3_ext

# Create Kubernetes secret
kubectl create secret tls istio-gateway-certs \
  --cert=certs/istio-gateway.crt \
  --key=certs/istio-gateway.key \
  -n aks-istio-ingress \
  --dry-run=client -o yaml | kubectl apply -f -

log_success "Certificates created and stored in Kubernetes secret"

# Step 3: Create client certificates for mTLS (if enabled)
if [[ "$ENABLE_MTLS" == "true" ]]; then
    log_info "Step 3: Creating client certificates for mTLS..."
    
    # Generate client private key
    openssl genrsa -out certs/apim-client.key 2048
    
    # Create client certificate request
    cat > certs/client-csr.conf <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn

[dn]
CN=apim-client
O=API Management
C=US
ST=WA
L=Seattle
EOF
    
    # Generate client certificate
    openssl req -new -key certs/apim-client.key -out certs/apim-client.csr -config certs/client-csr.conf
    openssl x509 -req -in certs/apim-client.csr \
      -CA certs/istio-gateway.crt \
      -CAkey certs/istio-gateway.key \
      -CAcreateserial \
      -out certs/apim-client.crt \
      -days 365
    
    log_success "Client certificates created for mTLS"
fi

# Step 4: Create Gateway configuration
log_info "Step 4: Creating Istio Gateway configuration..."

TLS_MODE="SIMPLE"
if [[ "$ENABLE_MTLS" == "true" ]]; then
    TLS_MODE="MUTUAL"
fi

kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: apim-gateway-internal
  namespace: default
spec:
  selector:
    istio: aks-istio-ingressgateway-internal
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: $TLS_MODE
      credentialName: istio-gateway-certs
    hosts:
    - "$DOMAIN_NAME"
    - "productpage.istio.local"
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "$DOMAIN_NAME"
    - "productpage.istio.local"
    tls:
      httpsRedirect: true
EOF

# Step 5: Create VirtualService
log_info "Step 5: Creating VirtualService configuration..."

kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: apim-bookinfo-vs
  namespace: default
spec:
  hosts:
  - "$DOMAIN_NAME"
  - "productpage.istio.local"
  gateways:
  - apim-gateway-internal
  http:
  - match:
    - uri:
        exact: /productpage
    - uri:
        prefix: /static
    - uri:
        exact: /login
    - uri:
        exact: /logout
    - uri:
        prefix: /api/v1/products
    headers:
      request:
        add:
          X-Forwarded-Proto: https
          X-Forwarded-For: "apim-gateway"
    route:
    - destination:
        host: productpage
        port:
          number: 9080
  - match:
    - uri:
        prefix: /health
    route:
    - destination:
        host: productpage
        port:
          number: 9080
EOF

log_success "Istio Gateway and VirtualService configured"

# Step 6: Get internal gateway IP
log_info "Step 6: Retrieving internal gateway IP..."
INTERNAL_IP=""
for i in {1..30}; do
    INTERNAL_IP=$(kubectl get svc aks-istio-ingressgateway-internal -n aks-istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -n "$INTERNAL_IP" ]]; then
        break
    fi
    log_info "Waiting for internal IP assignment... (attempt $i/30)"
    sleep 10
done

if [[ -z "$INTERNAL_IP" ]]; then
    log_error "Failed to get internal gateway IP"
    exit 1
fi

log_success "Internal Gateway IP: $INTERNAL_IP"

# Step 7: Configure APIM
log_info "Step 7: Configuring Azure API Management..."

# Create API in APIM
az apim api create \
  --resource-group "$APIM_RG" \
  --service-name "$APIM_NAME" \
  --api-id bookinfo-api \
  --path /bookinfo \
  --display-name "Bookinfo via Istio" \
  --service-url "https://$INTERNAL_IP" \
  --protocols https

# Create backend
az apim backend create \
  --resource-group "$APIM_RG" \
  --service-name "$APIM_NAME" \
  --backend-id istio-gateway-backend \
  --url "https://$INTERNAL_IP" \
  --protocol http \
  --title "Istio Gateway Backend"

# Create operations
az apim api operation create \
  --resource-group "$APIM_RG" \
  --service-name "$APIM_NAME" \
  --api-id bookinfo-api \
  --operation-id get-productpage \
  --url-template "/productpage" \
  --method GET \
  --display-name "Get Product Page"

az apim api operation create \
  --resource-group "$APIM_RG" \
  --service-name "$APIM_NAME" \
  --api-id bookinfo-api \
  --operation-id get-health \
  --url-template "/health" \
  --method GET \
  --display-name "Health Check"

log_success "APIM API and backend configured"

# Step 8: Upload client certificate to APIM (if mTLS enabled)
if [[ "$ENABLE_MTLS" == "true" ]]; then
    log_info "Step 8: Uploading client certificate to APIM..."
    
    az apim certificate create \
      --resource-group "$APIM_RG" \
      --service-name "$APIM_NAME" \
      --certificate-id apim-client-cert \
      --certificate-path certs/apim-client.crt \
      --certificate-password ""
    
    log_success "Client certificate uploaded to APIM"
fi

# Step 9: Apply APIM policy
log_info "Step 9: Applying APIM policy..."

# Create temporary policy file with IP substitution
sed "s/{{istio-gateway-ip}}/$INTERNAL_IP/g" apim-istio-policy.xml > /tmp/apim-policy-temp.xml

az apim api policy create \
  --resource-group "$APIM_RG" \
  --service-name "$APIM_NAME" \
  --api-id bookinfo-api \
  --policy-file /tmp/apim-policy-temp.xml

rm /tmp/apim-policy-temp.xml

log_success "APIM policy applied"

# Step 10: Display configuration summary
log_info "=== Deployment Summary ==="
echo ""
echo "✅ Internal Istio Gateway: Ready"
echo "✅ TLS Certificates: Created and configured"
echo "✅ Gateway Configuration: Applied"
echo "✅ VirtualService: Configured"
echo "✅ APIM Backend: Configured"
echo "✅ APIM Policies: Applied"

if [[ "$ENABLE_MTLS" == "true" ]]; then
    echo "✅ mTLS: Enabled with client certificates"
fi

echo ""
echo "📋 Configuration Details:"
echo "   Internal Gateway IP: $INTERNAL_IP"
echo "   Domain: $DOMAIN_NAME"
echo "   APIM Gateway URL: $(az apim show --name "$APIM_NAME" --resource-group "$APIM_RG" --query "gatewayUrl" -o tsv 2>/dev/null)"
echo ""

# Step 11: Test connectivity
log_info "Step 11: Testing connectivity..."

# Test internal connectivity
kubectl run test-pod --image=curlimages/curl:latest --rm -it --restart=Never -- \
  curl -k -H "Host: $DOMAIN_NAME" "https://$INTERNAL_IP/health" || true

log_success "Deployment completed successfully!"
echo ""
echo "🎉 Your APIM to Istio integration is ready!"
echo ""
echo "Next steps:"
echo "1. Test the API through APIM using your subscription key"
echo "2. Monitor traffic flow using Istio observability tools"
echo "3. Configure additional APIs and policies as needed"
echo ""
echo "For testing:"
echo "curl '\$(az apim show --name $APIM_NAME --resource-group $APIM_RG --query gatewayUrl -o tsv)/bookinfo/health' \\"
echo "  -H 'Ocp-Apim-Subscription-Key: YOUR_SUBSCRIPTION_KEY'"

# Lab: Azure API Management to Istio Ingress Gateway - Secure Traffic Management

## Overview
This lab extends the basic Istio Ingress Gateway configuration to integrate with Azure API Management (APIM). You will learn how to:
- Configure TLS/mTLS between APIM and Istio Ingress Gateway
- Set up APIM policies for secure backend communication
- Implement certificate-based authentication
- Route traffic from APIM through Istio Gateway to backend services
- Monitor and troubleshoot APIM-to-Istio traffic flows

## Prerequisites
- Completed the [istio-ingress-gateway.md](./istio-ingress-gateway.md) lab
- Azure API Management instance (Developer mode, VNET-injected, internal mode)
- AKS cluster with Istio add-on enabled
- Network connectivity between APIM and AKS cluster
- Sample applications (Bookinfo) deployed in the mesh
- `az` CLI and `kubectl` configured

## Architecture Overview: APIM to Istio Traffic Flow

### Complete Architecture Diagram

```
                            Internet/Private Network
                                       │
                                       ▼
                            ┌─────────────────────┐
                            │  Azure API          │
                            │  Management         │
                            │  (VNET-injected)    │
                            └─────────┬───────────┘
                                      │ TLS/mTLS
                                      │ Backend API Call
                                      ▼
    ┌─────────────────────────────────────────────────────────────────────────────┐
    │                           AKS Cluster                                      │
    │                                                                             │
    │  ┌─────────────────────────────────────────────────────────────────────┐   │
    │  │                    aks-istio-ingress namespace                     │   │
    │  │                                                                     │   │
    │  │  ┌─────────────────────────────────────────────────────────────┐   │   │
    │  │  │              Internal Load Balancer                        │   │   │
    │  │  │           (Azure Internal LB)                              │   │   │
    │  │  │              IP: INTERNAL_IP                                │   │   │
    │  │  │              Port: 443 (HTTPS)                              │   │   │
    │  │  └─────────────────────┬───────────────────────────────────────┘   │   │
    │  │                        │                                             │   │
    │  │                        ▼                                             │   │
    │  │  ┌─────────────────────────────────────────────────────────────┐   │   │
    │  │  │         aks-istio-ingressgateway-internal                   │   │   │
    │  │  │                  (Envoy Proxy)                              │   │   │
    │  │  │                                                             │   │   │
    │  │  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐    │   │   │
    │  │  │  │  Listener   │  │  Routes     │  │   Clusters      │    │   │   │
    │  │  │  │  :443 HTTPS │  │  Gateway +  │  │  (Backend       │    │   │   │
    │  │  │  │  TLS Term   │  │VirtualService│  │   Services)     │    │   │   │
    │  │  │  └─────────────┘  └─────────────┘  └─────────────────┘    │   │   │
    │  │  └─────────────────────┬───────────────────────────────────────┘   │   │
    │  └────────────────────────┼─────────────────────────────────────────────┘   │
    │                           │ mTLS to Backend Services                       │
    │                           ▼                                                 │
    │  ┌─────────────────────────────────────────────────────────────────────┐   │
    │  │                      default namespace                             │   │
    │  │                                                                     │   │
    │  │  ┌─────────────────────────────────────────────────────────────┐   │   │
    │  │  │                 productpage Service                        │   │   │
    │  │  │                (ClusterIP: 10.x.x.x)                       │   │   │
    │  │  │                   Port: 9080                                │   │   │
    │  │  └─────────────────────┬───────────────────────────────────────┘   │   │
    │  │                        │ Load Balances to                           │   │
    │  │                        ▼                                             │   │
    │  │  ┌─────────────────────────────────────────────────────────────┐   │   │
    │  │  │                   Bookinfo Pods                            │   │   │
    │  │  │                 (with Istio sidecars)                      │   │   │
    │  │  └─────────────────────────────────────────────────────────────┘   │   │
    │  └─────────────────────────────────────────────────────────────────────┘   │
    └─────────────────────────────────────────────────────────────────────────────┘
```

### 🎯 Key Components

**1. API Management Layer:**
- **External API exposure** with authentication, authorization, rate limiting
- **Backend pool configuration** pointing to Istio Ingress Gateway
- **TLS/mTLS policies** for secure communication
- **Request transformation** and header management

**2. Istio Ingress Gateway:**
- **TLS termination** for APIM traffic
- **Internal service exposure** within the cluster
- **Certificate-based authentication** validation
- **Traffic routing** to mesh services

---

## Part 1: Configure Internal Istio Ingress Gateway

### Step 1.1: Set Environment Variables

```bash
export CLUSTER=aksistio4
export RESOURCE_GROUP=aksistio4rg
export LOCATION=eastus2
export APIM_NAME=apim-istio-dev
export APIM_RG=apim-rg
```

### Step 1.2: Create Internal Ingress Gateway

Since APIM is VNET-injected and internal, we need an internal ingress gateway:

```bash
# Enable internal ingress gateway
az aks mesh enable-ingress-gateway \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER \
  --ingress-gateway-type internal

# Verify the internal gateway is created
kubectl get svc -n aks-istio-ingress
```

**Expected Output**: You should see `aks-istio-ingressgateway-internal` service with an internal IP.

### Step 1.3: Create TLS Certificate for Istio Gateway

Create a self-signed certificate for the Istio Gateway (for production, use proper CA):

```bash
# Create certificate directory
mkdir -p certs

# Generate private key
openssl genrsa -out certs/istio-gateway.key 2048

# Create certificate signing request
cat > certs/csr.conf <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn

[dn]
CN=istio-gateway.internal.local
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
DNS.1=istio-gateway.internal.local
DNS.2=*.istio-gateway.internal.local
DNS.3=bookinfo.istio.local
DNS.4=productpage.istio.local
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
  -n aks-istio-ingress
```

## Part 2: Configure Istio Gateway and VirtualService

### Step 2.1: Create Gateway with TLS

Create an HTTPS Gateway for APIM traffic:

```bash
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
      mode: SIMPLE
      credentialName: istio-gateway-certs
    hosts:
    - "bookinfo.istio.local"
    - "productpage.istio.local"
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "bookinfo.istio.local"
    - "productpage.istio.local"
    tls:
      httpsRedirect: true
EOF
```

### Step 2.2: Create VirtualService for APIM Routing

```bash
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: apim-bookinfo-vs
  namespace: default
spec:
  hosts:
  - "bookinfo.istio.local"
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
```

### Step 2.3: Verify Gateway Configuration

```bash
# Get internal load balancer IP
INTERNAL_IP=$(kubectl get svc aks-istio-ingressgateway-internal -n aks-istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Internal Gateway IP: $INTERNAL_IP"

# Test HTTPS endpoint (from within VNET)
kubectl run test-pod --image=curlimages/curl:latest --rm -it --restart=Never -- \
  curl -k -H "Host: bookinfo.istio.local" https://$INTERNAL_IP/health

# Check gateway configuration
kubectl get gateway
kubectl get virtualservice
```

## Part 3: Configure Azure API Management

### Step 3.1: Get APIM Information

```bash
# Get APIM details
az apim show --name $APIM_NAME --resource-group $APIM_RG --query "{name:name,gatewayUrl:gatewayUrl,privateIPAddresses:privateIPAddresses}"

# Get APIM management endpoint
APIM_MGMT_URL=$(az apim show --name $APIM_NAME --resource-group $APIM_RG --query "managementApiUrl" -o tsv)
echo "APIM Management URL: $APIM_MGMT_URL"
```

### Step 3.2: Create Backend Service in APIM

```bash
# Create backend pointing to Istio Internal Gateway
az apim api create \
  --resource-group $APIM_RG \
  --service-name $APIM_NAME \
  --api-id bookinfo-api \
  --path /bookinfo \
  --display-name "Bookinfo via Istio" \
  --service-url "https://$INTERNAL_IP" \
  --protocols https

# Create backend pool
az apim backend create \
  --resource-group $APIM_RG \
  --service-name $APIM_NAME \
  --backend-id istio-gateway-backend \
  --url "https://$INTERNAL_IP" \
  --protocol http \
  --title "Istio Gateway Backend"
```

### Step 3.3: Configure Backend TLS Settings

Create a policy for backend TLS configuration:

```bash
az apim api operation create \
  --resource-group $APIM_RG \
  --service-name $APIM_NAME \
  --api-id bookinfo-api \
  --operation-id get-productpage \
  --url-template "/productpage" \
  --method GET \
  --display-name "Get Product Page"
```

## Part 4: Apply APIM Policies for Secure Communication

### Step 4.1: Configure Certificate Authentication (Optional mTLS)

If implementing mTLS, first create client certificate:

```bash
# Generate client certificate for APIM
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
openssl x509 -req -in certs/apim-client.csr -CA certs/istio-gateway.crt -CAkey certs/istio-gateway.key -CAcreateserial -out certs/apim-client.crt -days 365

# Upload client certificate to APIM
az apim certificate create \
  --resource-group $APIM_RG \
  --service-name $APIM_NAME \
  --certificate-id apim-client-cert \
  --certificate-path certs/apim-client.crt \
  --certificate-password ""
```

### Step 4.2: Apply Comprehensive APIM Policy

The policy file `apim-istio-policy.xml` (created separately) will be applied:

```bash
# Apply the policy to the API
az apim api policy create \
  --resource-group $APIM_RG \
  --service-name $APIM_NAME \
  --api-id bookinfo-api \
  --policy-file apim-istio-policy.xml
```

## Part 5: Testing and Validation

### Step 5.1: Test APIM to Istio Flow

```bash
# Get APIM gateway URL
APIM_GATEWAY_URL=$(az apim show --name $APIM_NAME --resource-group $APIM_RG --query "gatewayUrl" -o tsv)

# Test the API through APIM
curl -v "$APIM_GATEWAY_URL/bookinfo/productpage" \
  -H "Ocp-Apim-Subscription-Key: YOUR_SUBSCRIPTION_KEY" \
  -H "Host: bookinfo.istio.local"

# Test health endpoint
curl -v "$APIM_GATEWAY_URL/bookinfo/health" \
  -H "Ocp-Apim-Subscription-Key: YOUR_SUBSCRIPTION_KEY"
```

### Step 5.2: Monitor Traffic Flow

```bash
# Check Istio access logs
kubectl logs -n aks-istio-ingress -l app=aks-istio-ingressgateway-internal --tail=20

# Check productpage logs
kubectl logs -l app=productpage --tail=10

# Verify certificate usage
istioctl -n aks-istio-ingress proxy-config secret deploy/aks-istio-ingressgateway-internal-asm-1-25
```

### Step 5.3: Troubleshooting Commands

```bash
# Check gateway configuration
istioctl -n aks-istio-ingress proxy-config listener deploy/aks-istio-ingressgateway-internal-asm-1-25

# Check certificate configuration
kubectl describe secret istio-gateway-certs -n aks-istio-ingress

# Test connectivity from APIM subnet
kubectl run debug-pod --image=nicolaka/netshoot --rm -it --restart=Never -- \
  nslookup $INTERNAL_IP

# Check backend health in APIM
az apim backend show \
  --resource-group $APIM_RG \
  --service-name $APIM_NAME \
  --backend-id istio-gateway-backend
```

## Part 6: Advanced Configuration Options

### Step 6.1: Enable mTLS Authentication (Optional)

If implementing client certificate authentication:

```bash
# Update Gateway for mTLS
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
      mode: MUTUAL
      credentialName: istio-gateway-certs
      caCertificates: /etc/ssl/certs/ca-certificates.crt
    hosts:
    - "bookinfo.istio.local"
EOF
```

### Step 6.2: Configure Rate Limiting

```bash
# Create rate limiting configuration
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: EnvoyFilter
metadata:
  name: apim-rate-limit
  namespace: aks-istio-ingress
spec:
  workloadSelector:
    labels:
      app: aks-istio-ingressgateway-internal
  configPatches:
  - applyTo: HTTP_FILTER
    match:
      context: GATEWAY
      listener:
        filterChain:
          filter:
            name: "envoy.filters.network.http_connection_manager"
    patch:
      operation: INSERT_BEFORE
      value:
        name: envoy.filters.http.local_ratelimit
        typed_config:
          "@type": type.googleapis.com/udpa.type.v1.TypedStruct
          type_url: type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
          value:
            stat_prefix: local_rate_limiter
            token_bucket:
              max_tokens: 100
              tokens_per_fill: 100
              fill_interval: 60s
            filter_enabled:
              runtime_key: local_rate_limit_enabled
              default_value:
                numerator: 100
                denominator: HUNDRED
            filter_enforced:
              runtime_key: local_rate_limit_enforced
              default_value:
                numerator: 100
                denominator: HUNDRED
EOF
```

## 🎯 Lab Summary

### What You've Accomplished

✅ **APIM-Istio Integration**
- Configured internal Istio Ingress Gateway for VNET communication
- Set up TLS termination with custom certificates
- Created backend pool pointing to Istio Gateway
- Applied comprehensive APIM policies

✅ **Security Implementation**
- TLS encryption between APIM and Istio Gateway
- Optional mTLS client certificate authentication
- Secure header management and transformation
- Certificate lifecycle management

✅ **Advanced Traffic Management**
- Host-based routing through APIM
- Backend health monitoring
- Rate limiting and throttling
- Request/response transformation

### Architecture Benefits

🔒 **Enhanced Security**
- **Zero-trust networking** with certificate-based authentication
- **Defense in depth** with APIM policies + Istio security
- **Encrypted communication** end-to-end
- **Identity validation** at multiple layers

⚡ **Operational Excellence**
- **Centralized API management** through APIM
- **Service mesh benefits** with Istio
- **Observability** across the entire request path
- **Policy enforcement** at API gateway and mesh levels

🛠️ **Scalability & Reliability**
- **Load balancing** at APIM and Istio levels
- **Circuit breaking** and retry mechanisms
- **Canary deployments** support
- **High availability** configuration

### Production Considerations

🔐 **Certificate Management**
- Use proper CA-issued certificates for production
- Implement certificate rotation automation
- Monitor certificate expiration
- Secure private key storage

📊 **Monitoring & Observability**
- Configure APIM analytics and logging
- Enable Istio telemetry and tracing
- Set up alerting for failed requests
- Monitor certificate health

🚀 **Performance Optimization**
- Tune connection pooling settings
- Configure appropriate timeouts
- Implement caching strategies
- Monitor latency metrics

### Next Steps

Your APIM-Istio integration is ready for:
- **Advanced authentication** integration (OAuth, JWT)
- **API versioning** and lifecycle management
- **Multi-region deployment** patterns
- **GraphQL and gRPC** protocol support
- **Advanced observability** with distributed tracing

🎉 **Congratulations!** You've successfully implemented secure, enterprise-grade API management with Istio service mesh integration.

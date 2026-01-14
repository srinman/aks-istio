# End-to-End TLS with AKS Istio Add-on: Let's Encrypt Certificate and mTLS Re-encryption

## Overview

This guide demonstrates complete end-to-end TLS encryption in Istio service mesh:
1. **External TLS**: Client → Istio Gateway (using Let's Encrypt certificate)
2. **Internal mTLS**: Istio Gateway → Application Pods (using Istio-issued certificates with SPIFFE identities)

### Architecture

```
┌──────────┐  TLS (Let's Encrypt)   ┌─────────────────┐  mTLS (SPIFFE/SVID)  ┌──────────────┐
│  Client  │ ───────────────────► │ Istio Gateway   │ ──────────────────► │ Application  │
│          │  istiogatewaydemo.   │ (TLS Termination│  (Re-encryption)     │ Pod + Sidecar│
└──────────┘  srinman.com          │  + Re-encrypt)  │                      └──────────────┘
                                   └─────────────────┘
```

### Certificate Types

1. **Let's Encrypt Certificate**: Public CA certificate for external client trust
2. **SPIFFE SVID (X.509)**: Istio-issued certificates for workload identity and mTLS

**SPIFFE/SVID Reference**: [Istio Security - Identity](https://istio.io/latest/docs/concepts/security/#istio-identity)

> Istio uses X.509 certificates to carry SPIFFE Verifiable Identity Documents (SVIDs) in mutual TLS (mTLS). This is the recommended identity and credential format for production.

## Prerequisites

- AKS cluster with Istio add-on enabled
- Istio ingress gateway deployed
- Azure Key Vault created
- DNS zone access for istiogatewaydemo.srinman.com
- `kubectl`, `istioctl`, `az`, `certbot` CLI tools
- Docker registry access to srinmantest.azurecr.io

---

## Step 1: Create Let's Encrypt Certificate with Certbot

### Install Certbot (if needed)

```bash
# Install certbot
sudo apt-get update
sudo apt-get install -y certbot

# Verify installation
certbot --version
```

### Generate Certificate with DNS Challenge

```bash
# Set variables
export DOMAIN="istiogatewaydemo.srinman.com"
export EMAIL="smanivel@microsoft.com"

# Start certbot with manual DNS challenge
sudo certbot certonly \
  --manual \
  --preferred-challenges dns \
  --email $EMAIL \
  --agree-tos \
  --no-eff-email \
  -d $DOMAIN

# Certbot will display a DNS TXT record to create
# Example output:
# Please deploy a DNS TXT record under the name:
# _acme-challenge.istiogatewaydemo.srinman.com
# with the following value:
# abc123def456...

# DO NOT PRESS ENTER YET - First create the DNS record
```

### Create DNS TXT Record in Azure

```bash
# Set your DNS zone and resource group
export DNS_ZONE="srinman.com"
export DNS_RG="your-dns-resource-group"

# Get the challenge value from certbot output
export ACME_CHALLENGE="<paste-value-from-certbot>"

# Create TXT record
az network dns record-set txt add-record \
  --resource-group $DNS_RG \
  --zone-name $DNS_ZONE \
  --record-set-name "_acme-challenge.istiogatewaydemo" \
  --value "$ACME_CHALLENGE"

# Verify DNS propagation (wait 1-2 minutes)
nslookup -type=TXT _acme-challenge.istiogatewaydemo.srinman.com 8.8.8.8

# Once verified, go back to certbot and press ENTER
```

### Verify Certificate Files

```bash
# Certificates are stored in /etc/letsencrypt/live/
sudo ls -la /etc/letsencrypt/live/$DOMAIN/

# Files created:
# - cert.pem       (Server certificate)
# - chain.pem      (Intermediate certificates)
# - fullchain.pem  (cert.pem + chain.pem)
# - privkey.pem    (Private key)
```

---

## Step 2: Upload Certificate to Azure Key Vault

### Prepare Certificate for Key Vault

```bash
# Key Vault requires PFX format, convert the certificate
sudo openssl pkcs12 -export \
  -in /etc/letsencrypt/live/$DOMAIN/fullchain.pem \
  -inkey /etc/letsencrypt/live/$DOMAIN/privkey.pem \
  -out /tmp/istiogatewaydemo.pfx \
  -passout pass:

# Set Key Vault name
export KEYVAULT_NAME="srinmanakstlsdemo"
export CERT_NAME="istiogatewaydemo-tls"

# change perms for cert file 
sudo chmod 755 /tmp/istiogatewaydemo.pfx
# Upload certificate to Key Vault
az keyvault certificate import \
  --vault-name $KEYVAULT_NAME \
  --name $CERT_NAME \
  --file /tmp/istiogatewaydemo.pfx

# Verify certificate upload
az keyvault certificate show \
  --vault-name $KEYVAULT_NAME \
  --name $CERT_NAME \
  --query "{name:name, thumbprint:x509Thumbprint, expires:attributes.expires}"

# Clean up local PFX file
rm /tmp/istiogatewaydemo.pfx
```

---

## Step 3: Create Kubernetes Secret from Certificate

### Extract Certificate from Key Vault

```bash
# Download certificate as PEM
az keyvault certificate download \
  --vault-name $KEYVAULT_NAME \
  --name $CERT_NAME \
  --file /tmp/tls.crt \
  --encoding PEM

# Download private key (Key Vault stores it as base64-encoded PFX)
az keyvault secret show \
  --vault-name $KEYVAULT_NAME \
  --name $CERT_NAME \
  --query "value" -o tsv | \
  base64 -d | \
  openssl pkcs12 -nocerts -nodes -passin pass: -out /tmp/tls.key
```

### Create Kubernetes TLS Secret in Istio Gateway Namespace

```bash
# Get the Istio gateway namespace
export GATEWAY_NS="aks-istio-ingress"

# Create TLS secret
kubectl create secret tls istiogatewaydemo-credential \
  --cert=/tmp/tls.crt \
  --key=/tmp/tls.key \
  -n $GATEWAY_NS

# Verify secret creation
kubectl get secret istiogatewaydemo-credential -n $GATEWAY_NS

# Clean up local certificate files
rm /tmp/tls.crt /tmp/tls.key
```

---

## Step 4: Deploy Application with Istio Sidecar Injection

### Create Application Namespace with Istio Injection

```bash
# Create namespace
export APP_NS="istio-demo"

kubectl create namespace $APP_NS

# Enable Istio sidecar injection
kubectl label namespace $APP_NS istio.io/rev=asm-1-26

# Verify label
kubectl get namespace $APP_NS --show-labels
```

### Deploy Application with 3 Replicas

```bash
# Create deployment
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: istioapi1
  namespace: $APP_NS
  labels:
    app: istioapi1
    version: v1
spec:
  replicas: 3
  selector:
    matchLabels:
      app: istioapi1
      version: v1
  template:
    metadata:
      labels:
        app: istioapi1
        version: v1
    spec:
      serviceAccountName: istioapi1
      containers:
      - name: istioapi1
        image: srinmantest.azurecr.io/istioapi:v1
        ports:
        - containerPort: 5000
          name: http
        env:
        - name: APP_VERSION
          value: "v1"
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: istioapi1
  namespace: $APP_NS
---
apiVersion: v1
kind: Service
metadata:
  name: istioapi1
  namespace: $APP_NS
  labels:
    app: istioapi1
spec:
  selector:
    app: istioapi1
  ports:
  - name: http
    port: 80
    targetPort: 5000
    protocol: TCP
  type: ClusterIP
EOF
```

### Verify Deployment with Sidecar Injection

```bash
# Check pods (should show 2/2 - app + sidecar)
kubectl get pods -n $APP_NS

# Verify sidecar injection
kubectl get pods -n $APP_NS -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].name}{"\n"}{end}'

# Expected output:
# istioapi1-xxx   istioapi1 istio-proxy
```

---

## Step 5: Configure Istio Gateway for TLS Termination

### Create Gateway Resource

**Reference**: [Istio Gateway - HTTPS](https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/)

```bash
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: istiogatewaydemo-gateway
  namespace: $APP_NS
spec:
  selector:
    istio: aks-istio-ingressgateway-external
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: istiogatewaydemo-credential
    hosts:
    - "istiogatewaydemo.srinman.com"
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "istiogatewaydemo.srinman.com"
    tls:
      httpsRedirect: true
EOF
```

### Create VirtualService for Routing

```bash
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: istiogatewaydemo-vs
  namespace: $APP_NS
spec:
  hosts:
  - "istiogatewaydemo.srinman.com"
  gateways:
  - istiogatewaydemo-gateway
  http:
  - match:
    - uri:
        prefix: "/"
    route:
    - destination:
        host: istioapi1.${APP_NS}.svc.cluster.local
        port:
          number: 80
EOF
```

### Create DestinationRule for mTLS

**Reference**: [Istio Destination Rule - TLS Settings](https://istio.io/latest/docs/reference/config/networking/destination-rule/#ClientTLSSettings)

```bash
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: istioapi1-mtls
  namespace: $APP_NS
spec:
  host: istioapi1.${APP_NS}.svc.cluster.local
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL
EOF
```

```bash
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: nswidepeerauth
  namespace: $APP_NS
spec:
  mtls:
    mode: STRICT
EOF
```


### Verify Configuration

```bash
# Check Gateway
kubectl get gateway -n $APP_NS

# Check VirtualService
kubectl get virtualservice -n $APP_NS

# Check DestinationRule
kubectl get destinationrule -n $APP_NS

# Get Gateway external IP
export GATEWAY_IP=$(kubectl get svc -n aks-istio-ingress aks-istio-ingressgateway-external -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Gateway IP: $GATEWAY_IP"
```

---

## Step 6: Configure DNS for Gateway

### Create A Record in Azure DNS

```bash
# Create A record pointing to Gateway IP
az network dns record-set a add-record \
  --resource-group $DNS_RG \
  --zone-name $DNS_ZONE \
  --record-set-name "istiogatewaydemo" \
  --ipv4-address $GATEWAY_IP

# Verify DNS resolution
nslookup istiogatewaydemo.srinman.com
```

### Test External TLS Connection

```bash
# Wait for DNS propagation (1-2 minutes)
sleep 120

# Test HTTPS connection
curl -v https://istiogatewaydemo.srinman.com/

# Verify certificate
echo | openssl s_client -servername istiogatewaydemo.srinman.com \
  -connect istiogatewaydemo.srinman.com:443 2>/dev/null | \
  openssl x509 -noout -text | grep -E "(Subject:|Issuer:|Not Before|Not After)"
```

---

## Step 7: Inspect Gateway TLS Certificate (Let's Encrypt)

### View Gateway Secret Configuration

```bash
# Get Gateway pod
export GATEWAY_POD=$(kubectl get pods -n aks-istio-ingress -l istio=aks-istio-ingressgateway-external -o jsonpath='{.items[0].metadata.name}')

echo "Gateway Pod: $GATEWAY_POD"

# View all secrets in gateway
istioctl -n aks-istio-ingress proxy-config secret $GATEWAY_POD

# View specific certificate details
istioctl -n aks-istio-ingress proxy-config secret $GATEWAY_POD -o json | \
  jq '.dynamicActiveSecrets[] | select(.name | contains("istiogatewaydemo"))'
```

### Extract and Inspect Let's Encrypt Certificate

```bash
# Extract the Let's Encrypt certificate from gateway
istioctl -n aks-istio-ingress proxy-config secret $GATEWAY_POD -o json | \
  jq -r '.dynamicActiveSecrets[] | select(.name | contains("istiogatewaydemo")) | .secret.tlsCertificate.certificateChain.inlineBytes' | \
  base64 -d > /tmp/gateway_letsencrypt.pem

# View certificate details
openssl x509 -in /tmp/gateway_letsencrypt.pem -text -noout

# Extract key information
echo "=== Let's Encrypt Certificate Details ==="
echo "Issuer:"
openssl x509 -in /tmp/gateway_letsencrypt.pem -noout -issuer

echo -e "\nSubject:"
openssl x509 -in /tmp/gateway_letsencrypt.pem -noout -subject

echo -e "\nSubject Alternative Names:"
openssl x509 -in /tmp/gateway_letsencrypt.pem -noout -text | grep -A2 "Subject Alternative Name"

echo -e "\nValidity:"
openssl x509 -in /tmp/gateway_letsencrypt.pem -noout -dates

# Clean up
rm /tmp/gateway_letsencrypt.pem
```

---

## Step 8: Inspect Istio-Issued mTLS Certificates (SPIFFE SVIDs)

### Understanding SPIFFE in Istio

**Reference**: [Istio Security - PKI](https://istio.io/latest/docs/concepts/security/#pki)

> Istio securely provisions strong identities to every workload with X.509 certificates. Istio agents running alongside each Envoy proxy work together with istiod to automate key and certificate rotation at scale.

### Important: Istio Identity 

**How It Works**:
1. istio-agent generates a Certificate Signing Request (CSR)  
2. istiod signs the CSR and issues a certificate containing the **SPIFFE identity** based on the service account

**Example with 3 Replicas**:

istioapi1-pod1:
  - Private Key: unique-key-1 (generated by pod1's istio-agent)
  - Certificate Serial: ABC123
  - **SPIFFE ID: spiffe://cluster.local/ns/istio-demo/sa/istioapi1** 

istioapi1-pod2:
  - Private Key: unique-key-2 (generated by pod2's istio-agent)  
  - Certificate Serial: DEF456
  - **SPIFFE ID: spiffe://cluster.local/ns/istio-demo/sa/istioapi1** (SAME identity)

istioapi1-pod3:
  - Private Key: unique-key-3 (generated by pod3's istio-agent)
  - Certificate Serial: GHI789
  - **SPIFFE ID: spiffe://cluster.local/ns/istio-demo/sa/istioapi1** (SAME identity)

**Key Takeaway**: 
- ✅ **Identity is shared**: All pods with same service account have the same SPIFFE ID
- ✅ **Certificates are unique**: Each pod has a different certificate with different private key

**Reference**: [Istio Security - Identity](https://istio.io/latest/docs/concepts/security/#istio-identity)

### Inspect Gateway's Workload Identity Certificate

```bash
# View gateway's default workload certificate (SPIFFE SVID)
istioctl -n aks-istio-ingress proxy-config secret $GATEWAY_POD -o json | \
  jq -r '.dynamicActiveSecrets[] | select(.name=="default")'

# Extract gateway's SPIFFE certificate
istioctl -n aks-istio-ingress proxy-config secret $GATEWAY_POD -o json | \
  jq -r '.dynamicActiveSecrets[] | select(.name=="default") | .secret.tlsCertificate.certificateChain.inlineBytes' | \
  base64 -d > /tmp/gateway_spiffe.pem

openssl x509 -in /tmp/gateway_spiffe.pem -noout -text


# Clean up
rm /tmp/gateway_spiffe.pem
```

### Inspect Application Pod's SPIFFE Certificate

```bash
# Get application pod
export APP_POD=$(kubectl get pods -n $APP_NS -l app=istioapi1 -o jsonpath='{.items[0].metadata.name}')

echo "Application Pod: $APP_POD"

# View application's SPIFFE certificate
istioctl -n $APP_NS proxy-config secret $APP_POD -o json | \
  jq -r '.dynamicActiveSecrets[] | select(.name=="default")'

# Extract application's SPIFFE certificate
istioctl -n $APP_NS proxy-config secret $APP_POD -o json | \
  jq -r '.dynamicActiveSecrets[] | select(.name=="default") | .secret.tlsCertificate.certificateChain.inlineBytes' | \
  base64 -d > /tmp/app_spiffe.pem

openssl x509 -in /tmp/app_spiffe.pem -noout -text 


# Clean up
rm /tmp/app_spiffe.pem
```

---

## Step 9: Verify mTLS Configuration from Gateway to Application

### Understanding Hostname and SNI in Istio mTLS

**The Challenge**: When app1 calls app2, the request goes to `app2.istio-demo.svc.cluster.local`, but the certificate contains a SPIFFE identity, not a hostname.

**How Istio Solves This**:

Istio uses **SNI (Server Name Indication)** in the TLS handshake to route to the correct service, while using **SPIFFE identity** for authentication.

**Reference**: [Istio Traffic Management - Service Entries](https://istio.io/latest/docs/reference/config/networking/destination-rule/#ClientTLSSettings)

#### The Flow:

1. **Client Side (Gateway calling istioapi1)**:
   ```
   DNS Resolution: istioapi1.istio-demo.svc.cluster.local → Pod IPs
   TLS ClientHello with SNI: "outbound_.80_._.istioapi1.istio-demo.svc.cluster.local"
   Certificate presented: Contains SPIFFE ID (not hostname)
   ```

2. **Server Side (istioapi1 pod receiving call)**:
   ```
   Receives SNI: "outbound_.80_._.istioapi1.istio-demo.svc.cluster.local"
   Routes to correct listener based on SNI
   Validates client certificate using SPIFFE ID (not SNI)
   Presents own certificate with SPIFFE ID
   ```

3. **Authentication vs Routing**:
   ```
   SNI field:      Used for ROUTING (which service/port)
   SPIFFE ID:      Used for AUTHENTICATION (who is calling)
   Hostname:       NOT used for certificate validation in mTLS
   ```

#### Verify SNI Configuration:

```bash
# View SNI configuration in cluster definition
istioctl -n aks-istio-ingress proxy-config cluster $GATEWAY_POD \
  --fqdn "istioapi1.${APP_NS}.svc.cluster.local" -o json | \
  jq -r '.[].transportSocket.typedConfig.sni'

# Expected output:
# outbound_.80_._.istioapi1.istio-demo.svc.cluster.local
```

#### Key Points:

| Aspect | Traditional TLS | Istio mTLS |
|--------|----------------|------------|
| **Certificate Subject** | CN=hostname | Empty (identity in SAN) |
| **Certificate SAN** | DNS:hostname | URI:spiffe://... |
| **SNI Value** | hostname | Istio internal format |
| **Validation** | Hostname matching | SPIFFE ID matching |
| **Routing** | IP address | SNI + service discovery |

**Why This Matters**:
- Traditional TLS validates: "Is the certificate for the hostname I'm connecting to?"
- Istio mTLS validates: "Is the workload identity authorized to serve this request?"

This allows Istio to:
✅ Route to the correct service using SNI
✅ Authenticate workloads using SPIFFE identity
✅ Support multiple services on same IP (via SNI)
✅ Enable service-level authorization policies

### Check Cluster TLS Configuration

```bash
# View cluster configuration for backend service
istioctl -n aks-istio-ingress proxy-config cluster $GATEWAY_POD \
  --fqdn "istioapi1.${APP_NS}.svc.cluster.local" -o json

# Extract TLS configuration
istioctl -n aks-istio-ingress proxy-config cluster $GATEWAY_POD \
  --fqdn "istioapi1.${APP_NS}.svc.cluster.local" -o json | \
  jq '.[] | {
    name: .name,
    tlsContext: .transportSocket.typedConfig.commonTlsContext | {
      tlsCertificates: .tlsCertificateSdsSecretConfigs[].name,
      validationContext: .combinedValidationContext.validationContextSdsSecretConfig.name,
      alpnProtocols: .alpnProtocols
    }
  }'
```

### Verify SPIFFE Identity Matching

**Reference**: [Istio Peer Authentication](https://istio.io/latest/docs/reference/config/security/peer_authentication/)

```bash
# Check what SPIFFE identity the gateway expects from the application
istioctl -n aks-istio-ingress proxy-config cluster $GATEWAY_POD \
  --fqdn "istioapi1.${APP_NS}.svc.cluster.local" -o json | \
  jq -r '.[].transportSocket.typedConfig.commonTlsContext.combinedValidationContext.defaultValidationContext.matchSubjectAltNames[].exact'

# Expected output:
# spiffe://cluster.local/ns/istio-demo/sa/istioapi1
```

### View Endpoints with Health Status

```bash
# Check endpoints and their health
istioctl -n aks-istio-ingress proxy-config endpoints $GATEWAY_POD \
  --cluster "outbound|80||istioapi1.${APP_NS}.svc.cluster.local"

# This shows all backend pods and their health status
```

---

## Step 10: Verify End-to-End Encryption

### Test External HTTPS Access

```bash
# Test from external client
curl -v https://istiogatewaydemo.srinman.com/

# Verify TLS handshake details
curl -v --trace-ascii /dev/stdout https://istiogatewaydemo.srinman.com/ 2>&1 | grep -i "tls\|ssl\|certificate"

# Check certificate chain
echo | openssl s_client -servername istiogatewaydemo.srinman.com \
  -connect istiogatewaydemo.srinman.com:443 -showcerts 2>/dev/null
```

### Monitor mTLS Traffic

```bash
# View Envoy access logs from gateway
kubectl logs -n aks-istio-ingress $GATEWAY_POD --tail=50

# View application sidecar logs
kubectl logs -n $APP_NS $APP_POD -c istio-proxy --tail=50

# Check for mTLS indicators in logs (should show "MTLS" or "ISTIO_MUTUAL")
```

### Verify Traffic with Kiali (if installed)

```bash
# Port-forward Kiali (if available)
kubectl port-forward -n istio-system svc/kiali 20001:20001

# Open browser: http://localhost:20001
# Navigate to Graph > Select namespace: istio-demo
# Look for padlock icons indicating mTLS
```

---

## Step 11: Certificate Rotation and Monitoring

### Monitor Certificate Rotation

**Reference**: [Istio Certificate Management](https://istio.io/latest/docs/tasks/security/cert-management/plugin-ca-cert/)

```bash
# Watch certificate timestamps
watch -n 30 'istioctl -n aks-istio-ingress proxy-config secret $GATEWAY_POD -o json | \
  jq ".dynamicActiveSecrets[] | {name: .name, lastUpdated: .lastUpdated}"'

# Monitor certificate expiry
istioctl -n $APP_NS proxy-config secret $APP_POD -o json | \
  jq -r '.dynamicActiveSecrets[] | select(.name=="default") | .secret.tlsCertificate.certificateChain.inlineBytes' | \
  base64 -d | openssl x509 -noout -enddate
```

### Verify Automatic Certificate Renewal

```bash
# Istio automatically rotates certificates every 24 hours within running pods
# Check certificate issuance time (Not Before date)
istioctl -n $APP_NS proxy-config secret $APP_POD -o json | \
  jq -r '.dynamicActiveSecrets[] | select(.name=="default") | .secret.tlsCertificate.certificateChain.inlineBytes' | \
  base64 -d | openssl x509 -noout -dates

# Or check the lastUpdated timestamp from istioctl
istioctl -n $APP_NS proxy-config secret $APP_POD -o json | \
  jq '.dynamicActiveSecrets[] | select(.name=="default") | {name: .name, lastUpdated: .lastUpdated}'

# After 24 hours, run these commands again to see the new certificate dates
# Note: Pods are NOT recreated during certificate rotation - certificates rotate in-place
```

---

## Step 12: Troubleshooting

### Check Gateway Certificate Loading

```bash
# Verify gateway loaded the Let's Encrypt certificate
istioctl -n aks-istio-ingress proxy-config secret $GATEWAY_POD | \
  grep istiogatewaydemo

# Check for errors in gateway logs
kubectl logs -n aks-istio-ingress $GATEWAY_POD | grep -i "certificate\|tls\|error"
```

### Verify mTLS Enforcement

```bash
# Check PeerAuthentication policy
kubectl get peerauthentication -n $APP_NS

# View mesh-wide mTLS mode
kubectl get meshconfig -n istio-system -o yaml | grep -A5 mtls

# Test that plain HTTP is rejected
kubectl run test-client --rm -it --image=curlimages/curl --restart=Never -- \
  curl -v http://istioapi1.${APP_NS}.svc.cluster.local/

# Should fail or show connection errors without proper mTLS
```

### Debug Certificate Issues

```bash
# Check istiod logs for certificate issuance
kubectl logs -n aks-istio-system -l app=istiod --tail=100 | grep -i certificate

# Verify CA root certificate
istioctl -n $APP_NS proxy-config secret $APP_POD -o json | \
  jq '.dynamicActiveSecrets[] | select(.name=="ROOTCA")'

# Check certificate provisioning status
kubectl get events -n $APP_NS --sort-by='.lastTimestamp'
```

---

## Certificate Chain Summary

### External Client → Gateway (Let's Encrypt)

```
Client Certificate Store (OS/Browser)
  ↓ validates
Let's Encrypt Root CA (ISRG Root X1)
  ↓ signs
Let's Encrypt Intermediate CA (R3)
  ↓ signs
istiogatewaydemo.srinman.com (Server Certificate)
  ↓ presented by
Istio Gateway (TLS Termination)
```

### Gateway → Application (SPIFFE/SVID)

```
Istio CA (istiod)
  ↓ issues
Gateway SPIFFE SVID
  URI SAN: spiffe://cluster.local/ns/aks-istio-ingress/sa/aks-istio-ingressgateway-external
  ↓ authenticates to
Application SPIFFE SVID  
  URI SAN: spiffe://cluster.local/ns/istio-demo/sa/istioapi1
  ↓ validates using
Istio Root CA Certificate (ROOTCA)
```

---

## Key Insights

### Security Guarantees

✅ **External Trust**: Let's Encrypt provides browser-trusted certificates  
✅ **Zero Trust Internal**: Every service-to-service connection uses mTLS  
✅ **Identity-Based**: SPIFFE IDs tied to Kubernetes service accounts  
✅ **Automatic Rotation**: Istio certificates rotate every 24 hours  
✅ **No Application Changes**: Transparent to application code  

### SPIFFE/SVID Implementation

**SPIFFE ID Format in Istio**:
```
spiffe://cluster.local/ns/<namespace>/sa/<service-account>
```

**Reference**: [SPIFFE in Istio](https://istio.io/latest/docs/ops/best-practices/security/#use-namespaces-for-isolation)

> Istio uses SPIFFE to establish identity. Each workload has a SPIFFE ID that encodes its identity based on its service account and namespace.

### Certificate Lifecycle

| Certificate Type | Issuer | Lifetime | Rotation |
|-----------------|--------|----------|----------|
| Let's Encrypt | Let's Encrypt CA | 90 days | Manual renewal |
| SPIFFE SVID | Istio CA (istiod) | 24 hours | Automatic |
| Root CA | Istio CA | 10 years | Manual (rare) |

---

## Cleanup

```bash
# Delete application resources
kubectl delete namespace $APP_NS

# Delete gateway configuration
kubectl delete gateway istiogatewaydemo-gateway -n $APP_NS
kubectl delete virtualservice istiogatewaydemo-vs -n $APP_NS

# Delete Kubernetes secret
kubectl delete secret istiogatewaydemo-credential -n aks-istio-ingress

# Delete DNS records
az network dns record-set a delete \
  --resource-group $DNS_RG \
  --zone-name $DNS_ZONE \
  --name "istiogatewaydemo" \
  --yes

az network dns record-set txt delete \
  --resource-group $DNS_RG \
  --zone-name $DNS_ZONE \
  --name "_acme-challenge.istiogatewaydemo" \
  --yes

# Revoke Let's Encrypt certificate (optional)
sudo certbot revoke --cert-path /etc/letsencrypt/live/$DOMAIN/cert.pem
sudo certbot delete --cert-name $DOMAIN

# Delete from Key Vault
az keyvault certificate delete \
  --vault-name $KEYVAULT_NAME \
  --name $CERT_NAME
```

---

## References

1. [Istio Security Concepts](https://istio.io/latest/docs/concepts/security/)
2. [Istio Secure Ingress Gateway](https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/)
3. [SPIFFE Specification](https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE.md)
4. [Istio Certificate Management](https://istio.io/latest/docs/tasks/security/cert-management/)
5. [Istio mTLS Deep Dive](https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/)
6. [Let's Encrypt Documentation](https://letsencrypt.org/docs/)

---

**Status**: This configuration provides production-grade end-to-end encryption with public CA trust for external clients and zero-trust mTLS for internal service-to-service communication using Istio's SPIFFE-based identity framework.

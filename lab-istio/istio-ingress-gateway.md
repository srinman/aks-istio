# Lab: Istio Ingress Gateway - Traffic Management

## Overview
In this lab, you will learn how to:
- Enable and configure Istio Ingress Gateway on AKS
- Understand the relationship between Gateway and VirtualService resources
- Route external traffic into your service mesh
- Configure path-based routing and host-based routing
- Monitor and troubleshoot ingress traffic
- Test advanced routing scenarios

## Prerequisites
- Completed the Istio installation lab (without telemetry configuration)
- AKS cluster with Istio add-on enabled
- Sample applications deployed in the mesh
- Clean environment without pre-existing telemetry resources

> ⚠️ **Important**: This lab should be completed with a clean environment. If you previously configured telemetry resources in the installation lab, please remove them first to avoid conflicts.

## Understanding Istio Traffic Management Components

### 🌐 Gateway Resource
The **Gateway** resource configures a load balancer operating at the **edge of the mesh**. It:
- **Defines network entry points** into the service mesh
- **Specifies ports, protocols, and hostnames** that should be exposed
- **Acts as a configuration template** for the underlying Envoy proxy
- **Does NOT handle routing logic** - that's VirtualService's job

### 🚦 VirtualService Resource  
The **VirtualService** resource defines **routing rules** for traffic that matches a Gateway. It:
- **Specifies how requests are routed** to services within the mesh
- **Supports advanced routing** based on headers, URIs, methods, etc.
- **Enables traffic splitting, redirects, and rewrites**
- **Works with Gateways** to handle external traffic or standalone for internal traffic

### 🔗 How They Work Together
```
External Request → Gateway (defines entry point) → VirtualService (routing rules) → Backend Service
```

## 🏗️ Architecture Overview: Istio Ingress Traffic Flow

### Complete Traffic Flow Diagram

```
                                Internet
                                   │
                                   ▼
                          ┌─────────────────┐
                          │  External User  │
                          │  (Browser/curl) │
                          └─────────┬───────┘
                                    │ HTTP Request
                                    │ Host: istiosampleapp.srinman.com
                                    │ Path: /sampleapp
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           AKS Cluster                                      │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    aks-istio-ingress namespace                     │   │
│  │                                                                     │   │
│  │  ┌─────────────────────────────────────────────────────────────┐   │   │
│  │  │              External Load Balancer                        │   │   │
│  │  │           (Azure Load Balancer)                             │   │   │
│  │  │              IP: EXTERNAL_IP                                │   │   │
│  │  │              Port: 80                                       │   │   │
│  │  └─────────────────────┬───────────────────────────────────────┘   │   │
│  │                        │                                             │   │
│  │                        ▼                                             │   │
│  │  ┌─────────────────────────────────────────────────────────────┐   │   │
│  │  │         aks-istio-ingressgateway-external                   │   │   │
│  │  │                  (Envoy Proxy)                              │   │   │
│  │  │                                                             │   │   │
│  │  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐    │   │   │
│  │  │  │  Listener   │  │  Routes     │  │   Clusters      │    │   │   │
│  │  │  │  :80 HTTP   │  │  Gateway +  │  │  (Backend       │    │   │   │
│  │  │  │             │  │VirtualService│  │   Services)     │    │   │   │
│  │  │  └─────────────┘  └─────────────┘  └─────────────────┘    │   │   │
│  │  └─────────────────────┬───────────────────────────────────────┘   │   │
│  └────────────────────────┼─────────────────────────────────────────────┘   │
│                           │ Routed based on:                               │
│                           │ • Host header matching                         │
│                           │ • Path pattern matching                        │
│                           │ • URL rewriting rules                          │
│                           ▼                                                 │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      sampleapp namespace                           │   │
│  │                                                                     │   │
│  │  ┌─────────────────────────────────────────────────────────────┐   │   │
│  │  │                 istioapi Service                            │   │   │
│  │  │                (ClusterIP: 10.x.x.x)                       │   │   │
│  │  │                   Port: 80 → 5000                           │   │   │
│  │  └─────────────────────┬───────────────────────────────────────┘   │   │
│  │                        │ Load Balances to                           │   │
│  │                        ▼                                             │   │
│  │  ┌─────────────────────────────────────────────────────────────┐   │   │
│  │  │                   istioapi Pods                             │   │   │
│  │  │                                                             │   │   │
│  │  │ Pod 1:                        Pod 2:                       │   │   │
│  │  │ ┌─────────────┐              ┌─────────────┐               │   │   │
│  │  │ │istio-proxy  │              │istio-proxy  │               │   │   │
│  │  │ │(Envoy)      │              │(Envoy)      │               │   │   │
│  │  │ └──────┬──────┘              └──────┬──────┘               │   │   │
│  │  │        │                            │                     │   │   │
│  │  │ ┌──────▼──────┐              ┌──────▼──────┐               │   │   │
│  │  │ │   Flask     │              │   Flask     │               │   │   │
│  │  │ │ Application │              │ Application │               │   │   │
│  │  │ │ Port: 5000  │              │ Port: 5000  │               │   │   │
│  │  │ └─────────────┘              └─────────────┘               │   │   │
│  │  └─────────────────────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Gateway Resource Configuration Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Gateway Resource                                  │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ apiVersion: networking.istio.io/v1beta1                             │   │
│  │ kind: Gateway                                                       │   │
│  │ metadata:                                                           │   │
│  │   name: sampleapp-gateway-external                                  │   │
│  │ spec:                                                               │   │
│  │   selector:                                                         │   │
│  │     istio: aks-istio-ingressgateway-external  ←─┐                   │   │
│  │   servers:                                       │                   │   │
│  │   - port:                                        │                   │   │
│  │       number: 80                                 │                   │   │
│  │       protocol: HTTP                             │                   │   │
│  │     hosts:                                       │                   │   │
│  │     - istiosampleapp.srinman.com                 │                   │   │
│  └─────────────────────────────────────────────────┼───────────────────┘   │
└─────────────────────────────────────────────────────┼───────────────────────┘
                                                      │
                    Configures ▼                     │ Selects
                                                      │
┌─────────────────────────────────────────────────────┼───────────────────────┐
│                    Envoy Proxy Config               │                       │
│  ┌─────────────────────────────────────────────────┼───────────────────┐   │
│  │ Listeners:                                       │                   │   │
│  │ - Address: 0.0.0.0:80                           │                   │   │
│  │   Filter Chains:                                 │                   │   │
│  │   - HTTP Connection Manager                      │                   │   │
│  │     Virtual Hosts:                               │                   │   │
│  │     - Name: istiosampleapp.srinman.com          │                   │   │
│  │       Domains: ["istiosampleapp.srinman.com"]   │                   │   │
│  │       Routes: [configured by VirtualService]    │                   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### VirtualService Resource Routing Logic

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       VirtualService Resource                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ apiVersion: networking.istio.io/v1beta1                             │   │
│  │ kind: VirtualService                                                │   │
│  │ spec:                                                               │   │
│  │   hosts: ["istiosampleapp.srinman.com"]                            │   │
│  │   gateways: ["sampleapp-gateway-external"]                         │   │
│  │   http:                                                             │   │
│  │   - match:                                                          │   │
│  │     - uri:                                                          │   │
│  │         exact: /sampleapp                                           │   │
│  │     rewrite:                                                        │   │
│  │       uri: /authors                                                 │   │
│  │     route:                                                          │   │
│  │     - destination:                                                  │   │
│  │         host: istioapi                                              │   │
│  │         port: {number: 80}                                          │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                    Routing Decision ▼
                                    
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Request Processing                                  │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ 1. Incoming Request:                                                │   │
│  │    Host: istiosampleapp.srinman.com                                 │   │
│  │    Path: /sampleapp                                                 │   │
│  │                           │                                         │   │
│  │ 2. Gateway Match:         ▼                                         │   │
│  │    ✅ Host matches "istiosampleapp.srinman.com"                    │   │
│  │    ✅ Port 80 listener exists                                      │   │
│  │                           │                                         │   │
│  │ 3. VirtualService Match:  ▼                                         │   │
│  │    ✅ Host matches "istiosampleapp.srinman.com"                    │   │
│  │    ✅ Path exactly matches "/sampleapp"                            │   │
│  │                           │                                         │   │
│  │ 4. Request Transform:     ▼                                         │   │
│  │    Original: /sampleapp                                             │   │
│  │    Rewritten: /authors                                              │   │
│  │                           │                                         │   │
│  │ 5. Route to Backend:      ▼                                         │   │
│  │    Service: istioapi.sampleapp.svc.cluster.local:80                │   │
│  │    Final Path: /authors                                             │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 🎯 Key Learning Points

**1. Gateway Role:**
- Acts as the **entry point configuration** for external traffic
- Defines **which ports and hostnames** are accepted
- **Selects the Envoy proxy** that will handle the traffic
- **Does not define routing** - only opens the door

**2. VirtualService Role:**
- Defines **how requests are routed** once they pass the Gateway
- Supports **advanced matching** (headers, paths, methods)
- Enables **traffic manipulation** (rewriting, redirects, splitting)
- **Links to Gateway** via the `gateways` field

**3. Traffic Flow Steps:**
1. **External request** arrives at Azure Load Balancer
2. **Load Balancer** forwards to ingress gateway pod
3. **Envoy proxy** checks Gateway configuration for listener
4. **Gateway** accepts traffic based on host/port matching
5. **VirtualService** evaluates routing rules
6. **Request transformation** (rewriting, header manipulation)
7. **Backend routing** to appropriate service
8. **Service** load balances to pod endpoints
9. **Sidecar proxy** handles final delivery to application

---

## Part 1: Enable External Ingress Gateway

### Step 1.1: Set Environment Variables

Ensure your environment variables are set correctly:

```bash
export CLUSTER=aksistio4
export RESOURCE_GROUP=aksistio4rg
export LOCATION=eastus2
```

### Step 1.2: Enable External Ingress Gateway

Enable the external ingress gateway on your AKS cluster:

```bash
# Enable external ingress gateway
az aks mesh enable-ingress-gateway \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER \
  --ingress-gateway-type external

# Verify the configuration
az aks show --name $CLUSTER --resource-group $RESOURCE_GROUP --query 'serviceMeshProfile'
```

### Step 1.3: Verify Ingress Gateway Components

Check that the ingress gateway components are deployed:

```bash
# List all resources in the ingress namespace
kubectl get all -n aks-istio-ingress

# Check the ingress gateway service and external IP
kubectl get svc -n aks-istio-ingress

# Verify pods are running
kubectl get pods -n aks-istio-ingress
```

📝 **Expected Output**: You should see the `aks-istio-ingressgateway-external` service with an external IP address.  


## Part 2: Deploy and Configure Bookinfo Application

### Step 2.1: Prepare Default Namespace for Istio

Label the default namespace to enable automatic sidecar injection:

```bash
# Check available Istio revisions and their labels
kubectl get ns --show-labels | grep -i asm-

# Label the default namespace for sidecar injection (use your revision)
kubectl label namespace default istio.io/rev=asm-1-26

# Verify the label was applied
kubectl get ns default --show-labels

# bounce pods if required
kubectl delete pods --all -n default
```

### Step 2.2: Deploy Bookinfo Sample Application

Deploy the Istio sample Bookinfo application:

```bash
# Deploy the Bookinfo application
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.18/samples/bookinfo/platform/kube/bookinfo.yaml

# Check all resources were created
kubectl get all

# Verify pods have sidecars injected (should show 2/2 ready)
kubectl get pods

# Check services
kubectl get svc
```

### Step 2.3: Test Internal Connectivity

Test the application connectivity within the cluster:

```bash
# Port forward to test the application locally
kubectl port-forward service/productpage 9080:9080 &

# Test from another terminal (or use curl)
curl http://localhost:9080/productpage

# Stop port forwarding
pkill -f "kubectl port-forward"
```

📝 **Expected Result**: You should see the Bookinfo product page HTML response.

## Part 3: Configure Gateway and VirtualService for Bookinfo

### Step 3.1: Examine Gateway Configuration Before Creation

Let's first look at the current ingress gateway configuration:

```bash
# Check current listeners on the ingress gateway
kubectl delete gateway --all -A
istioctl -n aks-istio-ingress proxy-config listener deploy/aks-istio-ingressgateway-external-asm-1-26

# Check current routes (should be minimal)
kubectl delete virtualservice --all -A
istioctl -n aks-istio-ingress proxy-config route deploy/aks-istio-ingressgateway-external-asm-1-26
```

### Step 3.2: Create Gateway Resource

Create a Gateway to expose the Bookinfo application:

```bash
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: bookinfo-gateway-external
  namespace: default
spec:
  selector:
    istio: aks-istio-ingressgateway-external
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
EOF
```

**🔍 Gateway Configuration Explained:**
- `selector`: Matches the ingress gateway pods using their labels
- `servers.port`: Defines the port (80) and protocol (HTTP) to listen on
- `hosts: ["*"]`: Accepts requests for any hostname (wildcard)

### Step 3.3: Verify Gateway Impact on Ingress Configuration

Check how the Gateway affects the ingress gateway configuration:

```bash
# Check listeners again - should now show HTTP listener on port 80
istioctl -n aks-istio-ingress proxy-config listener deploy/aks-istio-ingressgateway-external-asm-1-26

# Check routes - blackhole route 
istioctl -n aks-istio-ingress proxy-config route deploy/aks-istio-ingressgateway-external-asm-1-26

# List gateways
kubectl get gateway

# Try to access the external IP (should get 404 - no routes configured yet)
EXTERNAL_IP=$(kubectl get svc aks-istio-ingressgateway-external -n aks-istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "External IP: $EXTERNAL_IP"
curl -v http://$EXTERNAL_IP/productpage
```

📝 **Expected Result**: 404 error because Gateway exists but no routing rules (VirtualService) are configured.

### Step 3.4: Create VirtualService Resource

Create routing rules for the Bookinfo application:

```bash
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: bookinfo-vs-external
  namespace: default
spec:
  hosts:
  - "*"
  gateways:
  - bookinfo-gateway-external
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
    route:
    - destination:
        host: productpage
        port:
          number: 9080
EOF
```

**🔍 VirtualService Configuration Explained:**
- `hosts: ["*"]`: Matches any hostname (same as Gateway)
- `gateways`: Links to our Gateway resource
- `http.match`: Defines URL patterns that should be routed
- `route.destination`: Specifies the target service and port

### Step 3.5: Verify Complete Configuration

Now check the complete ingress configuration:

```bash
# Check listeners (should show HTTP:80)
istioctl -n aks-istio-ingress proxy-config listener deploy/aks-istio-ingressgateway-external-asm-1-26

# Check routes (should now show our routing rules)
istioctl -n aks-istio-ingress proxy-config route deploy/aks-istio-ingressgateway-external-asm-1-26

# Get detailed route configuration
istioctl -n aks-istio-ingress proxy-config route deploy/aks-istio-ingressgateway-external-asm-1-26 -o json --name http.80

# List all gateways and virtual services
kubectl get gateway
kubectl get virtualservice
```

## Part 4: Test External Access to Bookinfo

### Step 4.1: Test Application Access

Test accessing the Bookinfo application from outside the cluster:

```bash
# Get the external IP
EXTERNAL_IP=$(kubectl get svc aks-istio-ingressgateway-external -n aks-istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "External IP: $EXTERNAL_IP"

# Test the productpage (should work)
curl -v http://$EXTERNAL_IP/productpage

# Test other paths
curl -v http://$EXTERNAL_IP/api/v1/products
curl -v http://$EXTERNAL_IP/login

# Test an invalid path (should get 404)
curl -v http://$EXTERNAL_IP/invalid-path
```

📝 **Expected Results:**
- `/productpage`: Returns HTML page
- `/api/v1/products`: Returns JSON product data  
- `/login`: Returns login page
- `/invalid-path`: Returns 404 error

### Step 4.2: Access from Browser

Open your browser and navigate to:
```
http://EXTERNAL_IP/productpage
```

🎯 **What to observe:**
- Page loads correctly with book information
- Reviews section shows different versions (round-robin)
- Static resources (CSS, JS) load properly




## Part 5: Monitor and Enable Access Logging

### Step 5.1: Check Initial Gateway Logs

Check the ingress gateway logs before enabling access logging:

```bash
# Get ingress gateway pods
kubectl get pods -n aks-istio-ingress

# Check logs (should show startup but no access logs yet)
kubectl logs -n aks-istio-ingress -l app=aks-istio-ingressgateway-external --tail=20
```

📝 **Expected Behavior**: You should see Envoy proxy initialization messages, but HTTP request logs won't appear until access logging is enabled.

**🔍 Typical Log Content at This Stage:**
```
2025-08-02T11:51:52.683447Z	warning	envoy main external/envoy/source/server/server.cc:863	Usage of the deprecated runtime key overload.global_downstream_max_connections
2025-08-02T11:51:52.709043Z	info	xdsproxy	connected to delta upstream XDS server: istiod-asm-1-25.aks-istio-system.svc:15012
2025-08-02T11:51:52.721235Z	info	cache	generated new workload certificate	resourceName=default latency=95.003242ms
2025-08-02T11:51:52.721290Z	info	cache	Root cert has changed, start rotating root cert
2025-08-02T11:51:53.441402Z	info	Readiness succeeded in 912.538262ms
2025-08-02T11:51:53.441776Z	info	Envoy proxy is ready
```

**📊 Log Types Explained:**
- **Warning messages**: Envoy configuration warnings (normal)
- **XDS connection**: Connection to Istio control plane (istiod)
- **Certificate management**: Workload identity and TLS certificate handling
- **Readiness**: Gateway pod startup completion
- **Missing**: HTTP access logs like `"GET /path HTTP/1.1" 200`

### Step 5.2: Enable Access Logging with Telemetry

Apply the modern Telemetry configuration to enable access logging:

```bash
kubectl apply -n aks-istio-system -f - <<EOF
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-logging-default
spec:
  # Global configuration - applies to entire mesh
  accessLogging:
  - providers:
    - name: envoy
EOF
```

**🔍 Configuration Notes:**
- Uses **global scope** (no selector) to apply to entire mesh
- Named `mesh-logging-default` for clarity
- Applied in `aks-istio-system` namespace where Istio control plane resides
- Uses the default `envoy` provider for stdout logging

### Step 5.3: Ensure Configuration Takes Effect

Restart the ingress gateway pods to ensure the telemetry configuration is picked up:

```bash
# Restart ingress gateway deployment to pick up new configuration
kubectl rollout restart deployment/aks-istio-ingressgateway-external-asm-1-25 -n aks-istio-ingress

# Wait for pods to be ready
kubectl rollout status deployment/aks-istio-ingressgateway-external-asm-1-25 -n aks-istio-ingress

# Verify pods are running
kubectl get pods -n aks-istio-ingress -l app=aks-istio-ingressgateway-external
```

### Step 5.4: Alternative Method - ConfigMap (Legacy)

> ⚠️ **Note**: This is the legacy method. Use Telemetry above for new deployments.

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio-shared-configmap-asm-1-25
  namespace: aks-istio-system
data:
  mesh: |-
    accessLogFile: /dev/stdout
    defaultConfig:
      holdApplicationUntilProxyStarts: true
EOF
```

### Step 5.5: Test and Verify Access Logging

Make some requests and check the logs:

```bash
# Make several requests
curl http://$EXTERNAL_IP/productpage
curl http://$EXTERNAL_IP/api/v1/products
curl http://$EXTERNAL_IP/invalid-path

# Check access logs (should now appear)
kubectl logs -n aks-istio-ingress -l app=aks-istio-ingressgateway-external --tail=10
```

**📊 Sample Access Log Format:**
```
[2024-08-02T11:03:55.177Z] "GET /productpage HTTP/1.1" 200 - via_upstream - "-" 0 5289 86 86 "10.224.0.5" "curl/7.68.0" "a50c8b8a-99ec-4a7e-bacc-9c8900c34f26" "EXTERNAL_IP" "10.244.1.7:9080" outbound|9080||productpage.default.svc.cluster.local 10.244.2.12:37132 10.244.2.12:80 10.224.0.5:39753 - -
```

**🔍 Log Fields Explained:**
- `[timestamp]`: Request timestamp
- `"GET /productpage HTTP/1.1"`: HTTP method, path, protocol
- `200`: HTTP response code
- `via_upstream`: Routing decision
- `0 5289 86 86`: Bytes received, sent, total time, upstream time
- `"curl/7.68.0"`: User agent
- `"EXTERNAL_IP"`: Host header
- `"10.244.1.7:9080"`: Upstream service IP:port

### 🔧 Troubleshooting Access Logging

If access logs don't appear immediately:

```bash
# 1. Check if telemetry resource exists
kubectl get telemetry -n aks-istio-system

# 2. Verify telemetry configuration
kubectl describe telemetry mesh-logging-default -n aks-istio-system

# 3. Check if pods picked up the configuration (may need restart)
kubectl rollout restart deployment/aks-istio-ingressgateway-external-asm-1-25 -n aks-istio-ingress

# 4. Wait for pods to be ready
kubectl get pods -n aks-istio-ingress -w

# 5. Make a test request and check logs immediately
curl http://$EXTERNAL_IP/productpage && kubectl logs -n aks-istio-ingress -l app=aks-istio-ingressgateway-external --tail=5
```

**💡 Common Issues:**
- **No logs appearing**: Pod restart usually resolves configuration pickup issues
- **Partial logs**: Global telemetry configuration works better than targeted selectors
- **Conflicting configurations**: Remove any previous telemetry resources before applying new ones

## Part 6: Advanced Routing with Custom Application

### Step 6.1: Create Host-Based Routing for Sample App

Create a Gateway with specific hostname for your sample application:

```bash
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: sampleapp-gateway-external
  namespace: sampleapp
spec:
  selector:
    istio: aks-istio-ingressgateway-external
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - istiosampleapp.srinman.com
EOF
```

**🔍 Key Difference**: This Gateway only accepts requests for `istiosampleapp.srinman.com`, not wildcard.

### Step 6.2: Create VirtualService with Path Rewriting

Create routing rules with URL rewriting:

```bash
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: sampleapp-vs-external
  namespace: sampleapp
spec:
  hosts:
  - istiosampleapp.srinman.com
  gateways:
  - sampleapp-gateway-external
  http:
  - match:
    - uri:
        exact: /sampleapp
    rewrite:
      uri: /authors
    route:
    - destination:
        host: istioapi
        port:
          number: 80
EOF
```

**🔍 Advanced Features Demonstrated:**
- **Host-based routing**: Only `istiosampleapp.srinman.com` is routed
- **Path rewriting**: `/sampleapp` is rewritten to `/authors` before forwarding
- **Cross-namespace routing**: Gateway in `sampleapp` namespace routes to `istioapi` service

### Step 6.3: Verify Multi-Gateway Configuration

Check that both configurations coexist:

```bash
# List all gateways across namespaces
kubectl get gateway -A

# List all virtual services
kubectl get virtualservice -A

# Check updated route configuration
istioctl -n aks-istio-ingress proxy-config route deploy/aks-istio-ingressgateway-external-asm-1-25

# Get detailed JSON route configuration
istioctl -n aks-istio-ingress proxy-config route deploy/aks-istio-ingressgateway-external-asm-1-25 -o json --name http.80
```

### Step 6.4: Test Host-Based Routing

Test both applications with different Host headers:

```bash
# Test Bookinfo (any hostname works)
curl -v http://$EXTERNAL_IP/productpage

# Test sample app (requires specific Host header)
curl -v http://$EXTERNAL_IP/sampleapp --header "Host: istiosampleapp.srinman.com"

# Test without proper Host header (should fail)
curl -v http://$EXTERNAL_IP/sampleapp

# Test with wrong hostname (should fail)
curl -v http://$EXTERNAL_IP/sampleapp --header "Host: wrong.hostname.com"
```

📝 **Expected Results:**
- Bookinfo: Works with any or no Host header
- Sample app: Only works with correct Host header
- URL rewriting: `/sampleapp` becomes `/authors` in the backend

## Part 7: Advanced Testing and Troubleshooting

### Step 7.1: Deep Dive into Traffic Analysis

Analyze how traffic flows through the gateway and understand the Envoy proxy configuration:

```bash
# Check all listeners
istioctl -n aks-istio-ingress proxy-config listener deploy/aks-istio-ingressgateway-external-asm-1-25

# Check clusters (backend services)
istioctl -n aks-istio-ingress proxy-config cluster deploy/aks-istio-ingressgateway-external-asm-1-25

# Check endpoints
istioctl -n aks-istio-ingress proxy-config endpoints deploy/aks-istio-ingressgateway-external-asm-1-25
```

#### 🎧 Understanding Listeners

**What Listeners Show:**
Listeners define **network entry points** where the Envoy proxy accepts incoming connections. Each listener represents a socket that binds to a specific address and port.

**Key Information in Listener Output:**
- **ADDRESS**: The IP address and port the proxy listens on (e.g., `0.0.0.0:80`)
- **FILTER CHAINS**: Processing pipeline for incoming requests
- **HTTP Connection Manager**: Handles HTTP protocol specifics
- **Virtual Hosts**: Domain-based routing configuration

**Why This Matters for the Lab:**
- Confirms your Gateway resource correctly created an HTTP listener on port 80
- Shows how different hostnames are configured (wildcard `*` vs specific domains)
- Validates that both Bookinfo and sample app gateways are properly configured
- Helps troubleshoot why traffic might not be accepted (no matching listener)

```bash
# Get detailed listener configuration
istioctl -n aks-istio-ingress proxy-config listener deploy/aks-istio-ingressgateway-external-asm-1-25 -o json
```

#### 🏗️ Understanding Clusters

**What Clusters Show:**
Clusters represent **backend service groups** that the proxy can route traffic to. They define how Envoy connects to upstream services.

**Key Information in Cluster Output:**
- **SERVICE FQDN**: Fully qualified domain names of backend services
- **PORT**: Target port on the backend service
- **SUBSET**: Service subset routing (for canary deployments)
- **ENDPOINTS**: Number of healthy backend instances

**Why This Matters for the Lab:**
- Verifies that your VirtualService correctly references backend services
- Shows service discovery working (Kubernetes services → Envoy clusters)
- Confirms cross-namespace routing (sampleapp Gateway → istioapi service)
- Helps debug service resolution issues

**Sample Output Analysis:**
```
SERVICE FQDN                              PORT     SUBSET     DIRECTION     TYPE             DESTINATION RULE
productpage.default.svc.cluster.local    9080     -          outbound      EDS              -
istioapi.sampleapp.svc.cluster.local     80       -          outbound      EDS              -
```

```bash
# Get detailed cluster configuration
istioctl -n aks-istio-ingress proxy-config cluster deploy/aks-istio-ingressgateway-external-asm-1-25 -o json
```

#### 🎯 Understanding Endpoints

**What Endpoints Show:**
Endpoints represent the **actual pod IP addresses** that serve traffic. They show the real destinations where requests will be sent.

**Key Information in Endpoint Output:**
- **ENDPOINT**: Pod IP addresses and ports
- **STATUS**: Health status (HEALTHY, UNHEALTHY, DEGRADED)
- **OUTLIER DETECTION**: Circuit breaker status
- **CLUSTER**: Which backend service group they belong to

**Why This Matters for the Lab:**
- Confirms that backend pods are healthy and reachable
- Shows load balancing targets (multiple pod IPs for the same service)
- Validates that sidecar injection worked (endpoints should be pod IPs, not service IPs)
- Helps troubleshoot 503 errors (no healthy endpoints available)

**Sample Output Analysis:**
```
ENDPOINT                         STATUS      OUTLIER CHECK     CLUSTER
10.244.1.7:9080                 HEALTHY     OK                outbound|9080||productpage.default.svc.cluster.local
10.244.2.5:9080                 HEALTHY     OK                outbound|9080||reviews.default.svc.cluster.local
10.244.1.8:5000                 HEALTHY     OK                outbound|80||istioapi.sampleapp.svc.cluster.local
```

**🔍 What This Tells You:**
- `10.244.1.7:9080`: Productpage pod ready to serve traffic
- `HEALTHY`: Pod passed health checks
- `outbound|9080||productpage...`: Traffic routing from ingress gateway to productpage service on port 9080

```bash
# Get detailed endpoint configuration
istioctl -n aks-istio-ingress proxy-config endpoints deploy/aks-istio-ingressgateway-external-asm-1-25 -o json
```

#### 🕵️ Traffic Flow Correlation

**Complete Request Journey Analysis:**
1. **Listener**: Accepts request on `0.0.0.0:80` → matches Gateway configuration
2. **Virtual Host**: Routes based on Host header → matches VirtualService rules  
3. **Cluster**: Selects backend service → targets specific service FQDN
4. **Endpoint**: Chooses healthy pod → actual destination IP:port
5. **Load Balancing**: Distributes across multiple endpoints

**Troubleshooting Commands:**
```bash
# Trace a specific request path
istioctl -n aks-istio-ingress proxy-config route deploy/aks-istio-ingressgateway-external-asm-1-25 --name http.80 -o json

# Check if specific service has endpoints
istioctl -n aks-istio-ingress proxy-config endpoints deploy/aks-istio-ingressgateway-external-asm-1-25 --cluster "outbound|9080||productpage.default.svc.cluster.local"

# Verify listener filter chains
istioctl -n aks-istio-ingress proxy-config listener deploy/aks-istio-ingressgateway-external-asm-1-25 --port 80 -o json
```

### Step 7.2: Performance and Health Testing

```bash
# Test gateway health
curl -v http://$EXTERNAL_IP/healthz

# Load testing (if Apache Bench is available)
ab -n 100 -c 10 http://$EXTERNAL_IP/productpage

# Monitor during load test
kubectl top pods -n aks-istio-ingress
kubectl logs -n aks-istio-ingress -l app=aks-istio-ingressgateway-external --follow
```

## 🎯 Lab Summary

### What You've Accomplished

✅ **Gateway Configuration**
- Enabled external ingress gateway on AKS
- Created Gateway resources defining network entry points
- Configured listeners for HTTP traffic on port 80
- Learned the difference between wildcard (`*`) and specific host matching

✅ **VirtualService Routing**
- Implemented path-based routing rules
- Configured host-based routing with specific domains
- Demonstrated URL rewriting capabilities
- Tested route precedence and conflict resolution

✅ **Advanced Traffic Management**
- Enabled comprehensive access logging
- Analyzed traffic flow through istioctl proxy inspection
- Tested cross-namespace service routing
- Monitored ingress gateway performance

✅ **Troubleshooting Skills**
- Used istioctl to inspect proxy configuration
- Analyzed access logs for debugging
- Tested various routing scenarios
- Understood how Gateway and VirtualService work together

### Key Concepts Mastered

🌐 **Gateway vs VirtualService**
- **Gateway**: Defines the entry point (ports, protocols, hosts)
- **VirtualService**: Defines the routing logic (where traffic goes)
- **Together**: They provide complete ingress traffic management

🚦 **Routing Capabilities**
- **Path-based**: Route based on URL paths (`/productpage`, `/api/*`)
- **Host-based**: Route based on Host header (`istiosampleapp.srinman.com`)
- **Rewriting**: Transform URLs before forwarding to backends
- **Cross-namespace**: Route from gateways to services in different namespaces

📊 **Observability**
- **Access logs**: Detailed HTTP request/response information
- **Proxy inspection**: Real-time configuration via istioctl
- **Traffic analysis**: Understanding request flow and routing decisions

### Production Considerations

🔒 **Security**
- Use specific hostnames instead of wildcards in production
- Implement TLS termination for HTTPS traffic
- Consider authentication and authorization policies

⚡ **Performance**
- Monitor ingress gateway resource usage
- Configure appropriate resource limits
- Use multiple ingress gateway replicas for high availability

🛠️ **Operations**
- Implement proper logging and monitoring
- Use canary deployments for gateway configuration changes
- Test routing rules thoroughly before production deployment

### Next Steps

Your ingress gateway is now ready for advanced scenarios:
- **TLS/HTTPS configuration** with certificates
- **Rate limiting and throttling** policies
- **Authentication integration** with external providers
- **Advanced load balancing** strategies
- **Multi-cluster ingress** configurations

🎉 **Congratulations!** You now understand how to effectively manage external traffic into your Istio service mesh using Gateway and VirtualService resources.  



# Lab: Istio Service Mesh Add-on on AKS

## Overview
In this lab, you will learn how to:
- Set up an AKS cluster with Istio add-on enabled
- Configure basic Istio components
- Deploy sample applications with sidecar injection
- Verify Istio installation and functionality

## Prerequisites

Before starting this lab, ensure you have the following tools installed and configured:

### Required Tools

| Tool | Purpose | Version Check |
|------|---------|---------------|
| Azure CLI | Manage Azure resources | `az --version` |
| kubectl | Kubernetes command line | `kubectl version --client` |
| istioctl | Istio command line | `istioctl version` |

### Verify Tool Installation

Run these commands to verify your tools are installed:

```bash
# Check Azure CLI version
az --version

# Check kubectl version
kubectl version --client

# Check istioctl version
istioctl version
```

## Part 1: Create AKS Cluster with Istio Add-on

### Step 1.1: Set Environment Variables

First, set up your environment variables. **Customize these values** for your lab:

```bash
export CLUSTER=aksistio4
export RESOURCE_GROUP=aksistio4rg
export LOCATION=eastus2
```

### Step 1.2: Check Available Istio Revisions

Before creating the cluster, check what Istio revisions are available in your region:

```bash
az aks mesh get-revisions --location ${LOCATION} -o table
```

### Step 1.3: Create Resource Group and AKS Cluster

Create the resource group and AKS cluster with Istio add-on enabled:

```bash
# Create resource group
az group create --name ${RESOURCE_GROUP} --location ${LOCATION}

# Create AKS cluster with Istio add-on
az aks create \
  --resource-group ${RESOURCE_GROUP} \
  --name ${CLUSTER} \
  --enable-asm \
  --generate-ssh-keys \
  --node-vm-size Standard_D4s_v5
```

> **Note**: The `--node-vm-size Standard_D4s_v5` ensures x86_64 architecture for compatibility with standard container images.

### Step 1.4: Verify Cluster Creation

Verify that your cluster was created successfully and Istio is enabled:

```bash
# Get cluster information
az aks show --resource-group ${RESOURCE_GROUP} --name ${CLUSTER}

# Check service mesh profile mode
az aks show --resource-group ${RESOURCE_GROUP} --name ${CLUSTER} --query 'serviceMeshProfile.mode'

# Get detailed service mesh profile
az aks show --name ${CLUSTER} --resource-group ${RESOURCE_GROUP} --query 'serviceMeshProfile'
```

### Step 1.5: Connect to Your Cluster

Get credentials and verify connectivity:

```bash
# Get cluster credentials
az aks get-credentials --resource-group ${RESOURCE_GROUP} --name ${CLUSTER}

# Verify namespaces (should see Istio system namespaces)
kubectl get ns

# Check Istio system components
kubectl get all -n aks-istio-system
kubectl get all -n aks-istio-ingress
kubectl get all -n aks-istio-egress
```

### Step 1.6: Get Istio Revision Number

Get the Istio revision number - **you'll need this for later steps**:

```bash
az aks show --resource-group ${RESOURCE_GROUP} --name ${CLUSTER} --query 'serviceMeshProfile.istio.revisions'
```

📝 **Important**: Note down the revision number (e.g., `asm-1-25`) - you'll use it in subsequent steps.  


## Part 2: Configure Istio Components

### Step 2.1: Explore Istio Custom Resource Definitions (CRDs)

Istio extends Kubernetes with custom resources. Let's explore what's available:

```bash
kubectl get crd | grep istio
```

You should see output similar to:
```
authorizationpolicies.security.istio.io                      2024-10-21T20:57:52Z
destinationrules.networking.istio.io                         2024-10-21T20:57:52Z
envoyfilters.networking.istio.io                             2024-10-21T20:57:52Z
gateways.networking.istio.io                                 2024-10-21T20:57:52Z
peerauthentications.security.istio.io                        2024-10-21T20:57:52Z
proxyconfigs.networking.istio.io                             2024-10-21T20:57:52Z
requestauthentications.security.istio.io                     2024-10-21T20:57:52Z
serviceentries.networking.istio.io                           2024-10-21T20:57:52Z
sidecars.networking.istio.io                                 2024-10-21T20:57:52Z
telemetries.telemetry.istio.io                               2024-10-21T20:57:52Z
virtualservices.networking.istio.io                          2024-10-21T20:57:52Z
wasmplugins.extensions.istio.io                              2024-10-21T20:57:52Z
workloadentries.networking.istio.io                          2024-10-21T20:57:52Z
workloadgroups.networking.istio.io                           2024-10-21T20:57:52Z
```

### Step 2.2: Examine Default Istio Configuration

A default ConfigMap is created when the Istio add-on is enabled. Check it using your revision number:

```bash
# Replace 'asm-1-25' with your actual revision number from Step 1.6
kubectl get cm istio-asm-1-25 -n aks-istio-system -o yaml
```

## Part 3: Deploy and Test Sample Applications

### Step 3.1: Build Container Images

First, navigate to the application directory and build your container images:

> **Important**: Change `srinmantest` to your own Azure Container Registry name.

```bash
cd istioapi

# Build all application images for x86_64 architecture
az acr build --registry srinmantest --image istioapi:v1 --file Dockerfilev1 --platform linux/amd64 .
az acr build --registry srinmantest --image istioapi:v2 --file Dockerfilev2 --platform linux/amd64 .
az acr build --registry srinmantest --image istioapi:v3 --file Dockerfilev3 --platform linux/amd64 .
az acr build --registry srinmantest --image appflaky:v1 --file Dockerfileflaky --platform linux/amd64 .
az acr build --registry srinmantest --image echocaller:v1 --file Dockerfileechocaller --platform linux/amd64 .
az acr build --registry srinmantest --image clientapp:v1 --file Dockerfileclientapp --platform linux/amd64 .
```

### Step 3.2: Attach ACR to AKS Cluster

Allow your AKS cluster to pull images from your Azure Container Registry:

```bash
# Replace the subscription and registry path with your actual values
az aks update \
  --resource-group ${RESOURCE_GROUP} \
  --name ${CLUSTER} \
  --attach-acr "/subscriptions/YOUR_SUBSCRIPTION_ID/resourceGroups/YOUR_RG/providers/Microsoft.ContainerRegistry/registries/YOUR_REGISTRY_NAME"
```

## 🏗️ Architecture Overview: Testing Setup

Before we proceed with creating namespaces and deploying applications, let's understand the architecture we're building:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           AKS Cluster (aksistio3)                          │
│                                                                             │
│  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐  │
│  │   aks-istio-system  │  │     sampleapp       │  │       testns        │  │
│  │    (Istio Control   │  │   (Application      │  │   (Testing Tools)   │  │
│  │      Plane)         │  │    Namespace)       │  │                     │  │
│  │                     │  │                     │  │                     │  │
│  │ ┌─────────────────┐ │  │ ┌─────────────────┐ │  │ ┌─────────────────┐ │  │
│  │ │   istiod        │ │  │ │   istioapi      │ │  │ │    netshoot     │ │  │
│  │ │  (Control       │ │  │ │    (Flask       │ │  │ │  (Test Client)  │ │  │
│  │ │   Plane)        │ │  │ │     API)        │ │  │ │                 │ │  │
│  │ └─────────────────┘ │  │ │                 │ │  │ └─────────────────┘ │  │
│  │                     │  │ │ ┌─────────────┐ │ │  │                     │  │
│  │ ┌─────────────────┐ │  │ │ │ Container:  │ │ │  │                     │  │
│  │ │   Telemetry     │ │  │ │ │  api1v1.py  │ │ │  │                     │  │
│  │ │   Config        │ │  │ │ │ Port: 5000  │ │ │  │                     │  │
│  │ └─────────────────┘ │  │ │ └─────────────┘ │ │  │                     │  │
│  └─────────────────────┘  │ └─────────────────┘ │  └─────────────────────┘  │
│                           │                     │                           │
│                           │ ┌─────────────────┐ │                           │
│                           │ │    Service:     │ │                           │
│                           │ │   istioapi      │ │                           │
│                           │ │  Port: 80->5000 │ │                           │
│                           │ └─────────────────┘ │                           │
│                           └─────────────────────┘                           │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 🔄 Sidecar Injection Process

**Phase 1: Before Sidecar Injection**
```
┌─────────────────────────────────────┐
│           sampleapp Pod             │
│  ┌─────────────────────────────────┐│
│  │        istioapi Container       ││  ← Only 1 container
│  │     ┌─────────────────────┐     ││
│  │     │    Flask App        │     ││
│  │     │   (api1v1.py)       │     ││
│  │     │   Port: 5000        │     ││
│  │     └─────────────────────┘     ││
│  └─────────────────────────────────┘│
└─────────────────────────────────────┘
```

**Phase 2: After Namespace Labeling & Pod Recreation**
```
┌─────────────────────────────────────┐
│           sampleapp Pod             │
│  ┌─────────────────────────────────┐│
│  │        istioapi Container       ││  ← Application container
│  │     ┌─────────────────────┐     ││
│  │     │    Flask App        │     ││
│  │     │   (api1v1.py)       │     ││
│  │     │   Port: 5000        │     ││
│  │     └─────────────────────┘     ││
│  └─────────────────────────────────┘│
│  ┌─────────────────────────────────┐│
│  │       istio-proxy Container     ││  ← Automatically injected!
│  │     ┌─────────────────────┐     ││
│  │     │   Envoy Proxy       │     ││
│  │     │ (Traffic Interception) │   ││
│  │     │   Metrics & Logs    │     ││
│  │     └─────────────────────┘     ││
│  └─────────────────────────────────┘│
└─────────────────────────────────────┘
```

### 📡 Traffic Flow After Sidecar Injection

```
netshoot Pod (testns)                    istioapi Pod (sampleapp)
┌──────────────┐                        ┌────────────────────────┐
│              │                        │  ┌──────────────────┐  │
│   curl       │────────────────────────┼─▶│  istio-proxy     │  │
│   request    │                        │  │  (Envoy)         │  │
│              │                        │  │  - Intercepts    │  │
└──────────────┘                        │  │  - Logs          │  │
                                        │  │  - Metrics       │  │
                                        │  └─────────┬────────┘  │
                                        │            │           │
                                        │  ┌─────────▼────────┐  │
                                        │  │  istioapi        │  │
                                        │  │  Flask App       │  │
                                        │  │  Port: 5000      │  │
                                        │  └──────────────────┘  │
                                        └────────────────────────┘
```

### 🎯 What We'll Verify

1. **Connectivity Test**: netshoot → istioapi service (through Kubernetes service discovery)
2. **Sidecar Injection**: Check pod shows `2/2` ready containers
3. **Proxy Logs**: Verify istio-proxy container captures traffic logs
4. **Service Mesh**: Confirm traffic flows through Envoy proxy

---

### Step 3.3: Create Application Namespaces

Create separate namespaces for your applications:

```bash
kubectl create ns sampleapp
kubectl create ns testns
```

### Step 3.4: Deploy Sample Application

Deploy the first version of your sample API application:

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: istioapi
  namespace: sampleapp
spec:
  replicas: 2
  selector:
    matchLabels:
      app: istioapi
  template:
    metadata:
      labels:
        app: istioapi
    spec:
      containers:
      - name: istioapi
        image: srinmantest.azurecr.io/istioapi:v1
        imagePullPolicy: Always
        ports:
        - containerPort: 5000
---
apiVersion: v1
kind: Service
metadata:
  name: istioapi
  namespace: sampleapp
spec:
  selector:
    app: istioapi
  ports:
  - protocol: TCP
    port: 80
    targetPort: 5000
EOF
```

### Step 3.5: Enable Istio Sidecar Injection

Enable automatic sidecar injection for your application namespace:

```bash
kubectl get pods -n sampleapp
# Replace 'asm-1-25' with your actual revision number from Step 1.6
kubectl label namespace sampleapp istio.io/rev=asm-1-25  
kubectl get pods -n sampleapp

```

### Step 3.6: Force Pod Recreation to Inject Sidecars

Restart the pods to trigger sidecar injection:

```bash
# Check current pods (should show 1/1 ready)
kubectl get pods -n sampleapp

# Delete pods to trigger recreation with sidecars
kubectl delete pods --all -n sampleapp

# Verify pods are recreated with sidecars (should show 2/2 ready)
kubectl get pods -n sampleapp
```

You should now see pods with `2/2` containers ready (application + istio-proxy).

## Part 4: Test and Observe Proxy Logging Behavior

### Step 4.1: Deploy Test Client

Deploy a test pod to make requests to your application:

```bash
# Deploy test pod
kubectl -n testns run netshoot --image=nicolaka/netshoot -- sh -c 'sleep 2000'

# Test connectivity to your application
kubectl -n testns exec -it netshoot -- curl istioapi.sampleapp.svc.cluster.local
```

You should see a JSON response from your API.

### Step 4.2: Check Proxy Logs **BEFORE** Telemetry Configuration

Let's examine what the istio-proxy logs contain by default:

```bash
# Check sidecar proxy logs (before telemetry configuration)
kubectl logs -l app=istioapi -c istio-proxy -n sampleapp --tail=10
```

📝 **Expected Behavior**: You'll see minimal logs - mostly startup messages and administrative logs, but **NO access logs** for your HTTP requests.

### Step 4.3: Make Additional Requests and Verify No Access Logs

Make a few more requests to confirm no access logging is happening:

```bash
# Make multiple requests
kubectl -n testns exec -it netshoot -- curl istioapi.sampleapp.svc.cluster.local/books
kubectl -n testns exec -it netshoot -- curl istioapi.sampleapp.svc.cluster.local/authors

# Check logs again - still no access logs
kubectl logs -l app=istioapi -c istio-proxy -n sampleapp --tail=10
```

> 🔍 **What you should observe**: Even though requests are successful, the istio-proxy logs don't show individual HTTP request details.

> 💡 **Note**: In production environments, you may want to enable access logging for better observability. This is covered in detail in the next lab (Istio Ingress Gateway) where you'll learn about different methods to configure access logging.

## Part 5: Summary and Next Steps

### 🎯 What You've Learned

In this lab, you successfully:

**✅ Infrastructure Setup:**
- Created an AKS cluster with Istio service mesh add-on enabled
- Verified all Istio components are properly installed and running
- Configured proper networking and security contexts

**✅ Application Deployment:**
- Deployed applications with automatic sidecar injection
- Verified that pods show `2/2` containers ready (application + istio-proxy)
- Tested internal service-to-service communication within the mesh

**✅ Service Mesh Verification:**
- Confirmed Istio proxy integration with your applications
- Validated that traffic flows through the service mesh
- Observed basic proxy logs and understood their structure

### 📊 Key Success Indicators

✅ **You should have achieved:**
- Pods showing `2/2` containers ready (application + istio-proxy)
- Working application accessible via Kubernetes service DNS
- Basic proxy logs showing Envoy startup and configuration
- Understanding of automatic sidecar injection behavior

### 🎉 Congratulations!

You have successfully:
- Created an AKS cluster with Istio add-on
- Deployed applications with automatic sidecar injection
- **Verified core service mesh functionality**
- **Prepared your cluster** for advanced Istio traffic management features

### 🚀 Next Steps

Your cluster is now ready for advanced Istio features like:
- **Traffic Management**: Ingress gateways and virtual services
- **Advanced Observability**: Access logging and distributed tracing
- **Security Policies**: mTLS and authorization policies  
- **Monitoring**: Integration with Prometheus and Grafana
- **Fault Injection**: Testing resilience patterns 



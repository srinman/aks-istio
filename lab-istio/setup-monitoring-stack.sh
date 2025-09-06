#!/bin/bash

# Setup Script for Azure Monitoring Stack with Istio
# This script helps set up the complete observability stack

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
CLUSTER_NAME="${CLUSTER_NAME:-aksistio4}"
RESOURCE_GROUP="${RESOURCE_GROUP:-aksistio4rg}"
LOCATION="${LOCATION:-eastus2}"
NAMESPACE="${NAMESPACE:-bookinfo}"

echo "🚀 Azure Monitoring Stack Setup for Istio"
echo "=========================================="
echo ""
log_info "Cluster: $CLUSTER_NAME"
log_info "Resource Group: $RESOURCE_GROUP"
log_info "Location: $LOCATION"
log_info "Target Namespace: $NAMESPACE"
echo ""

# Step 1: Enable preview features
log_info "Step 1: Enabling preview features..."

log_info "Registering AzureMonitorAppMonitoringPreview feature..."
az feature register --namespace "Microsoft.ContainerService" --name "AzureMonitorAppMonitoringPreview" 2>/dev/null || true

log_info "Checking feature registration status..."
FEATURE_STATUS=$(az feature show --namespace "Microsoft.ContainerService" --name "AzureMonitorAppMonitoringPreview" --query "properties.state" -o tsv 2>/dev/null || echo "NotRegistered")
log_info "Feature status: $FEATURE_STATUS"

if [[ "$FEATURE_STATUS" != "Registered" ]]; then
    log_warning "Feature registration may take up to 15 minutes. You can continue and check back later."
    log_info "Check status with: az feature show --namespace 'Microsoft.ContainerService' --name 'AzureMonitorAppMonitoringPreview'"
fi

# Step 2: Enable Application Insights on cluster
log_info "Step 2: Enabling Application Insights monitoring..."

APP_MONITORING_ENABLED=$(az aks show --name $CLUSTER_NAME --resource-group $RESOURCE_GROUP --query "azureMonitorProfile.appMonitoring.enabled" -o tsv 2>/dev/null || echo "false")

if [[ "$APP_MONITORING_ENABLED" != "true" ]]; then
    log_info "Enabling Azure Monitor App Monitoring on cluster..."
    az aks update \
      --resource-group $RESOURCE_GROUP \
      --name $CLUSTER_NAME \
      --enable-azure-monitor-app-monitoring
    log_success "Application Insights monitoring enabled"
else
    log_success "Application Insights monitoring already enabled"
fi

# Step 3: Verify Istio installation
log_info "Step 3: Verifying Istio installation..."

kubectl get namespace aks-istio-system > /dev/null 2>&1
if [ $? -eq 0 ]; then
    log_success "Istio control plane namespace found"
    
    ISTIO_PODS=$(kubectl get pods -n aks-istio-system --no-headers | wc -l)
    log_info "Istio control plane pods: $ISTIO_PODS"
    
    if [[ $ISTIO_PODS -gt 0 ]]; then
        log_success "Istio control plane is running"
    else
        log_error "Istio control plane pods not found"
        exit 1
    fi
else
    log_error "Istio is not installed. Please install Istio first."
    exit 1
fi

# Step 4: Create and configure namespace
log_info "Step 4: Setting up target namespace..."

# Create namespace if it doesn't exist
kubectl get namespace $NAMESPACE > /dev/null 2>&1
if [ $? -ne 0 ]; then
    log_info "Creating namespace: $NAMESPACE"
    kubectl create namespace $NAMESPACE
    log_success "Namespace created"
else
    log_success "Namespace already exists"
fi

# Enable Istio injection
ISTIO_INJECTION=$(kubectl get namespace $NAMESPACE -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null || echo "")
if [[ "$ISTIO_INJECTION" != "enabled" ]]; then
    log_info "Enabling Istio injection for namespace: $NAMESPACE"
    kubectl label namespace $NAMESPACE istio-injection=enabled --overwrite
    log_success "Istio injection enabled"
else
    log_success "Istio injection already enabled"
fi

# Step 5: Create Application Insights instrumentation
log_info "Step 5: Setting up Application Insights instrumentation..."

# Check if instrumentation already exists
kubectl get instrumentations default -n $NAMESPACE > /dev/null 2>&1
if [ $? -ne 0 ]; then
    log_info "You need to provide an Application Insights connection string."
    echo ""
    echo "To get your connection string:"
    echo "1. Go to Azure Portal > Application Insights"
    echo "2. Create or select an Application Insights resource"
    echo "3. Copy the 'Connection String' from the Overview page"
    echo ""
    
    # For demonstration, we'll create a placeholder
    read -p "Enter your Application Insights connection string (or press Enter to skip): " APP_INSIGHTS_CONNECTION_STRING
    
    if [[ -n "$APP_INSIGHTS_CONNECTION_STRING" ]]; then
        log_info "Creating Application Insights instrumentation..."
        kubectl apply -f - <<EOF
apiVersion: monitor.azure.com/v1
kind: Instrumentation
metadata:
  name: default
  namespace: $NAMESPACE
spec:
  settings:
    autoInstrumentationPlatforms: ["java", "nodejs", "python", "dotnet"]
  destination:
    applicationInsightsConnectionString: "$APP_INSIGHTS_CONNECTION_STRING"
EOF
        log_success "Application Insights instrumentation created"
    else
        log_warning "Skipping Application Insights instrumentation setup"
        log_info "You can create it later using the sample configuration in the lab guide"
    fi
else
    log_success "Application Insights instrumentation already exists"
fi

# Step 6: Deploy sample application (Bookinfo)
log_info "Step 6: Deploying sample application..."

read -p "Deploy Bookinfo sample application? (y/N): " DEPLOY_BOOKINFO
if [[ "$DEPLOY_BOOKINFO" =~ ^[Yy]$ ]]; then
    log_info "Deploying Bookinfo application..."
    
    # Deploy Bookinfo
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.23/samples/bookinfo/platform/kube/bookinfo.yaml -n $NAMESPACE
    
    # Wait for pods to be ready
    log_info "Waiting for pods to be ready..."
    kubectl wait --for=condition=ready pod --all -n $NAMESPACE --timeout=300s
    
    # Create Gateway and VirtualService
    log_info "Creating Istio Gateway and VirtualService..."
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: bookinfo-gateway
  namespace: $NAMESPACE
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
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: bookinfo
  namespace: $NAMESPACE
spec:
  hosts:
  - "*"
  gateways:
  - bookinfo-gateway
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
    
    log_success "Bookinfo application deployed"
    
    # Get external IP
    log_info "Getting external IP address..."
    EXTERNAL_IP=""
    for i in {1..30}; do
        EXTERNAL_IP=$(kubectl get svc aks-istio-ingressgateway-external -n aks-istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [[ -n "$EXTERNAL_IP" ]]; then
            break
        fi
        echo "Waiting for external IP... (attempt $i/30)"
        sleep 10
    done
    
    if [[ -n "$EXTERNAL_IP" ]]; then
        log_success "External IP: $EXTERNAL_IP"
        echo ""
        echo "🌐 Access your application:"
        echo "   http://$EXTERNAL_IP/productpage"
        echo ""
    else
        log_warning "External IP not assigned yet. Check later with:"
        echo "   kubectl get svc aks-istio-ingressgateway-external -n aks-istio-ingress"
    fi
else
    log_info "Skipping Bookinfo deployment"
fi

# Step 7: Install monitoring tools (optional)
log_info "Step 7: Installing additional monitoring tools..."

read -p "Install Kiali for service mesh visualization? (y/N): " INSTALL_KIALI
if [[ "$INSTALL_KIALI" =~ ^[Yy]$ ]]; then
    log_info "Installing Kiali..."
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.23/samples/addons/kiali.yaml
    log_success "Kiali installed"
    
    log_info "To access Kiali:"
    echo "   kubectl port-forward svc/kiali 20001:20001 -n istio-system"
    echo "   Then visit: http://localhost:20001"
fi

read -p "Install Jaeger for distributed tracing? (y/N): " INSTALL_JAEGER
if [[ "$INSTALL_JAEGER" =~ ^[Yy]$ ]]; then
    log_info "Installing Jaeger..."
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.23/samples/addons/jaeger.yaml
    log_success "Jaeger installed"
    
    log_info "To access Jaeger:"
    echo "   kubectl port-forward svc/jaeger 16686:16686 -n istio-system"
    echo "   Then visit: http://localhost:16686"
fi

# Step 8: Apply Prometheus rules (optional)
read -p "Apply Prometheus alerting rules? (y/N): " APPLY_RULES
if [[ "$APPLY_RULES" =~ ^[Yy]$ ]]; then
    if [[ -f "prometheus-rules.yaml" ]]; then
        log_info "Applying Prometheus rules..."
        kubectl apply -f prometheus-rules.yaml
        log_success "Prometheus rules applied"
    else
        log_warning "prometheus-rules.yaml not found in current directory"
    fi
fi

echo ""
echo "🎉 Setup completed successfully!"
echo ""
echo "📋 Next Steps:"
echo "1. Generate traffic to your application to see telemetry data"
echo "2. Check Application Insights in Azure Portal"
echo "3. View Container Insights for infrastructure monitoring"
echo "4. Use Grafana for metrics visualization"
echo "5. Run validation: ./validate-monitoring-stack.sh"
echo ""

if [[ -n "$EXTERNAL_IP" ]]; then
    echo "🔧 Generate test traffic:"
    echo "   for i in {1..100}; do curl -s http://$EXTERNAL_IP/productpage > /dev/null; echo \"Request \$i\"; sleep 1; done"
    echo ""
fi

echo "📚 Documentation:"
echo "   - Lab guide: istio-appinisghts-ci.md"
echo "   - Sample queries: sample-queries.kql"
echo "   - Validation script: validate-monitoring-stack.sh"
echo ""

log_success "Monitoring stack setup completed!"

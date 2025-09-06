#!/bin/bash

# Validation Script for Azure Monitoring Stack with Istio
# This script validates the complete observability setup including App Insights and Container Insights

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

echo "🔍 Azure Monitoring Stack Validation with Istio"
echo "=============================================="
echo ""

# Set default values
CLUSTER_NAME="${CLUSTER_NAME:-aksistio4}"
RESOURCE_GROUP="${RESOURCE_GROUP:-aksistio4rg}"
NAMESPACE="${NAMESPACE:-bookinfo}"

log_info "Using cluster: $CLUSTER_NAME in resource group: $RESOURCE_GROUP"
log_info "Target namespace: $NAMESPACE"
echo ""

# Check 1: Verify cluster and Istio
log_info "Checking AKS cluster and Istio installation..."
kubectl get nodes > /dev/null 2>&1
check_status $? "AKS cluster is accessible"

kubectl get pods -n aks-istio-system > /dev/null 2>&1
check_status $? "Istio control plane is running"

ISTIO_VERSION=$(kubectl get pods -n aks-istio-system -o jsonpath='{.items[0].metadata.labels.version}' 2>/dev/null || echo "unknown")
log_info "Istio version: $ISTIO_VERSION"

# Check 2: Application Insights auto-instrumentation
log_info "Checking Application Insights integration..."

# Check if the feature is enabled on cluster
APP_MONITORING_ENABLED=$(az aks show --name $CLUSTER_NAME --resource-group $RESOURCE_GROUP --query "azureMonitorProfile.appMonitoring.enabled" -o tsv 2>/dev/null || echo "false")
if [[ "$APP_MONITORING_ENABLED" == "true" ]]; then
    log_success "Azure Monitor App Monitoring is enabled on cluster"
else
    log_warning "Azure Monitor App Monitoring is not enabled on cluster"
fi

# Check for instrumentation resources
kubectl get instrumentations -n $NAMESPACE > /dev/null 2>&1
check_status $? "Instrumentation resources exist in $NAMESPACE"

if kubectl get instrumentations -n $NAMESPACE > /dev/null 2>&1; then
    INSTRUMENTATION_COUNT=$(kubectl get instrumentations -n $NAMESPACE --no-headers | wc -l)
    log_info "Found $INSTRUMENTATION_COUNT instrumentation resource(s)"
    
    # Check specific instrumentation details
    kubectl get instrumentations -n $NAMESPACE -o yaml | grep -q "applicationInsightsConnectionString"
    check_status $? "Application Insights connection string is configured"
fi

# Check 3: Container Insights
log_info "Checking Container Insights integration..."

# Check Azure Monitor metrics addon
METRICS_ENABLED=$(az aks show --name $CLUSTER_NAME --resource-group $RESOURCE_GROUP --query "azureMonitorProfile.metrics.enabled" -o tsv 2>/dev/null || echo "false")
if [[ "$METRICS_ENABLED" == "true" ]]; then
    log_success "Azure Monitor metrics is enabled"
else
    log_warning "Azure Monitor metrics is not enabled"
fi

# Check for ama-logs (Container Insights agent)
kubectl get pods -n kube-system | grep -q "ama-logs"
check_status $? "Container Insights agent (ama-logs) is running"

# Check for ama-metrics (Prometheus agent)
kubectl get pods -n kube-system | grep -q "ama-metrics"
check_status $? "Managed Prometheus agent (ama-metrics) is running"

# Check 4: Verify target application
log_info "Checking target application deployment..."
kubectl get namespace $NAMESPACE > /dev/null 2>&1
check_status $? "Target namespace '$NAMESPACE' exists"

if kubectl get namespace $NAMESPACE > /dev/null 2>&1; then
    # Check if namespace has Istio injection enabled
    ISTIO_INJECTION=$(kubectl get namespace $NAMESPACE -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null || echo "disabled")
    if [[ "$ISTIO_INJECTION" == "enabled" ]]; then
        log_success "Istio injection is enabled in $NAMESPACE"
    else
        log_warning "Istio injection is not enabled in $NAMESPACE"
    fi
    
    # Check for running pods
    POD_COUNT=$(kubectl get pods -n $NAMESPACE --no-headers 2>/dev/null | wc -l)
    if [[ $POD_COUNT -gt 0 ]]; then
        log_success "Found $POD_COUNT pod(s) in $NAMESPACE"
        
        # Check for Envoy sidecars
        SIDECAR_COUNT=$(kubectl get pods -n $NAMESPACE -o jsonpath='{range .items[*]}{.spec.containers[*].name}{"\n"}{end}' | grep -c "istio-proxy" || echo "0")
        log_info "Pods with Envoy sidecars: $SIDECAR_COUNT/$POD_COUNT"
    else
        log_warning "No pods found in $NAMESPACE"
    fi
fi

# Check 5: Verify data collection configuration
log_info "Checking data collection configuration..."

# Check Container Insights configuration
kubectl get configmap container-azm-ms-agentconfig -n kube-system > /dev/null 2>&1
check_status $? "Container Insights configuration exists"

# Check Prometheus configuration
kubectl get configmap ama-metrics-prometheus-config -n kube-system > /dev/null 2>&1
check_status $? "Managed Prometheus configuration exists"

# Check 6: Test connectivity and data flow
log_info "Testing data flow and connectivity..."

# Check if pods have OpenTelemetry auto-instrumentation
if kubectl get pods -n $NAMESPACE > /dev/null 2>&1; then
    INSTRUMENTED_PODS=$(kubectl get pods -n $NAMESPACE -o yaml | grep -c "opentelemetry" || echo "0")
    if [[ $INSTRUMENTED_PODS -gt 0 ]]; then
        log_success "Found $INSTRUMENTED_PODS pod(s) with OpenTelemetry instrumentation"
    else
        log_warning "No pods found with OpenTelemetry instrumentation"
    fi
fi

# Check for recent container logs
if kubectl get pods -n $NAMESPACE > /dev/null 2>&1; then
    FIRST_POD=$(kubectl get pods -n $NAMESPACE -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$FIRST_POD" ]]; then
        kubectl logs $FIRST_POD -n $NAMESPACE --tail=1 > /dev/null 2>&1
        check_status $? "Container logs are accessible for pod: $FIRST_POD"
    fi
fi

# Check 7: Azure resources validation
log_info "Validating Azure monitoring resources..."

# Check if Azure Monitor Workspace exists
AMW_EXISTS=$(az monitor account list --resource-group $RESOURCE_GROUP --query "length(@)" -o tsv 2>/dev/null || echo "0")
if [[ $AMW_EXISTS -gt 0 ]]; then
    log_success "Azure Monitor Workspace found"
    AMW_NAME=$(az monitor account list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
    log_info "Azure Monitor Workspace: $AMW_NAME"
else
    log_warning "No Azure Monitor Workspace found in $RESOURCE_GROUP"
fi

# Check if Managed Grafana exists
GRAFANA_EXISTS=$(az grafana list --resource-group $RESOURCE_GROUP --query "length(@)" -o tsv 2>/dev/null || echo "0")
if [[ $GRAFANA_EXISTS -gt 0 ]]; then
    log_success "Azure Managed Grafana found"
    GRAFANA_NAME=$(az grafana list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
    log_info "Grafana instance: $GRAFANA_NAME"
else
    log_warning "No Azure Managed Grafana found in $RESOURCE_GROUP"
fi

# Check if Log Analytics Workspace exists (for Container Insights)
LAW_EXISTS=$(az monitor log-analytics workspace list --resource-group $RESOURCE_GROUP --query "length(@)" -o tsv 2>/dev/null || echo "0")
if [[ $LAW_EXISTS -gt 0 ]]; then
    log_success "Log Analytics Workspace found"
    LAW_NAME=$(az monitor log-analytics workspace list --resource-group $RESOURCE_GROUP --query "[0].name" -o tsv)
    log_info "Log Analytics Workspace: $LAW_NAME"
else
    log_warning "No Log Analytics Workspace found in $RESOURCE_GROUP"
fi

# Check 8: Generate test traffic (if productpage exists)
log_info "Testing traffic generation..."
if kubectl get svc productpage -n $NAMESPACE > /dev/null 2>&1; then
    # Try to generate some internal traffic
    kubectl run test-traffic --image=curlimages/curl:latest --rm -i --restart=Never -n $NAMESPACE -- \
        curl -s http://productpage:9080/health > /dev/null 2>&1
    check_status $? "Internal traffic generation successful"
else
    log_info "Productpage service not found, skipping traffic test"
fi

echo ""
echo "📊 Configuration Summary"
echo "========================"

# Display configuration summary
echo ""
echo "🔧 Cluster Configuration:"
echo "   AKS Cluster: $CLUSTER_NAME"
echo "   Resource Group: $RESOURCE_GROUP"
echo "   Istio Version: $ISTIO_VERSION"
echo "   Target Namespace: $NAMESPACE"

echo ""
echo "📈 Monitoring Stack Status:"
echo "   App Monitoring: $APP_MONITORING_ENABLED"
echo "   Metrics Collection: $METRICS_ENABLED"
echo "   Istio Injection: $ISTIO_INJECTION"

if [[ -n "$AMW_NAME" ]]; then
    echo "   Azure Monitor Workspace: $AMW_NAME"
fi
if [[ -n "$GRAFANA_NAME" ]]; then
    echo "   Managed Grafana: $GRAFANA_NAME"
fi
if [[ -n "$LAW_NAME" ]]; then
    echo "   Log Analytics Workspace: $LAW_NAME"
fi

echo ""
echo "🔍 Validation Commands"
echo "======================"
echo ""
echo "Check Application Insights data:"
echo "  # Query traces in Application Insights"
echo "  requests | where timestamp > ago(1h) | take 10"
echo ""
echo "Check Container Insights logs:"
echo "  # Query container logs"
echo "  ContainerLog | where TimeGenerated > ago(1h) | take 10"
echo ""
echo "Check Prometheus metrics:"
echo "  # In Grafana, query Istio metrics"
echo "  istio_requests_total"
echo ""
echo "Manual verification steps:"
echo "  1. Visit Azure Portal > Application Insights > Application Map"
echo "  2. Visit Azure Portal > Container Insights > Containers"
echo "  3. Visit Grafana > Dashboards > Istio Service Mesh"
echo "  4. Visit Kiali UI for service mesh visualization"

echo ""
echo "✅ Validation completed!"
echo ""
echo "If you see any warnings above, refer to the troubleshooting section"
echo "in the lab guide: istio-appinisghts-ci.md"

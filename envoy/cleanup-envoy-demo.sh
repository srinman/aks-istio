#!/bin/bash

# Envoy Static Configuration Demo - Cleanup Script
# This script cleans up all resources created by the simple-envoy tutorial

set -e

echo "🧹 Starting cleanup of Envoy demo resources..."

# Function to check if resource exists before deletion
cleanup_resource() {
    local resource_type=$1
    local resource_name=$2
    local label_selector=$3
    
    if [[ -n "$label_selector" ]]; then
        echo "🔍 Checking for $resource_type with label: $label_selector"
        if kubectl get $resource_type -l "$label_selector" --no-headers 2>/dev/null | grep -q .; then
            echo "🗑️  Deleting $resource_type with label: $label_selector"
            kubectl delete $resource_type -l "$label_selector" --ignore-not-found=true
        else
            echo "✅ No $resource_type found with label: $label_selector"
        fi
    else
        echo "🔍 Checking for $resource_type: $resource_name"
        if kubectl get $resource_type "$resource_name" --no-headers 2>/dev/null | grep -q .; then
            echo "🗑️  Deleting $resource_type: $resource_name"
            kubectl delete $resource_type "$resource_name" --ignore-not-found=true
        else
            echo "✅ No $resource_type found: $resource_name"
        fi
    fi
}

# Clean up by specific resource names
echo ""
echo "📋 Cleaning up named resources..."
cleanup_resource "deployment" "envoy-proxy" ""
cleanup_resource "deployment" "echo-service" ""
cleanup_resource "service" "envoy-proxy" ""
cleanup_resource "service" "echo-service" ""
cleanup_resource "configmap" "envoy-config" ""

# Clean up by labels (safety net)
echo ""
echo "📋 Cleaning up labeled resources..."
cleanup_resource "deployments,services,configmaps" "" "app=envoy-proxy"
cleanup_resource "deployments,services,configmaps" "" "app=echo-service"

# Clean up any test pods that might be left behind
echo ""
echo "📋 Cleaning up test pods..."
kubectl delete pods -l run=test-pod --ignore-not-found=true
kubectl delete pods -l run=debug --ignore-not-found=true

# Wait for cleanup to complete
echo ""
echo "⏳ Waiting for cleanup to complete..."
sleep 5

# Verify cleanup
echo ""
echo "✅ Verifying cleanup..."
echo "Checking for remaining envoy-proxy resources:"
kubectl get all -l app=envoy-proxy 2>/dev/null || echo "  No envoy-proxy resources found"

echo "Checking for remaining echo-service resources:"
kubectl get all -l app=echo-service 2>/dev/null || echo "  No echo-service resources found"

echo "Checking for envoy-config configmap:"
kubectl get configmap envoy-config 2>/dev/null || echo "  No envoy-config configmap found"

echo ""
echo "🎉 Cleanup completed successfully!"
echo ""
echo "💡 Tips for starting fresh:"
echo "   • Run the tutorial commands from simple-envoy.md"
echo "   • Or use the Quick Start Commands section"
echo "   • Monitor deployment: kubectl get pods -w"
echo ""
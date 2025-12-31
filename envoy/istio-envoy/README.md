# Istio-Style Envoy Configuration - Direct Pod Endpoints

## Overview

This configuration demonstrates how **Istio programs Envoy sidecars** to route traffic directly to pod IPs, bypassing Kubernetes Services. This gives Envoy full control over load balancing, circuit breaking, retries, and traffic management.

## Key Differences from Basic Envoy Setup

| Aspect | Basic Envoy (../simple-envoy.md) | Istio-Style (this config) |
|--------|----------------------------------|---------------------------|
| **Service Discovery** | DNS → Kubernetes Service ClusterIP | Direct pod IPs |
| **Load Balancing** | Kubernetes Service (kube-proxy) | Envoy proxy |
| **Endpoint Updates** | Static (requires config reload) | Dynamic via xDS APIs (in real Istio) |
| **Cluster Type** | `STRICT_DNS` | `STATIC` (or `EDS` in real Istio) |
| **Target Port** | Service port (3000) | Pod container port (8080) |
| **Pod Awareness** | None - only sees ClusterIP | Full - sees all pod IPs |

## Architecture Comparison

### Basic Envoy Setup
```
Client → Envoy → Kubernetes Service (ClusterIP) → kube-proxy → Pods
                 (DNS: echo-service → 10.x.x.x)   (load balances)
```

### Istio-Style Setup
```
Client → Envoy → Pod 10.244.0.26:8080 ┐
                 Pod 10.244.1.26:8080 ├─ Round Robin (Envoy decides)
                 Pod 10.244.2.12:8080 ┘
         (No Kubernetes Service involved!)
```

## How Istio Actually Works

In a real Istio deployment:

1. **Istio Control Plane** (istiod) watches Kubernetes API for pods
2. **Pilot** component discovers all pod endpoints
3. **xDS APIs** dynamically push endpoint updates to Envoy sidecars
4. **Envoy** receives endpoint list via EDS (Endpoint Discovery Service)
5. **Traffic** goes directly pod-to-pod, bypassing Kubernetes Services

This static configuration simulates step 4-5 by hardcoding the pod IPs that Istio would normally discover dynamically.

## Current Pod IPs

The configuration is pre-populated with these pod IPs:

- `10.244.0.26` - echo-service-86d4747cb8-4kfrj
- `10.244.1.26` - echo-service-86d4747cb8-qncxk
- `10.244.2.12` - echo-service-86d4747cb8-rwsrg

**Note:** These IPs are from your current cluster. If you recreate pods, you'll need to update the ConfigMap.

## Deployment

### 1. Deploy the Istio-style Envoy Configuration

```bash
cd envoy/istio-envoy/

# Apply the configuration
kubectl apply -f envoy-config-direct-pods.yaml
kubectl apply -f envoy-deployment.yaml
```

### 2. Verify Deployment

```bash
# Check pods
kubectl get pods -l app=envoy-proxy-istio-style

# Check service
kubectl get svc envoy-proxy-istio-style

# Wait for external IP
kubectl get svc envoy-proxy-istio-style -w
```

### 3. Test Traffic Distribution

```bash
# Get the external IP
ENVOY_LB_IP=$(kubectl get svc envoy-proxy-istio-style -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Test load balancing - Envoy now controls which pod gets traffic
for i in {1..9}; do
  echo "Request $i:"
  curl -s http://$ENVOY_LB_IP:8080/ | jq -r '.os.hostname'
done
```

Expected output shows **exact round-robin distribution** across the 3 pods:
```
Request 1: echo-service-86d4747cb8-4kfrj
Request 2: echo-service-86d4747cb8-qncxk
Request 3: echo-service-86d4747cb8-rwsrg
Request 4: echo-service-86d4747cb8-4kfrj
Request 5: echo-service-86d4747cb8-qncxk
Request 6: echo-service-86d4747cb8-rwsrg
...
```

### 4. Verify Envoy Sees All 3 Pod Endpoints

```bash
# Check cluster status
kubectl exec deployment/envoy-proxy-istio-style -c envoy -- \
  curl -s localhost:9901/clusters | grep echo_cluster_direct_pods

# You should see 3 endpoints:
# echo_cluster_direct_pods::10.244.0.26:8080::health_flags::healthy
# echo_cluster_direct_pods::10.244.1.26:8080::health_flags::healthy
# echo_cluster_direct_pods::10.244.2.12:8080::health_flags::healthy
```

Compare this to the basic setup:
```bash
kubectl exec deployment/envoy-proxy -c envoy -- \
  curl -s localhost:9901/clusters | grep echo_cluster

# Only shows 1 endpoint (the ClusterIP):
# echo_cluster::echo-service:3000::health_flags::healthy
```

## Key Configuration Elements

### 1. Direct Pod Endpoints

```yaml
clusters:
- name: echo_cluster_direct_pods
  type: STATIC              # Static IPs (Istio uses EDS for dynamic updates)
  lb_policy: ROUND_ROBIN    # Envoy's load balancing in action
  load_assignment:
    endpoints:
    - lb_endpoints:
      - endpoint:
          address:
            socket_address:
              address: 10.244.0.26    # Direct pod IP
              port_value: 8080        # Pod container port
      - endpoint:
          address:
            socket_address:
              address: 10.244.1.26
              port_value: 8080
      - endpoint:
          address:
            socket_address:
              address: 10.244.2.12
              port_value: 8080
```

### 2. Health Checks on Each Pod

```yaml
health_checks:
- timeout: 1s
  interval: 10s
  unhealthy_threshold: 2
  healthy_threshold: 2
  http_health_check:
    path: "/"
    expected_statuses:
    - start: 200
      end: 299
```

Envoy actively health checks each pod. If a pod becomes unhealthy, Envoy automatically removes it from the load balancing pool.

## Testing Scenarios

### 1. Test Load Balancing Precision

```bash
# Run 30 requests and count distribution
for i in {1..30}; do
  curl -s http://$ENVOY_LB_IP:8080/ | jq -r '.os.hostname'
done | sort | uniq -c

# Expected: 10 requests to each pod (perfect distribution)
#  10 echo-service-86d4747cb8-4kfrj
#  10 echo-service-86d4747cb8-qncxk
#  10 echo-service-86d4747cb8-rwsrg
```

### 2. Test Pod Failure Handling

```bash
# Delete one pod
kubectl delete pod echo-service-86d4747cb8-4kfrj

# Immediately test traffic
for i in {1..6}; do
  curl -s http://$ENVOY_LB_IP:8080/ | jq -r '.os.hostname'
done

# Initially you may see connection errors or the deleted pod
# After health check kicks in, traffic only goes to healthy pods
```

### 3. Compare with Basic Envoy

Run both configurations side-by-side:

```bash
# Basic Envoy (via Kubernetes Service)
BASIC_IP=$(kubectl get svc envoy-proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Istio-style Envoy (direct pods)
ISTIO_IP=$(kubectl get svc envoy-proxy-istio-style -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Compare cluster endpoints
echo "=== Basic Envoy Clusters ==="
kubectl exec deployment/envoy-proxy -c envoy -- \
  curl -s localhost:9901/clusters | grep echo_cluster

echo -e "\n=== Istio-style Envoy Clusters ==="
kubectl exec deployment/envoy-proxy-istio-style -c envoy -- \
  curl -s localhost:9901/clusters | grep echo_cluster_direct_pods
```

## Updating Pod IPs

If pods are recreated with new IPs, update the ConfigMap:

```bash
# Get new pod IPs
kubectl get pods -l app=echo-service -o wide

# Edit the ConfigMap
kubectl edit configmap envoy-config-istio-style

# Or regenerate with script
cat > update-pod-ips.sh << 'EOF'
#!/bin/bash

# Get current pod IPs
IPS=($(kubectl get pods -l app=echo-service -o jsonpath='{.items[*].status.podIP}'))

echo "Current pod IPs: ${IPS[@]}"
echo "Update these in envoy-config-direct-pods.yaml"

# TODO: Automate ConfigMap update
EOF

chmod +x update-pod-ips.sh
./update-pod-ips.sh

# Restart Envoy to pick up changes
kubectl rollout restart deployment/envoy-proxy-istio-style
```

## Why This Matters for Istio

### Benefits of Direct Pod Routing

1. **Fine-grained Traffic Control**
   - Per-pod circuit breaking
   - Per-pod connection limits
   - Weighted load balancing (A/B testing)

2. **Advanced Routing**
   - Header-based routing to specific pod versions
   - Gradual rollouts (10% v2, 90% v1)
   - Canary deployments

3. **Better Observability**
   - Metrics per pod endpoint
   - Request tracing across pod hops
   - Detailed latency percentiles per pod

4. **Resiliency**
   - Independent health checking
   - Outlier detection (remove slow pods)
   - Automatic retry to different pods

### Real Istio vs This Static Config

| Feature | This Static Config | Real Istio |
|---------|-------------------|------------|
| Endpoint Discovery | Manual pod IPs | Automatic via Kubernetes API |
| Config Updates | Manual ConfigMap edit + restart | Automatic via xDS push |
| Multi-cluster | Not supported | Full support |
| mTLS | Not implemented | Automatic |
| Telemetry | Basic access logs | Full tracing, metrics |

## Cleanup

```bash
# Remove Istio-style deployment
kubectl delete -f envoy-deployment.yaml
kubectl delete -f envoy-config-direct-pods.yaml

# Or delete all resources
kubectl delete deployment envoy-proxy-istio-style
kubectl delete service envoy-proxy-istio-style
kubectl delete configmap envoy-config-istio-style
```

## Next Steps

1. **Learn about xDS APIs**: How Istio dynamically programs Envoy
2. **Explore EDS**: Endpoint Discovery Service for automatic updates
3. **Implement mTLS**: Secure pod-to-pod communication
4. **Add Circuit Breaking**: Protect against cascading failures
5. **Deploy Real Istio**: See the full service mesh in action

## References

- [Istio Architecture](../../lab-istio/istio-references.md)
- [Envoy xDS Protocol](https://www.envoyproxy.io/docs/envoy/latest/api-docs/xds_protocol)
- [Istio Traffic Management](../../lab-istio/istio-traffic-management.md)
- [Basic Envoy Setup](../simple-envoy.md)

---

**Key Takeaway:** This configuration demonstrates why Istio is powerful - by programming Envoy with direct pod endpoints, it gains complete control over traffic management, enabling sophisticated routing, resilience patterns, and observability that wouldn't be possible when routing through Kubernetes Services.

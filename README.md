# AKS Istio Service Mesh Labs

This repository contains comprehensive labs for learning and implementing Istio service mesh on Azure Kubernetes Service (AKS).

## Lab Overview

| Lab | Description |
|-----|-------------|
| [istio-install.md](./lab-istio/istio-install.md) | Set up an AKS cluster with Istio service mesh add-on, configure basic Istio components, deploy sample applications with sidecar injection, and verify installation functionality |
| [istio-ingress-gateway.md](./lab-istio/istio-ingress-gateway.md) | Configure Istio Ingress Gateway for external traffic management, implement Gateway and VirtualService resources, set up path-based and host-based routing scenarios |
| [istio-observability.md](./lab-istio/istio-observability.md) | Implement comprehensive observability with Azure Monitor, Prometheus metrics, centralized logging, service mesh visualization with Kiali, and distributed tracing with Jaeger |
| [istio-traffic-management.md](./lab-istio/istio-traffic-management.md) | Master advanced traffic management with sophisticated routing strategies, locality-aware load balancing, traffic policies (circuit breakers, retries, timeouts), and deployment patterns |
| [istio-security.md](./lab-istio/istio-security.md) | Implement Istio's security features including strong identity with X.509 certificates, mutual TLS, peer and request authentication, fine-grained authorization policies, and security auditing |
| [istio-references.md](./lab-istio/istio-references.md) | Comprehensive collection of reference links and additional resources for Istio, service mesh concepts, Kubernetes networking, Azure AKS, and distributed systems architecture |

## Learning Path

The labs are designed to be completed in sequence:

1. **Installation** - Foundation setup and basic concepts
2. **Ingress Gateway** - External traffic entry point configuration
3. **Observability** - Monitoring, logging, and visualization
4. **Traffic Management** - Advanced routing and deployment patterns
5. **Security** - Authentication, authorization, and encryption

## Prerequisites

- Azure subscription with permissions to create AKS clusters
- Azure CLI installed and configured
- kubectl command-line tool
- Basic understanding of Kubernetes concepts
- Familiarity with containerized applications

## Repository Structure

```
├── istioapi/           # Sample applications for testing
├── lab-istio/          # Istio lab guides and configurations
└── LICENSE             # Apache 2.0 License
```

## Getting Started

1. Start with the [Istio Installation Lab](./lab-istio/istio-install.md)
2. Follow the labs in the recommended sequence
3. Use the sample applications in the `istioapi/` directory for testing

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

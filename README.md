# Local Kubernetes Development on Windows with Docker Desktop

This guide covers setting up a local Kubernetes development environment on Windows using Docker Desktop, with Istio service mesh for production parity.

> **Add to README.md:**
> ```markdown
> ## Local Development (Windows)
> See [README.md](README.md) for Windows Docker Desktop Kubernetes setup.
> ```

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Running the Bootstrap](#running-the-bootstrap)
3. [Tilt Usage](#tilt-usage)
4. [DNS and Hostnames](#dns-and-hostnames)
5. [Gateway Usage](#gateway-usage)
6. [Egress Control](#egress-control)
7. [Canary and Blue-Green Deployments](#canary-and-blue-green-deployments)
8. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Required Software

| Tool | Version | Installation |
|------|---------|-------------|
| Docker Desktop | Latest | [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/) |
| kubectl | v1.34+ | Included with Docker Desktop, or `choco install kubernetes-cli` |
| Helm | v3.x | `choco install kubernetes-helm` or [helm.sh/docs/intro/install](https://helm.sh/docs/intro/install/) |
| Tilt | Latest | `choco install tilt` or [docs.tilt.dev/install](https://docs.tilt.dev/install.html) |

### Optional Tools

| Tool | Purpose | Installation |
|------|---------|-------------|
| Git Bash | Unix-like shell | Included with Git for Windows |
| istioctl | Istio CLI utilities | [istio.io/latest/docs/setup/getting-started](https://istio.io/latest/docs/setup/getting-started/) |

### Enable Docker Desktop Kubernetes

1. Open Docker Desktop
2. Go to **Settings** → **Kubernetes**
3. Check **Enable Kubernetes**
4. Click **Apply & Restart**
5. Wait for the Kubernetes indicator to turn green

Verify setup:
```powershell
kubectl config use-context docker-desktop
kubectl cluster-info
kubectl config current-context  # Should show: docker-desktop
```

---

## Running the Bootstrap

The bootstrap script is idempotent and safe to run multiple times.

### Basic Usage (Sidecar Mode)

```powershell
# Navigate to repo root
cd path\to\your\repo

# Run with defaults (sidecar mode, no gateway)
.\scripts\bootstrap-docker-desktop-k8s.ps1
```

### All Parameters

```powershell
.\scripts\bootstrap-docker-desktop-k8s.ps1 `
    -DataplaneMode sidecar `    # Options: sidecar (default), ambient, none
    -InstallIngressGateway `    # Enable Istio ingress gateway
    -InstallDashboard `         # Install Kubernetes Dashboard
    -AllowInternetEgress `      # Allow pods to reach internet
    -Force                      # Bypass kubecontext safety check

# One Liner for above
.\scripts\bootstrap-docker-desktop-k8s.ps1 -DataplaneMode sidecar -InstallIngressGateway -InstallDashboard -AllowInternetEgress -Force
```

### Common Scenarios

**Minimal Dev Setup (fastest startup):**
```powershell
.\scripts\bootstrap-docker-desktop-k8s.ps1 -DataplaneMode none
```

**Standard Dev with Sidecar Injection:**
```powershell
.\scripts\bootstrap-docker-desktop-k8s.ps1
```

**Production-Like with Gateway:**
```powershell
.\scripts\bootstrap-docker-desktop-k8s.ps1 -InstallIngressGateway
```

**Ambient Mode (Sidecar-less):**
```powershell
.\scripts\bootstrap-docker-desktop-k8s.ps1 -DataplaneMode ambient -InstallIngressGateway
```

**Full Setup with Dashboard and Egress:**
```powershell
.\scripts\bootstrap-docker-desktop-k8s.ps1 `
    -DataplaneMode sidecar `
    -InstallIngressGateway `
    -InstallDashboard `
    -AllowInternetEgress
```

### What the Bootstrap Does

1. **Validates environment**: Checks kubectl, helm, kubecontext, StorageClass
2. **Installs Gateway API CRDs**: Required for Istio gateway resources
3. **Installs Istio 1.28.2**: Base, Istiod, optionally ztunnel and gateway
4. **Creates platform-dev namespace**: With appropriate mesh enrollment labels
5. **Applies Zero Trust policies**:
   - PeerAuthentication: mTLS STRICT
   - AuthorizationPolicy: default-deny + allow intra-namespace
   - NetworkPolicy: default-deny + allow DNS
6. **Optional components**: Ingress gateway, Kubernetes Dashboard

---

## Tilt Usage

### Starting Tilt in Kubernetes Mode

```powershell
# Standard mode with Istio sidecar injection
tilt up -- --mode=k8s --k8s-istio-enabled=true

# With gateway management (requires -InstallIngressGateway)
tilt up -- --mode=k8s --k8s-istio-enabled=true --k8s-manage-gateway=true

# Override gateway name if needed
tilt up -- --mode=k8s --k8s-istio-enabled=true --k8s-manage-gateway=true --k8s-gateway-name=platform-gateway
```

### Important Tilt Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--mode` | - | Deployment mode: `k8s` for Kubernetes |
| `--k8s-istio-enabled` | false | Enable Istio-aware deployments |
| `--k8s-manage-gateway` | false | Apply k8s/gateway.yaml via Tilt |
| `--k8s-gateway-name` | platform-gateway | Gateway resource name |

### Tilt UI

Once running, access Tilt dashboard at: **http://localhost:10350**

### Stopping Tilt

Press `Ctrl+C` or run `tilt down` to clean up resources.

---

## DNS and Hostnames

### Recommended: localtest.me

Use `localtest.me` for local development. This domain resolves to `127.0.0.1` without any `/etc/hosts` modification.

**Examples:**
```
http://platform.localtest.me
http://api.platform.localtest.me
http://admin.platform.localtest.me:8080
```

Any subdomain works: `*.localtest.me` → `127.0.0.1`

### Using with Ingress Gateway

When the ingress gateway is installed, it exposes a LoadBalancer service on localhost (Docker Desktop handles this automatically).

```powershell
# Check gateway service
kubectl get svc istio-ingressgateway -n istio-system

# Example output:
# NAME                   TYPE           EXTERNAL-IP   PORT(S)
# istio-ingressgateway   LoadBalancer   localhost     15021,80,443
```

Access your services via:
- `http://platform.localtest.me` (port 80)
- `https://platform.localtest.me` (port 443, requires TLS config)

### Alternative: Direct Port Forwarding

Without a gateway, use `kubectl port-forward` or Tilt's `port_forward`:

```powershell
# Manual port-forward
kubectl port-forward svc/my-service -n platform-dev 8080:80

# Access at http://localhost:8080
```

---

## Gateway Usage

### Simple Dev: No Gateway

For rapid iteration, skip the gateway entirely:

```powershell
# Bootstrap without gateway
.\scripts\bootstrap-docker-desktop-k8s.ps1

# Use Tilt port_forwards or kubectl port-forward
tilt up -- --mode=k8s --k8s-istio-enabled=true
```

Access services via Tilt's port forwards shown in Tilt UI.

### Production-Like: With Ingress Gateway

For testing gateway routing, TLS termination, or traffic management:

```powershell
# Bootstrap with gateway
.\scripts\bootstrap-docker-desktop-k8s.ps1 -InstallIngressGateway

# Run Tilt with gateway management
tilt up -- --mode=k8s --k8s-istio-enabled=true --k8s-manage-gateway=true
```

This applies `k8s/gateway.yaml` which defines Gateway and HTTPRoute resources.

### Gateway Configuration for localtest.me

If your `k8s/gateway.yaml` uses `platform.local` hostnames, create a dev-friendly variant:

**Option A: Wildcard Host**
```yaml
# In gateway.yaml or a local override
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: platform-routes
  namespace: platform-dev
spec:
  parentRefs:
    - name: platform-gateway
      namespace: istio-system
  hostnames:
    - "*.localtest.me"      # Wildcard for dev
    - "platform.localtest.me"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: api-service
          port: 80
    - backendRefs:
        - name: frontend-service
          port: 80
```

**Option B: Tiltfile Override**

In your Tiltfile, conditionally modify hostnames for local development.

---

## Egress Control

### Default: Locked Down

By default, pods in `platform-dev` can only reach:
- Other pods in `platform-dev` (intra-namespace)
- Kubernetes DNS (`kube-dns` in `kube-system`)

All other egress (including internet) is blocked by NetworkPolicy.

### Enabling Internet Egress

For development scenarios requiring external API access:

```powershell
# At bootstrap time
.\scripts\bootstrap-docker-desktop-k8s.ps1 -AllowInternetEgress

# Or apply manually
kubectl apply -f k8s/dev/networkpolicies/np-allow-internet-egress.yaml
```

### Fine-Grained Egress with Istio ServiceEntry

For production-like control over external services, use Istio ServiceEntry instead of blanket NetworkPolicy rules.

**Example: Allow access to external API**
```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: external-api
  namespace: platform-dev
spec:
  hosts:
    - api.example.com
  ports:
    - number: 443
      name: https
      protocol: HTTPS
  location: MESH_EXTERNAL
  resolution: DNS
```

**When to use ServiceEntry:**
- You need to track metrics for external calls
- You want to apply retry/timeout policies to external services
- You need to enforce mTLS to external endpoints
- Production uses ServiceEntry and you want parity

**When NetworkPolicy egress is enough:**
- Simple development scenarios
- You don't need Istio observability for external calls
- Faster iteration without additional configuration

---

## Canary and Blue-Green Deployments

Istio enables sophisticated traffic management for canary releases and blue-green deployments.

### Prerequisites

**Sidecar Mode:** Works out of the box with sidecar proxies.

**Ambient Mode:** Requires waypoint proxy for L7 traffic management.

```powershell
# Verify waypoint is running (ambient mode only)
kubectl get gateway -n platform-dev
kubectl get pods -n platform-dev -l gateway.networking.k8s.io/gateway-name=waypoint
```

### Example: Canary Deployment

**1. Deploy both versions with version labels:**
```yaml
# v1 deployment (stable)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app-v1
  namespace: platform-dev
spec:
  selector:
    matchLabels:
      app: my-app
      version: v1
  template:
    metadata:
      labels:
        app: my-app
        version: v1
    spec:
      containers:
        - name: app
          image: my-app:1.0.0

---
# v2 deployment (canary)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app-v2
  namespace: platform-dev
spec:
  selector:
    matchLabels:
      app: my-app
      version: v2
  template:
    metadata:
      labels:
        app: my-app
        version: v2
    spec:
      containers:
        - name: app
          image: my-app:2.0.0
```

**2. Apply DestinationRule (defines subsets):**
```powershell
kubectl apply -f k8s/dev/traffic/canary-destinationrule.yaml
```

**3. Apply VirtualService (defines traffic split):**
```powershell
kubectl apply -f k8s/dev/traffic/canary-virtualservice.yaml
```

**4. Adjust traffic weights:**

Edit `canary-virtualservice.yaml` to change the split:
```yaml
# 90% to v1, 10% to v2 (initial canary)
route:
  - destination:
      host: my-app
      subset: stable
    weight: 90
  - destination:
      host: my-app
      subset: canary
    weight: 10
```

Gradually increase canary weight as confidence grows:
- 90/10 → 80/20 → 50/50 → 20/80 → 0/100

### Blue-Green with Instant Cutover

For blue-green, use 100% weights:

```yaml
# Blue is live
route:
  - destination:
      host: my-app
      subset: blue
    weight: 100
  - destination:
      host: my-app
      subset: green
    weight: 0

# Cutover to green
route:
  - destination:
      host: my-app
      subset: blue
    weight: 0
  - destination:
      host: my-app
      subset: green
    weight: 100
```

### Header-Based Routing (Testing Canary)

Route specific requests to canary based on headers:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: my-app
  namespace: platform-dev
spec:
  hosts:
    - my-app
  http:
    # Route test traffic to canary
    - match:
        - headers:
            x-canary:
              exact: "true"
      route:
        - destination:
            host: my-app
            subset: canary
    # Default: all other traffic to stable
    - route:
        - destination:
            host: my-app
            subset: stable
```

Test with:
```powershell
curl -H "x-canary: true" http://my-app.platform-dev.svc.cluster.local
```

---

## Troubleshooting

### Context Mismatch

**Symptom:** Bootstrap fails with "kubecontext is not docker-desktop"

**Solution:**
```powershell
# List available contexts
kubectl config get-contexts

# Switch to docker-desktop
kubectl config use-context docker-desktop

# Verify
kubectl config current-context
```

**Bypass (not recommended):**
```powershell
.\scripts\bootstrap-docker-desktop-k8s.ps1 -Force
```

### Image Pull Issues

**Symptom:** Pods stuck in `ImagePullBackOff` or `ErrImagePull`

**Solutions:**

1. **Check image name/tag:**
   ```powershell
   kubectl describe pod <pod-name> -n platform-dev | Select-String -Pattern "Image:"
   ```

2. **For local images, ensure they're built:**
   ```powershell
   docker images | Select-String "my-app"
   ```

3. **Docker Desktop image sharing:**
   Docker Desktop Kubernetes uses the same Docker daemon, so locally built images are available without pushing to a registry.

4. **Private registry auth:**
   ```powershell
   kubectl create secret docker-registry regcred `
       --docker-server=<registry> `
       --docker-username=<user> `
       --docker-password=<password> `
       -n platform-dev
   ```

### Resetting Docker Desktop Kubernetes

**When to reset:**
- Cluster in bad state
- Storage issues
- Want a fresh start

**Steps:**
1. Open Docker Desktop
2. Go to **Settings** → **Kubernetes**
3. Click **Reset Kubernetes Cluster**
4. Wait for reset to complete
5. Re-run bootstrap script

**Note:** This deletes all Kubernetes resources but preserves Docker images.

### Dashboard Access and Tokens

**Start port forward:**
```powershell
kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard-kong-proxy 8443:443
```

**Access:** https://localhost:8443

**Create a viewer token (safe for dev):**
```powershell
# Create service account
kubectl create serviceaccount dashboard-viewer -n kubernetes-dashboard

# Grant view permissions
kubectl create clusterrolebinding dashboard-viewer `
    --clusterrole=view `
    --serviceaccount=kubernetes-dashboard:dashboard-viewer

# Generate token
kubectl create token dashboard-viewer -n kubernetes-dashboard
```

**Security Warning:** Never create cluster-admin tokens. Use RBAC to grant minimum necessary permissions.

### Istio Sidecar Not Injecting

**Symptom:** Pods don't have istio-proxy container

**Check namespace labels:**
```powershell
kubectl get namespace platform-dev --show-labels
```

**Expected for sidecar mode:**
```
istio-injection=enabled
```

**Fix:**
```powershell
kubectl label namespace platform-dev istio-injection=enabled --overwrite
# Restart pods to inject sidecar
kubectl rollout restart deployment -n platform-dev
```

### Ambient Mode: L7 Features Not Working

**Symptom:** VirtualService routing rules not applied

**Cause:** Ambient mode requires waypoint proxy for L7 features

**Solution:**
```powershell
# Check if waypoint exists
kubectl get gateway -n platform-dev

# Apply waypoint if missing
kubectl apply -f k8s/dev/ambient/waypoint-platform-dev.yaml

# Verify waypoint pods
kubectl get pods -n platform-dev -l gateway.networking.k8s.io/gateway-name=waypoint
```

### mTLS Verification

**Check mTLS status:**
```powershell
# Requires istioctl
istioctl authn tls-check <pod-name>.<namespace> -n <namespace>

# Example
istioctl authn tls-check my-app-abc123.platform-dev -n platform-dev
```

**Check PeerAuthentication:**
```powershell
kubectl get peerauthentication -n platform-dev
```

### NetworkPolicy Blocking Traffic

**Symptom:** Pods can't communicate

**Debug:**
```powershell
# List network policies
kubectl get networkpolicy -n platform-dev

# Check pod labels (must match policy selectors)
kubectl get pods -n platform-dev --show-labels

# Describe policy
kubectl describe networkpolicy np-default-deny -n platform-dev
```

**Temporary bypass (debugging only):**
```powershell
kubectl delete networkpolicy np-default-deny -n platform-dev
# Don't forget to re-apply after debugging!
```

### Logs and Debugging

**Istiod logs:**
```powershell
kubectl logs -l app=istiod -n istio-system -f
```

**Sidecar logs:**
```powershell
kubectl logs <pod-name> -c istio-proxy -n platform-dev
```

**Ztunnel logs (ambient mode):**
```powershell
kubectl logs -l app=ztunnel -n istio-system -f
```

**Waypoint logs (ambient mode):**
```powershell
kubectl logs -l gateway.networking.k8s.io/gateway-name=waypoint -n platform-dev -f
```

---

## Quick Reference

### Common Commands

```powershell
# Bootstrap (re-run safe)
.\scripts\bootstrap-docker-desktop-k8s.ps1

# Start Tilt
tilt up -- --mode=k8s --k8s-istio-enabled=true

# Check pod status
kubectl get pods -n platform-dev

# Check Istio
kubectl get pods -n istio-system
helm list -n istio-system

# Restart deployment (trigger sidecar injection)
kubectl rollout restart deployment/<name> -n platform-dev

# Port forward
kubectl port-forward svc/<service> -n platform-dev 8080:80

# Dashboard
kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard-kong-proxy 8443:443
```

### Namespace Labels by Mode

| Mode | Labels |
|------|--------|
| sidecar | `istio-injection=enabled` |
| ambient | `istio.io/dataplane-mode=ambient` |
| none | (no Istio labels) |

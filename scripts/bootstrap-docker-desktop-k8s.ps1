<#
.SYNOPSIS
    Idempotent bootstrap for Docker Desktop Kubernetes with Istio service mesh.

.DESCRIPTION
    This script sets up a local Kubernetes development environment on Docker Desktop
    with Istio 1.28.2 service mesh, supporting both Sidecar and Ambient dataplane modes.
    
    Designed for Windows 10/11 with PowerShell 5.1+ or PowerShell 7+.
    
    IDEMPOTENCY RULES:
    - Safe to run multiple times with no harmful side-effects
    - Uses helm upgrade --install (never raw install)
    - Uses kubectl apply -f for YAML
    - Creates namespaces only when missing
    - Labels/annotates with --overwrite only on intended keys
    - Never deletes or resets resources automatically
    - Fails fast with actionable errors

.PARAMETER Force
    Bypass kubecontext safety check (proceed even if not docker-desktop).

.PARAMETER DataplaneMode
    Istio dataplane mode for platform-dev namespace enrollment.
    - sidecar: Standard sidecar injection (default)
    - ambient: Ambient mesh with ztunnel (L4) + optional waypoint (L7)
    - none: No Istio enrollment for platform-dev

.PARAMETER InstallIngressGateway
    Install Istio ingress gateway for production-like routing.

.PARAMETER InstallDashboard
    Install Kubernetes Dashboard for cluster visibility.

.PARAMETER AllowInternetEgress
    Apply NetworkPolicy allowing internet egress from platform-dev.

.PARAMETER IstioNamespace
    Namespace for Istio control plane components.

.PARAMETER PlatformNamespace
    Application namespace for development workloads.

.PARAMETER IstioVersion
    Pinned Istio version (must match chart versions).

.PARAMETER UseGitBash
    Reserved for future quoting compatibility; currently unused.

.EXAMPLE
    .\bootstrap-docker-desktop-k8s.ps1
    # Default: Sidecar mode, no gateway, no dashboard

.EXAMPLE
    .\bootstrap-docker-desktop-k8s.ps1 -DataplaneMode ambient -InstallIngressGateway
    # Ambient mode with ingress gateway

.EXAMPLE
    .\bootstrap-docker-desktop-k8s.ps1 -Force -InstallDashboard -AllowInternetEgress
    # Force run with dashboard and internet egress enabled
#>

[CmdletBinding()]
param(
    [switch]$Force = $false,

    [ValidateSet("sidecar", "ambient", "none")]
    [string]$DataplaneMode = "sidecar",

    [switch]$InstallIngressGateway = $false,

    [switch]$InstallDashboard = $false,

    [switch]$AllowInternetEgress = $false,

    [string]$IstioNamespace = "istio-system",

    [string]$PlatformNamespace = "platform-dev",

    [string]$IstioVersion = "1.28.2",

    [switch]$UseGitBash = $false
)

# ==============================================================================
# STRICT MODE AND ERROR HANDLING
# ==============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Pinned versions for reproducibility
$GATEWAY_API_VERSION = "v1.2.1"
$GATEWAY_API_CRD_URL = "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

function Write-Header {
    param([string]$Message)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Message)
    Write-Host "[STEP] $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Gray
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Test-Command {
    param([string]$Command)
    $null = Get-Command $Command -ErrorAction SilentlyContinue
    return $?
}

function Exit-WithError {
    param(
        [string]$Message,
        [string]$Remediation = ""
    )
    Write-Err $Message
    if ($Remediation) {
        Write-Host "Remediation: $Remediation" -ForegroundColor Yellow
    }
    exit 1
}

function Get-ScriptRoot {
    # Compatible with PS 5.1 and PS 7+
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }
    return Split-Path -Parent $MyInvocation.MyCommand.Definition
}

function Get-RepoRoot {
    $scriptDir = Get-ScriptRoot
    # scripts/ is one level below repo root
    return Split-Path -Parent $scriptDir
}

function Invoke-KubectlSafe {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$PassThru,
        [switch]$AllowFailure
    )
    
    $argString = $Arguments -join " "
    Write-Info "kubectl $argString"
    
    if ($PassThru) {
        $result = & kubectl @Arguments 2>&1
        if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
            Exit-WithError "kubectl command failed: kubectl $argString" "Check cluster connectivity and resource state."
        }
        return $result
    }
    else {
        & kubectl @Arguments
        if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
            Exit-WithError "kubectl command failed: kubectl $argString" "Check cluster connectivity and resource state."
        }
    }
}

function Invoke-HelmSafe {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$PassThru,
        [switch]$AllowFailure
    )
    
    $argString = $Arguments -join " "
    Write-Info "helm $argString"
    
    if ($PassThru) {
        $result = & helm @Arguments 2>&1
        if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
            Exit-WithError "helm command failed: helm $argString" "Check Helm configuration and chart availability."
        }
        return $result
    }
    else {
        & helm @Arguments
        if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
            Exit-WithError "helm command failed: helm $argString" "Check Helm configuration and chart availability."
        }
    }
}

function Test-NamespaceExists {
    param([string]$Namespace)
    $result = kubectl get namespace $Namespace --ignore-not-found -o name 2>$null
    return ($null -ne $result -and $result -ne "")
}

function New-NamespaceIfMissing {
    param([string]$Namespace)
    if (-not (Test-NamespaceExists $Namespace)) {
        Write-Step "Creating namespace: $Namespace"
        Invoke-KubectlSafe -Arguments @("create", "namespace", $Namespace)
    }
    else {
        Write-Info "Namespace already exists: $Namespace"
    }
}

function Get-InstalledIstioVersion {

    # First check if namespace exists
    $nsExists = kubectl get namespace $IstioNamespace --ignore-not-found -o name 2>$null
    if (-not $nsExists) {
        return $null
    }

    # Check istiod deployment for version label (suppress error if not found)
    $version = $null
    $deployExists = kubectl get deployment istiod -n $IstioNamespace --ignore-not-found -o name 2>$null
    if ($deployExists) {
        $version = kubectl get deployment istiod -n $IstioNamespace -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $version) {
            return $version
        }
    }

    <#     # Check istiod deployment for version label
    $version = kubectl get deployment istiod -n $IstioNamespace -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $version) {
        return $version
    } #>
    
    # Fallback: check Helm release
    $releases = helm list -n $IstioNamespace -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($releases) {
        $istiod = $releases | Where-Object { $_.name -eq "istiod" }
        if ($istiod) {
            # Chart version format: istiod-1.28.2
            if ($istiod.chart -match "istiod-(.+)") {
                return $Matches[1]
            }
        }
    }
    
    return $null
}

function Test-HelmReleaseExists {
    param(
        [string]$ReleaseName,
        [string]$Namespace
    )
    $result = helm status $ReleaseName -n $Namespace 2>$null
    return ($LASTEXITCODE -eq 0)
}

# ==============================================================================
# PRE-FLIGHT CHECKS
# ==============================================================================

Write-Header "Docker Desktop Kubernetes Bootstrap"
Write-Host "Istio Version: $IstioVersion"
Write-Host "Dataplane Mode: $DataplaneMode"
Write-Host "Platform Namespace: $PlatformNamespace"
Write-Host "Install Ingress Gateway: $InstallIngressGateway"
Write-Host "Install Dashboard: $InstallDashboard"
Write-Host "Allow Internet Egress: $AllowInternetEgress"
Write-Host ""

# -----------------------------------------------------------------------------
# Check 1: kubectl exists
# -----------------------------------------------------------------------------
Write-Step "Checking for kubectl..."
if (-not (Test-Command "kubectl")) {
    Exit-WithError "kubectl not found in PATH." "Install kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/"
}
Write-Success "kubectl found"

# -----------------------------------------------------------------------------
# Check 2: helm exists
# -----------------------------------------------------------------------------
Write-Step "Checking for helm..."
if (-not (Test-Command "helm")) {
    Exit-WithError "helm not found in PATH." "Install helm: https://helm.sh/docs/intro/install/ or 'choco install kubernetes-helm'"
}
Write-Success "helm found"

# -----------------------------------------------------------------------------
# Check 3: Docker Desktop Kubernetes is running
# -----------------------------------------------------------------------------
Write-Step "Checking Kubernetes cluster connectivity..."
$clusterInfo = kubectl cluster-info 2>&1
if ($LASTEXITCODE -ne 0) {
    Exit-WithError "Cannot connect to Kubernetes cluster." @"
Ensure Docker Desktop is running and Kubernetes is enabled:
1. Open Docker Desktop
2. Go to Settings > Kubernetes
3. Check 'Enable Kubernetes'
4. Click 'Apply & Restart'
"@
}
Write-Success "Kubernetes cluster is reachable"

# -----------------------------------------------------------------------------
# Check 4: kubecontext is docker-desktop
# -----------------------------------------------------------------------------
Write-Step "Checking kubecontext..."
$currentContext = kubectl config current-context 2>$null
if ($currentContext -ne "docker-desktop") {
    if ($Force) {
        Write-Warn "Current context is '$currentContext', not 'docker-desktop'. Proceeding due to -Force flag."
        Write-Warn "THIS MAY AFFECT A NON-LOCAL CLUSTER. Use with caution!"
    }
    else {
        Exit-WithError "Current kubecontext is '$currentContext', expected 'docker-desktop'." @"
Switch context with:
    kubectl config use-context docker-desktop

Or run with -Force to bypass this safety check (NOT RECOMMENDED for remote clusters).
"@
    }
}
else {
    Write-Success "kubecontext is docker-desktop"
}

# -----------------------------------------------------------------------------
# Check 5: Default StorageClass exists
# -----------------------------------------------------------------------------
Write-Step "Checking StorageClass availability..."
$storageClasses = kubectl get storageclass -o name 2>$null
if (-not $storageClasses) {
    Write-Warn "No StorageClass found. PVC provisioning may fail."
    Write-Host @"
Docker Desktop should provide 'hostpath' StorageClass by default.
If PVCs fail to provision:
1. Reset Docker Desktop Kubernetes (Settings > Kubernetes > Reset)
2. Or manually create a StorageClass

Continuing anyway - this may cause issues with PersistentVolumeClaims.
"@ -ForegroundColor Yellow
}
else {
    $scList = kubectl get storageclass -o json 2>$null | ConvertFrom-Json
    $defaultSC = $scList.items | Where-Object { 
        $_.metadata.annotations.'storageclass.kubernetes.io/is-default-class' -eq 'true' 
    } | Select-Object -First 1 -ExpandProperty metadata | Select-Object -ExpandProperty name

    if ($defaultSC) {
        Write-Success "Default StorageClass found: $defaultSC"
    }
    else {
        Write-Warn "StorageClasses exist but none marked as default. PVCs without explicit storageClassName may fail."
    }
}

# -----------------------------------------------------------------------------
# Check 6: Existing Istio version check
# -----------------------------------------------------------------------------
Write-Step "Checking for existing Istio installation..."
$installedVersion = Get-InstalledIstioVersion
if ($installedVersion) {
    if ($installedVersion -ne $IstioVersion) {
        Exit-WithError "Istio version mismatch! Installed: $installedVersion, Required: $IstioVersion" @"
This script requires Istio $IstioVersion exactly.

To resolve:
1. OPTION A - Remove existing Istio (if safe):
   helm uninstall istiod -n $IstioNamespace
   helm uninstall istio-base -n $IstioNamespace
   # If ztunnel installed:
   helm uninstall ztunnel -n $IstioNamespace
   # If gateway installed:
   helm uninstall istio-ingressgateway -n $IstioNamespace
   kubectl delete namespace $IstioNamespace

2. OPTION B - Update this script's IstioVersion parameter to match installed version.
   (Not recommended - may cause compatibility issues)

3. OPTION C - Reset Docker Desktop Kubernetes entirely:
   Docker Desktop > Settings > Kubernetes > Reset Kubernetes Cluster
"@
    }
    else {
        Write-Success "Istio $IstioVersion already installed - will reconcile state"
    }
}
else {
    Write-Info "No existing Istio installation detected - will install fresh"
}

# ==============================================================================
# GATEWAY API CRD INSTALLATION
# ==============================================================================

Write-Header "Gateway API CRDs"

Write-Step "Checking Gateway API CRDs..."
$gatewayApiInstalled = kubectl get crd gateways.gateway.networking.k8s.io --ignore-not-found -o name 2>$null
if (-not $gatewayApiInstalled) {
    Write-Step "Installing Gateway API CRDs ($GATEWAY_API_VERSION)..."
    Invoke-KubectlSafe -Arguments @("apply", "-f", $GATEWAY_API_CRD_URL)
    Write-Success "Gateway API CRDs installed (version $GATEWAY_API_VERSION)"
}
else {
    Write-Success "Gateway API CRDs already installed"
}

# ==============================================================================
# HELM REPOSITORY SETUP
# ==============================================================================

Write-Header "Helm Repository Setup"

Write-Step "Adding Istio Helm repository..."
Invoke-HelmSafe -Arguments @("repo", "add", "istio", "https://istio-release.storage.googleapis.com/charts") -AllowFailure
# Repo add fails if exists - that's fine

Write-Step "Updating Helm repositories..."
Invoke-HelmSafe -Arguments @("repo", "update")
Write-Success "Helm repositories updated"

# ==============================================================================
# ISTIO INSTALLATION
# ==============================================================================

Write-Header "Istio $IstioVersion Installation"

# Create istio-system namespace
New-NamespaceIfMissing $IstioNamespace

# -----------------------------------------------------------------------------
# Install istio-base (CRDs and cluster-wide resources)
# -----------------------------------------------------------------------------
Write-Step "Installing/upgrading istio-base..."
if (Test-Path(Join-Path (Get-RepoRoot) "charts/base-$IstioVersion.tgz")) {
    Write-Info "Using local istio-base chart from repo"
    $baseChartPath = Join-Path (Get-RepoRoot) "charts/base-$IstioVersion.tgz"
    Invoke-HelmSafe -Arguments @(
        "upgrade", "--install", "istio-base", $baseChartPath,
        "-n", $IstioNamespace,
        "--wait"
    )
}
else {
    Write-Info "Using istio/base chart from Helm repository"
    Invoke-HelmSafe -Arguments @(
    "upgrade", "--install", "istio-base", "istio/base",
    "-n", $IstioNamespace,
    "--version", $IstioVersion,
    "--wait"
    )
}

Write-Success "istio-base installed"

# -----------------------------------------------------------------------------
# Install istiod (control plane)
# -----------------------------------------------------------------------------
Write-Step "Installing/upgrading istiod..."

# Build istiod values based on dataplane mode
$istiodValues = @()

# Common values for both modes
$istiodValues += "--set", "pilot.resources.requests.cpu=100m"
$istiodValues += "--set", "pilot.resources.requests.memory=256Mi"

# Mode-specific configuration
switch ($DataplaneMode) {
    "ambient" {
        Write-Info "Configuring istiod for Ambient mode..."
        # Enable ambient mesh support in istiod
        $istiodValues += "--set", "pilot.env.PILOT_ENABLE_AMBIENT=true"
        $istiodValues += "--set", "meshConfig.defaultConfig.proxyMetadata.ISTIO_META_ENABLE_HBONE=true"
    }
    "sidecar" {
        Write-Info "Configuring istiod for Sidecar mode..."
        # Standard sidecar mode - default configuration
    }
    "none" {
        Write-Info "Configuring istiod (no automatic enrollment)..."
    }
}

if(Test-Path(Join-Path (Get-RepoRoot) "charts/istiod-$IstioVersion.tgz")) {
    Write-Info "Using local istiod chart from repo"
    $istiodChartPath = Join-Path (Get-RepoRoot) "charts/istiod-$IstioVersion.tgz"
    $istiodArgs = @(
        "upgrade", "--install", "istiod", $istiodChartPath,
        "-n", $IstioNamespace
    ) + $istiodValues + @("--wait", "--timeout", "5m")
}
else {
    Write-Info "Using istio/istiod chart from Helm repository"
    $istiodArgs = @(
    "upgrade", "--install", "istiod", "istio/istiod",
    "-n", $IstioNamespace,
    "--version", $IstioVersion
    ) + $istiodValues + @("--wait", "--timeout", "5m")
}

Invoke-HelmSafe -Arguments $istiodArgs
Write-Success "istiod installed"

# -----------------------------------------------------------------------------
# Install ztunnel (Ambient mode only)
# -----------------------------------------------------------------------------
if ($DataplaneMode -eq "ambient") {
    Write-Step "Installing/upgrading ztunnel for Ambient mode..."
    Invoke-HelmSafe -Arguments @(
        "upgrade", "--install", "ztunnel", "istio/ztunnel",
        "-n", $IstioNamespace,
        "--version", $IstioVersion,
        "--wait", "--timeout", "3m"
    )
    Write-Success "ztunnel installed"
}
else {
    Write-Info "Skipping ztunnel (not required for $DataplaneMode mode)"
}

# -----------------------------------------------------------------------------
# Install Ingress Gateway (optional)
# -----------------------------------------------------------------------------
if ($InstallIngressGateway) {
    Write-Step "Installing/upgrading Istio Ingress Gateway..."
    
    # For Docker Desktop, use LoadBalancer (maps to localhost) or NodePort
    Invoke-HelmSafe -Arguments @(
        "upgrade", "--install", "istio-ingressgateway", "istio/gateway",
        "-n", $IstioNamespace,
        "--version", $IstioVersion,
        "--set", "service.type=LoadBalancer",
        "--wait", "--timeout", "3m"
    )
    Write-Success "Istio Ingress Gateway installed"
    
    # Get gateway service info
    Write-Info "Ingress Gateway service:"
    kubectl get svc istio-ingressgateway -n $IstioNamespace
}
else {
    Write-Info "Skipping Ingress Gateway (use -InstallIngressGateway to enable)"
}

# Wait for Istio control plane to be ready
Write-Step "Waiting for Istio control plane pods..."
Invoke-KubectlSafe -Arguments @(
    "wait", "--for=condition=Ready", "pod",
    "-l", "app=istiod",
    "-n", $IstioNamespace,
    "--timeout=120s"
)
Write-Success "Istio control plane is ready"

# ==============================================================================
# PLATFORM NAMESPACE SETUP
# ==============================================================================

Write-Header "Platform Namespace Setup"

# Create platform namespace
New-NamespaceIfMissing $PlatformNamespace

# -----------------------------------------------------------------------------
# Label namespace according to DataplaneMode
# -----------------------------------------------------------------------------
Write-Step "Labeling namespace $PlatformNamespace for $DataplaneMode mode..."

switch ($DataplaneMode) {
    "sidecar" {
        # Enable sidecar injection
        Invoke-KubectlSafe -Arguments @(
            "label", "namespace", $PlatformNamespace,
            "istio-injection=enabled",
            "--overwrite"
        )
        # Remove ambient label if present
        Invoke-KubectlSafe -Arguments @(
            "label", "namespace", $PlatformNamespace,
            "istio.io/dataplane-mode-",
            "--overwrite"
        ) -AllowFailure
        Write-Success "Namespace labeled for sidecar injection"
    }
    "ambient" {
        # Enable ambient mode
        Invoke-KubectlSafe -Arguments @(
            "label", "namespace", $PlatformNamespace,
            "istio.io/dataplane-mode=ambient",
            "--overwrite"
        )
        # Remove sidecar injection label if present
        Invoke-KubectlSafe -Arguments @(
            "label", "namespace", $PlatformNamespace,
            "istio-injection-",
            "--overwrite"
        ) -AllowFailure
        Write-Success "Namespace labeled for ambient mode"
    }
    "none" {
        # Remove both labels
        Invoke-KubectlSafe -Arguments @(
            "label", "namespace", $PlatformNamespace,
            "istio-injection-",
            "istio.io/dataplane-mode-",
            "--overwrite"
        ) -AllowFailure
        Write-Success "Namespace has no Istio enrollment"
    }
}

# ==============================================================================
# SECURITY MANIFESTS
# ==============================================================================

Write-Header "Security Policies"

$repoRoot = Get-RepoRoot
$securityPath = Join-Path $repoRoot "k8s/dev/security"
$networkPolicyPath = Join-Path $repoRoot "k8s/dev/networkpolicies"
$ambientPath = Join-Path $repoRoot "k8s/dev/ambient"

# Verify manifest directories exist
if (-not (Test-Path $securityPath)) {
    Exit-WithError "Security manifests not found at: $securityPath" "Ensure k8s/dev/security/ directory exists in repo."
}
if (-not (Test-Path $networkPolicyPath)) {
    Exit-WithError "NetworkPolicy manifests not found at: $networkPolicyPath" "Ensure k8s/dev/networkpolicies/ directory exists in repo."
}

# -----------------------------------------------------------------------------
# Always apply: Zero Trust base policies
# -----------------------------------------------------------------------------
Write-Step "Applying PeerAuthentication (mTLS STRICT)..."
Invoke-KubectlSafe -Arguments @("apply", "-f", (Join-Path $securityPath "peerauthentication-strict.yaml"))

Write-Step "Applying AuthorizationPolicy (default-deny)..."
Invoke-KubectlSafe -Arguments @("apply", "-f", (Join-Path $securityPath "authz-default-deny.yaml"))

Write-Step "Applying AuthorizationPolicy (allow intra-namespace)..."
Invoke-KubectlSafe -Arguments @("apply", "-f", (Join-Path $securityPath "authz-allow-intra-namespace.yaml"))

Write-Step "Applying NetworkPolicy (default-deny)..."
Invoke-KubectlSafe -Arguments @("apply", "-f", (Join-Path $networkPolicyPath "np-default-deny.yaml"))

Write-Step "Applying NetworkPolicy (allow DNS)..."
Invoke-KubectlSafe -Arguments @("apply", "-f", (Join-Path $networkPolicyPath "np-allow-dns.yaml"))

Write-Success "Zero Trust base policies applied"

# -----------------------------------------------------------------------------
# Conditional: Ingress Gateway authorization
# -----------------------------------------------------------------------------
if ($InstallIngressGateway) {
    Write-Step "Applying AuthorizationPolicy (allow from ingress gateway)..."
    Invoke-KubectlSafe -Arguments @("apply", "-f", (Join-Path $securityPath "authz-allow-from-ingressgateway.yaml"))
    Write-Success "Ingress gateway authorization policy applied"
}
else {
    Write-Info "Skipping ingress gateway auth policy (gateway not installed)"
}

# -----------------------------------------------------------------------------
# Conditional: Internet egress
# -----------------------------------------------------------------------------
if ($AllowInternetEgress) {
    Write-Step "Applying NetworkPolicy (allow internet egress)..."
    Invoke-KubectlSafe -Arguments @("apply", "-f", (Join-Path $networkPolicyPath "np-allow-internet-egress.yaml"))
    Write-Success "Internet egress NetworkPolicy applied"
}
else {
    Write-Info "Internet egress blocked (default). Use -AllowInternetEgress to enable."
}

# -----------------------------------------------------------------------------
# Ambient mode: Waypoint deployment
# -----------------------------------------------------------------------------
if ($DataplaneMode -eq "ambient") {
    Write-Header "Ambient Mode: Waypoint Proxy"
    
    $waypointManifest = Join-Path $ambientPath "waypoint-platform-dev.yaml"
    
    if (Test-Path $waypointManifest) {
        Write-Step "Applying Waypoint proxy for L7 traffic management..."
        Invoke-KubectlSafe -Arguments @("apply", "-f", $waypointManifest)
        Write-Success "Waypoint proxy deployed"
        
        Write-Info @"

IMPORTANT: Waypoint enables L7 features in Ambient mode.
Without waypoint, only L4 (mTLS, basic allow/deny) is available.
With waypoint, you get: request routing, retries, timeouts, header matching.

To verify waypoint:
    kubectl get gateway -n $PlatformNamespace
    kubectl get pods -n $PlatformNamespace -l gateway.networking.k8s.io/gateway-name=waypoint

"@
    }
    else {
        Write-Warn "Waypoint manifest not found at: $waypointManifest"
        Write-Host @"

To manually apply waypoint for L7 features:
    kubectl apply -f k8s/dev/ambient/waypoint-platform-dev.yaml

Or use istioctl:
    istioctl waypoint apply -n $PlatformNamespace --name waypoint

"@ -ForegroundColor Yellow
    }
}

# ==============================================================================
# KUBERNETES DASHBOARD (Optional)
# ==============================================================================

if ($InstallDashboard) {
    Write-Header "Kubernetes Dashboard"
    
    Write-Step "Adding Kubernetes Dashboard Helm repository..."
    Invoke-HelmSafe -Arguments @("repo", "add", "kubernetes-dashboard", "https://kubernetes.github.io/dashboard/") -AllowFailure
    Invoke-HelmSafe -Arguments @("repo", "update")
    
    Write-Step "Installing/upgrading Kubernetes Dashboard..."
    Invoke-HelmSafe -Arguments @(
        "upgrade", "--install", "kubernetes-dashboard", "kubernetes-dashboard/kubernetes-dashboard",
        "-n", "kubernetes-dashboard",
        "--create-namespace",
        "--wait", "--timeout", "3m"
    )
    Write-Success "Kubernetes Dashboard installed"
    
    Write-Host @"

DASHBOARD ACCESS:
-----------------
Run this command to start port forwarding (Ctrl+C to stop):
    kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard-kong-proxy 8443:443

Then open: https://localhost:8443

AUTHENTICATION:
For basic exploration, create a service account with view permissions:
    kubectl create serviceaccount dashboard-viewer -n kubernetes-dashboard
    kubectl create clusterrolebinding dashboard-viewer --clusterrole=view --serviceaccount=kubernetes-dashboard:dashboard-viewer
    kubectl create token dashboard-viewer -n kubernetes-dashboard

WARNING: Do NOT create cluster-admin tokens for the dashboard in production.
Use RBAC to grant minimum necessary permissions.

"@ -ForegroundColor Cyan
}

# ==============================================================================
# VERIFICATION
# ==============================================================================

Write-Header "Verification"

Write-Step "Istio system pods:"
kubectl get pods -n $IstioNamespace

Write-Host ""
Write-Step "Platform namespace pods:"
kubectl get pods -n $PlatformNamespace 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Info "No pods in $PlatformNamespace yet (expected for fresh setup)"
}

Write-Host ""
Write-Step "Helm releases in $IstioNamespace"
helm list -n $IstioNamespace

Write-Host ""
Write-Step "Namespace labels:"
kubectl get namespace $PlatformNamespace -o jsonpath='{.metadata.labels}' | ConvertFrom-Json | Format-List

Write-Host ""
Write-Step "Applied security policies:"
Write-Info "PeerAuthentication:"
kubectl get peerauthentication -n $PlatformNamespace 2>$null
Write-Info "AuthorizationPolicy:"
kubectl get authorizationpolicy -n $PlatformNamespace 2>$null
Write-Info "NetworkPolicy:"
kubectl get networkpolicy -n $PlatformNamespace 2>$null

# Check for istioctl
if (Test-Command "istioctl") {
    Write-Host ""
    Write-Step "Running istioctl verify-install..."
    istioctl verify-install 2>&1 | Write-Host
}
else {
    Write-Info "istioctl not found - skipping verify-install (optional tool)"
}

# ==============================================================================
# SUMMARY
# ==============================================================================

Write-Header "Bootstrap Complete!"

Write-Host @"
CONFIGURATION SUMMARY
---------------------
Istio Version:        $IstioVersion
Dataplane Mode:       $DataplaneMode
Istio Namespace:      $IstioNamespace
Platform Namespace:   $PlatformNamespace
Ingress Gateway:      $InstallIngressGateway
Internet Egress:      $AllowInternetEgress
Dashboard:            $InstallDashboard

VERIFICATION COMMANDS
---------------------
# Check Istio pods
kubectl get pods -n $IstioNamespace

# Check platform namespace enrollment
kubectl get namespace $PlatformNamespace --show-labels

# Check mTLS status (requires istioctl)
istioctl authn tls-check -n $PlatformNamespace

# Test connectivity from a pod
kubectl run test-curl --rm -it --image=curlimages/curl -n $PlatformNamespace -- curl -v http://<service>

NEXT STEPS
----------
1. Deploy your application to $PlatformNamespace
2. Use Tilt: tilt up -- --mode=k8s --k8s-istio-enabled=true
3. Access via port-forward or ingress gateway (if enabled)

For production-like routing with gateway:
    tilt up -- --mode=k8s --k8s-istio-enabled=true --k8s-manage-gateway=true

Documentation: README.md
"@ -ForegroundColor Green

exit 0
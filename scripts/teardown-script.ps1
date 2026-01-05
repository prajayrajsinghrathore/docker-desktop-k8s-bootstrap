<#
.SYNOPSIS
    Idempotent teardown for Docker Desktop Kubernetes bootstrap with Istio service mesh.

.DESCRIPTION
    Safely removes what our bootstrap script sets up:
    - Istio Helm releases (istio-base, istiod, optional ztunnel, optional ingress gateway)
    - Optional Kubernetes Dashboard Helm release
    - Platform namespace enrollment labels (sidecar/ambient)
    - Bootstrap-applied security policies and NetworkPolicies (and optional waypoint)
    - OPTIONAL: Gateway API CRDs (cluster-wide) (opt-in)
    - OPTIONAL: Namespace deletion (destructive) (opt-in + explicit acknowledgement)

    Designed for Windows 10/11 with PowerShell 5.1+ or PowerShell 7+.

.SAFETY / IDEMPOTENCY
    - Safe to run multiple times
    - Does NOT delete workloads or namespaces by default
    - Does NOT remove Gateway API CRDs by default
    - Tolerates resources/releases not existing
    - Fails fast with actionable errors

.PARAMETER Force
    Bypass kubecontext safety check AND allow teardown even if Istio version != expected.

.PARAMETER IstioNamespace
    Namespace where Istio control plane is installed (default: istio-system).

.PARAMETER PlatformNamespace
    Application namespace used by bootstrap (default: platform-dev).

.PARAMETER DashboardNamespace
    Namespace where Kubernetes Dashboard is installed (default: kubernetes-dashboard).

.PARAMETER IstioVersion
    Expected Istio version (bootstrap pinned). Used for safety check / reporting.

.PARAMETER RemoveIngressGateway
    Uninstall istio-ingressgateway Helm release if present (default: true).

.PARAMETER RemoveZtunnel
    Uninstall ztunnel Helm release if present (default: true).

.PARAMETER RemoveDashboard
    Uninstall kubernetes-dashboard Helm release if present (default: true).

.PARAMETER RemovePlatformPolicies
    Delete bootstrap-applied policies/waypoint from repo YAML (default: true).

.PARAMETER RemoveNamespaceLabels
    Remove namespace labels used for Istio enrollment from PlatformNamespace (default: true).

.PARAMETER DeleteNamespaces
    DESTRUCTIVE. Delete Platform/Istio/Dashboard namespaces (default: false).
    Requires -IUnderstandThisDeletesWorkloads.

.PARAMETER IUnderstandThisDeletesWorkloads
    Required acknowledgement switch when using -DeleteNamespaces.

.PARAMETER RemoveGatewayApiCrds
    DESTRUCTIVE (cluster-wide). Remove Gateway API CRDs installed by bootstrap (default: false).

.EXAMPLE
    .\teardown-docker-desktop-k8s.ps1
    # Removes bootstrap-applied policies, removes labels, uninstalls Istio releases, uninstalls dashboard (if installed).
    # Does NOT delete namespaces and does NOT remove Gateway API CRDs.

.EXAMPLE
    .\teardown-docker-desktop-k8s.ps1 -DeleteNamespaces -IUnderstandThisDeletesWorkloads
    # Also deletes the namespaces (DESTRUCTIVE).

.EXAMPLE
    .\teardown-docker-desktop-k8s.ps1 -RemoveGatewayApiCrds
    # Also removes Gateway API CRDs (cluster-wide, opt-in).
#>

[CmdletBinding()]
param(
    [switch]$Force = $false,

    [string]$IstioNamespace = "istio-system",
    [string]$PlatformNamespace = "platform-dev",
    [string]$DashboardNamespace = "kubernetes-dashboard",

    [string]$IstioVersion = "1.28.2",

    [switch]$RemoveIngressGateway = $true,
    [switch]$RemoveZtunnel = $true,
    [switch]$RemoveDashboard = $true,

    [switch]$RemovePlatformPolicies = $true,
    [switch]$RemoveNamespaceLabels = $true,

    [switch]$DeleteNamespaces = $false,
    [switch]$IUnderstandThisDeletesWorkloads = $false,

    [switch]$RemoveGatewayApiCrds = $false
)

# ==============================================================================
# STRICT MODE AND ERROR HANDLING
# ==============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Gateway API CRDs pinned by bootstrap
$GATEWAY_API_VERSION = "v1.2.1"
$GATEWAY_API_CRD_URL = "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# Helm release names used by bootstrap
$RELEASE_ISTIO_BASE = "istio-base"
$RELEASE_ISTIOD     = "istiod"
$RELEASE_ZTUNNEL    = "ztunnel"
$RELEASE_INGRESS    = "istio-ingressgateway"
$RELEASE_DASHBOARD  = "kubernetes-dashboard"

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

function Write-Step { param([string]$Message) Write-Host "[STEP] $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Gray }
function Write-Warn { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }
function Write-OK   { param([string]$Message) Write-Host "[OK] $Message" -ForegroundColor Green }

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

function Test-Command {
    param([string]$Command)
    $null = Get-Command $Command -ErrorAction SilentlyContinue
    return $?
}

function Get-ScriptRoot {
    # Compatible with PS 5.1 and PS 7+
    if ($PSScriptRoot) { return $PSScriptRoot }
    return Split-Path -Parent $MyInvocation.MyCommand.Definition
}

function Get-RepoRoot {
    $scriptDir = Get-ScriptRoot
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
    } else {
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
            Exit-WithError "helm command failed: helm $argString" "Check Helm configuration and cluster state."
        }
        return $result
    } else {
        & helm @Arguments
        if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
            Exit-WithError "helm command failed: helm $argString" "Check Helm configuration and cluster state."
        }
    }
}

function Test-NamespaceExists {
    param([string]$Namespace)
    $result = & kubectl get namespace $Namespace --ignore-not-found -o name 2>$null
    return ($LASTEXITCODE -eq 0 -and $null -ne $result -and $result -ne "")
}

function Test-HelmReleaseExists {
    param(
        [string]$ReleaseName,
        [string]$Namespace
    )
    $null = & helm status $ReleaseName -n $Namespace 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Get-InstalledIstioVersion {
    # Try deployment label first
    $version = & kubectl get deployment istiod -n $IstioNamespace -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $version) { return $version }

    # Fallback to Helm chart name parsing
    $json = & helm list -n $IstioNamespace -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $json) {
        try {
            $releases = $json | ConvertFrom-Json -ErrorAction Stop
            $istiod = $releases | Where-Object { $_.name -eq $RELEASE_ISTIOD }
            if ($istiod -and $istiod.chart -match "istiod-(.+)") {
                return $Matches[1]
            }
        } catch {
            # Ignore JSON parse issues; just return null
        }
    }
    return $null
}

function Remove-HelmReleaseIfPresent {
    param(
        [Parameter(Mandatory)][string]$ReleaseName,
        [Parameter(Mandatory)][string]$Namespace
    )

    if (Test-HelmReleaseExists -ReleaseName $ReleaseName -Namespace $Namespace) {
        Write-Step "Uninstalling Helm release '$ReleaseName' in namespace '$Namespace'..."
        Invoke-HelmSafe -Arguments @("uninstall", $ReleaseName, "-n", $Namespace)
        Write-OK "Uninstalled '$ReleaseName'"
    } else {
        Write-Info "Helm release '$ReleaseName' not found in '$Namespace' (nothing to do)"
    }
}

function Remove-NamespaceLabel {
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$LabelKey
    )

    if (-not (Test-NamespaceExists $Namespace)) {
        Write-Info "Namespace '$Namespace' does not exist; skipping label removal '$LabelKey-'"
        return
    }

    # Removing a label uses the "key-" syntax
    Invoke-KubectlSafe -Arguments @(
        "label", "namespace", $Namespace,
        ("{0}-" -f $LabelKey),
        "--overwrite"
    ) -AllowFailure

    Write-OK "Removed label '$LabelKey' from namespace '$Namespace' (if it existed)"
}

function Delete-FromFileIfExists {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$FriendlyName
    )

    if (Test-Path $FilePath) {
        Write-Step "Deleting $FriendlyName from file: $FilePath"
        Invoke-KubectlSafe -Arguments @("delete", "-f", $FilePath, "--ignore-not-found=true") -AllowFailure
        Write-OK "Delete applied for $FriendlyName (file-driven)"
        return $true
    } else {
        Write-Warn "$FriendlyName manifest not found at: $FilePath"
        return $false
    }
}

function BestEffort-DeleteKnownBootstrapResources {
    param([string]$Namespace)

    # Conservative best-effort deletions by likely names.
    # These only delete if exact name exists; otherwise they're no-ops due to --ignore-not-found.
    Write-Warn "Attempting best-effort deletion by likely resource names (because one or more manifest files were missing)."
    Write-Warn "If this doesn't remove everything, restore the repo manifests and re-run this script."

    # Security policies (Istio)
    Invoke-KubectlSafe -Arguments @("delete", "peerauthentication", "peerauthentication-strict", "-n", $Namespace, "--ignore-not-found=true") -AllowFailure
    Invoke-KubectlSafe -Arguments @("delete", "peerauthentication", "default", "-n", $Namespace, "--ignore-not-found=true") -AllowFailure

    Invoke-KubectlSafe -Arguments @("delete", "authorizationpolicy", "default-deny", "-n", $Namespace, "--ignore-not-found=true") -AllowFailure
    Invoke-KubectlSafe -Arguments @("delete", "authorizationpolicy", "allow-intra-namespace", "-n", $Namespace, "--ignore-not-found=true") -AllowFailure
    Invoke-KubectlSafe -Arguments @("delete", "authorizationpolicy", "allow-from-ingressgateway", "-n", $Namespace, "--ignore-not-found=true") -AllowFailure

    # NetworkPolicies
    Invoke-KubectlSafe -Arguments @("delete", "networkpolicy", "default-deny", "-n", $Namespace, "--ignore-not-found=true") -AllowFailure
    Invoke-KubectlSafe -Arguments @("delete", "networkpolicy", "allow-dns", "-n", $Namespace, "--ignore-not-found=true") -AllowFailure
    Invoke-KubectlSafe -Arguments @("delete", "networkpolicy", "allow-internet-egress", "-n", $Namespace, "--ignore-not-found=true") -AllowFailure

    # Ambient waypoint (Gateway API) - common naming patterns
    Invoke-KubectlSafe -Arguments @("delete", "gateway", "waypoint", "-n", $Namespace, "--ignore-not-found=true") -AllowFailure

    Write-OK "Best-effort deletion attempted"
}

function Delete-NamespaceIfRequested {
    param([string]$Namespace)

    if (-not (Test-NamespaceExists $Namespace)) {
        Write-Info "Namespace '$Namespace' not found (nothing to delete)"
        return
    }

    Write-Step "Deleting namespace '$Namespace' (DESTRUCTIVE)..."
    Invoke-KubectlSafe -Arguments @("delete", "namespace", $Namespace, "--ignore-not-found=true") -AllowFailure

    # Waiting for namespace deletion can take time; allow failure if it races.
    Invoke-KubectlSafe -Arguments @("wait", "--for=delete", ("namespace/{0}" -f $Namespace), "--timeout=180s") -AllowFailure
    Write-OK "Namespace deletion requested: '$Namespace'"
}

# ==============================================================================
# PRE-FLIGHT CHECKS
# ==============================================================================

Write-Header "Docker Desktop Kubernetes Teardown (Istio + Policies)"

Write-Step "Checking for kubectl..."
if (-not (Test-Command "kubectl")) {
    Exit-WithError "kubectl not found in PATH." "Install kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/"
}
Write-OK "kubectl found"

Write-Step "Checking for helm..."
if (-not (Test-Command "helm")) {
    Exit-WithError "helm not found in PATH." "Install helm: https://helm.sh/docs/intro/install/ or 'choco install kubernetes-helm'"
}
Write-OK "helm found"

Write-Step "Checking Kubernetes cluster connectivity..."
$clusterInfo = & kubectl cluster-info 2>&1
if ($LASTEXITCODE -ne 0) {
    Exit-WithError "Cannot connect to Kubernetes cluster." "Ensure Docker Desktop is running and Kubernetes is enabled."
}
Write-OK "Kubernetes cluster is reachable"

Write-Step "Checking kubecontext..."
$currentContext = & kubectl config current-context 2>$null
if ($currentContext -ne "docker-desktop") {
    if ($Force) {
        Write-Warn "Current context is '$currentContext', not 'docker-desktop'. Proceeding due to -Force."
        Write-Warn "THIS MAY AFFECT A NON-LOCAL CLUSTER. Use with caution!"
    } else {
        Exit-WithError "Current kubecontext is '$currentContext', expected 'docker-desktop'." @"
Switch context with:
    kubectl config use-context docker-desktop

Or run with -Force to bypass this safety check (NOT RECOMMENDED for remote clusters).
"@
    }
} else {
    Write-OK "kubecontext is docker-desktop"
}

# Safety: Istio version mismatch handling
Write-Step "Checking existing Istio installation/version (safety)..."
$installedIstioVersion = Get-InstalledIstioVersion
if ($installedIstioVersion) {
    Write-Info "Detected Istio version: $installedIstioVersion (expected bootstrap version: $IstioVersion)"
    if ($installedIstioVersion -ne $IstioVersion -and -not $Force) {
        Exit-WithError "Istio version mismatch detected. Refusing teardown without -Force." @"
Installed: $installedIstioVersion
Expected:  $IstioVersion

If this cluster has a different Istio version installed intentionally, re-run with:
    .\teardown-docker-desktop-k8s.ps1 -Force

NOTE: This script uninstalls Istio Helm releases by name; ensure that is desired.
"@
    }
} else {
    Write-Info "Istio not detected (or istiod deployment missing). Teardown will still attempt release cleanup safely."
}

# Destructive flag guard
if ($DeleteNamespaces -and -not $IUnderstandThisDeletesWorkloads) {
    Exit-WithError "-DeleteNamespaces is DESTRUCTIVE and requires -IUnderstandThisDeletesWorkloads." @"
Example:
    .\teardown-docker-desktop-k8s.ps1 -DeleteNamespaces -IUnderstandThisDeletesWorkloads

This will delete workloads in:
- $PlatformNamespace
- $IstioNamespace
- $DashboardNamespace (if present)
"@
}

# ==============================================================================
# PLAN (PRINT BEFORE EXECUTION)
# ==============================================================================

Write-Header "Plan"

Write-Host "Target context:             $currentContext"
Write-Host "Istio namespace:            $IstioNamespace"
Write-Host "Platform namespace:         $PlatformNamespace"
Write-Host "Dashboard namespace:        $DashboardNamespace"
Write-Host "Expected Istio version:     $IstioVersion"
Write-Host ""
Write-Host "RemovePlatformPolicies:     $RemovePlatformPolicies"
Write-Host "RemoveNamespaceLabels:      $RemoveNamespaceLabels"
Write-Host "RemoveIngressGateway:       $RemoveIngressGateway"
Write-Host "RemoveZtunnel:              $RemoveZtunnel"
Write-Host "RemoveDashboard:            $RemoveDashboard"
Write-Host "RemoveGatewayApiCrds:       $RemoveGatewayApiCrds  (CLUSTER-WIDE)"
Write-Host "DeleteNamespaces:           $DeleteNamespaces       (DESTRUCTIVE)"
if ($DeleteNamespaces) {
    Write-Host "IUnderstandThisDeletesWorkloads: $IUnderstandThisDeletesWorkloads" -ForegroundColor Yellow
}
Write-Host ""

if ($RemoveGatewayApiCrds) {
    Write-Warn "Gateway API CRDs removal is cluster-wide and may break other apps/controllers."
}
if ($DeleteNamespaces) {
    Write-Warn "Namespace deletion will delete workloads and all namespaced resources in those namespaces."
}

# ==============================================================================
# PLATFORM POLICIES / WAYPOINT REMOVAL
# ==============================================================================

$missingAnyManifests = $false

if ($RemovePlatformPolicies) {
    Write-Header "Remove Bootstrap-Applied Policies (Platform Namespace)"

    if (-not (Test-NamespaceExists $PlatformNamespace)) {
        Write-Warn "Platform namespace '$PlatformNamespace' does not exist. Skipping file-driven policy deletion."
    } else {
        $repoRoot = Get-RepoRoot

        $securityPath      = Join-Path $repoRoot "k8s/dev/security"
        $networkPolicyPath = Join-Path $repoRoot "k8s/dev/networkpolicies"
        $ambientPath       = Join-Path $repoRoot "k8s/dev/ambient"

        # Waypoint first (ambient)
        $waypointFile = Join-Path $ambientPath "waypoint-platform-dev.yaml"
        $ok = Delete-FromFileIfExists -FilePath $waypointFile -FriendlyName "Waypoint (Ambient)"
        if (-not $ok) { $missingAnyManifests = $true }

        # Security policies
        $files = @(
            @{ Path = (Join-Path $securityPath "peerauthentication-strict.yaml"); Friendly = "PeerAuthentication (mTLS STRICT)" },
            @{ Path = (Join-Path $securityPath "authz-default-deny.yaml");          Friendly = "AuthorizationPolicy (default-deny)" },
            @{ Path = (Join-Path $securityPath "authz-allow-intra-namespace.yaml"); Friendly = "AuthorizationPolicy (allow intra-namespace)" },
            @{ Path = (Join-Path $securityPath "authz-allow-from-ingressgateway.yaml"); Friendly = "AuthorizationPolicy (allow from ingress gateway)" } # optional usage
        )

        foreach ($f in $files) {
            $ok = Delete-FromFileIfExists -FilePath $f.Path -FriendlyName $f.Friendly
            if (-not $ok) { $missingAnyManifests = $true }
        }

        # NetworkPolicies
        $npFiles = @(
            @{ Path = (Join-Path $networkPolicyPath "np-default-deny.yaml");         Friendly = "NetworkPolicy (default-deny)" },
            @{ Path = (Join-Path $networkPolicyPath "np-allow-dns.yaml");            Friendly = "NetworkPolicy (allow DNS)" },
            @{ Path = (Join-Path $networkPolicyPath "np-allow-internet-egress.yaml");Friendly = "NetworkPolicy (allow internet egress)" } # optional usage
        )

        foreach ($f in $npFiles) {
            $ok = Delete-FromFileIfExists -FilePath $f.Path -FriendlyName $f.Friendly
            if (-not $ok) { $missingAnyManifests = $true }
        }

        if ($missingAnyManifests) {
            Write-Warn "One or more manifest files were missing. This usually means you're not running from the repo, or manifests were moved/deleted."
            Write-Host "Remediation:" -ForegroundColor Yellow
            Write-Host "  - Run this script from the repo after restoring k8s/dev/** manifests." -ForegroundColor Yellow
            Write-Host "  - Repo root should contain: k8s/dev/security, k8s/dev/networkpolicies, k8s/dev/ambient" -ForegroundColor Yellow

            BestEffort-DeleteKnownBootstrapResources -Namespace $PlatformNamespace
        } else {
            Write-OK "Policy/waypoint deletion applied via repo manifests"
        }
    }
} else {
    Write-Info "Skipping platform policy deletion (RemovePlatformPolicies=false)"
}

# ==============================================================================
# NAMESPACE LABEL REMOVAL
# ==============================================================================

if ($RemoveNamespaceLabels) {
    Write-Header "Remove Platform Namespace Enrollment Labels"
    Remove-NamespaceLabel -Namespace $PlatformNamespace -LabelKey "istio-injection"
    Remove-NamespaceLabel -Namespace $PlatformNamespace -LabelKey "istio.io/dataplane-mode"
} else {
    Write-Info "Skipping namespace label removal (RemoveNamespaceLabels=false)"
}

# ==============================================================================
# ISTIO HELM RELEASE REMOVAL
# ==============================================================================

Write-Header "Remove Istio Helm Releases"

# Remove gateway and ztunnel first (depend on control plane)
if ($RemoveIngressGateway) {
    Remove-HelmReleaseIfPresent -ReleaseName $RELEASE_INGRESS -Namespace $IstioNamespace
} else {
    Write-Info "Skipping ingress gateway uninstall (RemoveIngressGateway=false)"
}

if ($RemoveZtunnel) {
    Remove-HelmReleaseIfPresent -ReleaseName $RELEASE_ZTUNNEL -Namespace $IstioNamespace
} else {
    Write-Info "Skipping ztunnel uninstall (RemoveZtunnel=false)"
}

# Then control plane and base
Remove-HelmReleaseIfPresent -ReleaseName $RELEASE_ISTIOD -Namespace $IstioNamespace
Remove-HelmReleaseIfPresent -ReleaseName $RELEASE_ISTIO_BASE -Namespace $IstioNamespace

# ==============================================================================
# DASHBOARD REMOVAL
# ==============================================================================

if ($RemoveDashboard) {
    Write-Header "Remove Kubernetes Dashboard"
    Remove-HelmReleaseIfPresent -ReleaseName $RELEASE_DASHBOARD -Namespace $DashboardNamespace
} else {
    Write-Info "Skipping dashboard uninstall (RemoveDashboard=false)"
}

# ==============================================================================
# GATEWAY API CRD REMOVAL (OPT-IN, CLUSTER-WIDE)
# ==============================================================================

if ($RemoveGatewayApiCrds) {
    Write-Header "Remove Gateway API CRDs (CLUSTER-WIDE)"
    Write-Warn "This removes Gateway API CRDs installed from pinned URL (bootstrap)."
    Write-Warn "If other apps/controllers depend on Gateway API, they may break."

    Write-Step "Deleting Gateway API CRDs from: $GATEWAY_API_CRD_URL"
    Invoke-KubectlSafe -Arguments @("delete", "-f", $GATEWAY_API_CRD_URL, "--ignore-not-found=true") -AllowFailure
    Write-OK "Gateway API CRD delete applied (cluster-wide)"
} else {
    Write-Info "Skipping Gateway API CRD removal (RemoveGatewayApiCrds=false)"
}

# ==============================================================================
# NAMESPACE DELETION (OPT-IN, DESTRUCTIVE)
# ==============================================================================

if ($DeleteNamespaces) {
    Write-Header "Delete Namespaces (DESTRUCTIVE)"
    Write-Warn "Deleting namespaces will delete workloads and all namespaced resources within them."

    Delete-NamespaceIfRequested -Namespace $PlatformNamespace
    Delete-NamespaceIfRequested -Namespace $IstioNamespace
    Delete-NamespaceIfRequested -Namespace $DashboardNamespace
} else {
    Write-Info "Skipping namespace deletion (DeleteNamespaces=false)"
}

# ==============================================================================
# VERIFICATION
# ==============================================================================

Write-Header "Verification"

Write-Step "Namespaces:"
Invoke-KubectlSafe -Arguments @("get", "ns") -AllowFailure

Write-Host ""
Write-Step "Helm releases (all namespaces):"
Invoke-HelmSafe -Arguments @("list", "-A") -AllowFailure

Write-Host ""
Write-Step "Gateway API CRDs (if present):"
# Use kubectl + jsonpath-ish listing; tolerate absence.
Invoke-KubectlSafe -Arguments @("get", "crd") -AllowFailure | Out-Null
# Better: attempt to list specific known CRDs; no-op if missing.
Invoke-KubectlSafe -Arguments @("get", "crd", "gateways.gateway.networking.k8s.io", "--ignore-not-found") -AllowFailure
Invoke-KubectlSafe -Arguments @("get", "crd", "httproutes.gateway.networking.k8s.io", "--ignore-not-found") -AllowFailure

Write-Host ""
Write-Step "Platform namespace labels (if namespace exists):"
if (Test-NamespaceExists $PlatformNamespace) {
    Invoke-KubectlSafe -Arguments @("get", "namespace", $PlatformNamespace, "--show-labels") -AllowFailure
} else {
    Write-Info "Namespace '$PlatformNamespace' not present"
}

Write-Host ""
Write-Step "Bootstrap policy resource kinds in platform namespace (tolerate missing):"
if (Test-NamespaceExists $PlatformNamespace) {
    Invoke-KubectlSafe -Arguments @("get", "peerauthentication", "-n", $PlatformNamespace) -AllowFailure
    Invoke-KubectlSafe -Arguments @("get", "authorizationpolicy", "-n", $PlatformNamespace) -AllowFailure
    Invoke-KubectlSafe -Arguments @("get", "networkpolicy", "-n", $PlatformNamespace) -AllowFailure
    Invoke-KubectlSafe -Arguments @("get", "gateway", "-n", $PlatformNamespace) -AllowFailure
} else {
    Write-Info "Namespace '$PlatformNamespace' not present"
}

# ==============================================================================
# SUMMARY / NEXT STEPS
# ==============================================================================

Write-Header "Teardown Complete"

Write-Host @"
- If you want a truly pristine cluster, Docker Desktop can reset Kubernetes:
  Docker Desktop > Settings > Kubernetes > Reset Kubernetes Cluster

Common checks:
  kubectl get ns
  helm list -A

If you removed Istio, workloads previously enrolled may need redeploy/restart to clear sidecars.
"@ -ForegroundColor Green

exit 0
# ============================================================================
# Configure la partie Exchange (post-infra) en app-only headless :
#   - groupe de scope + membre
#   - Application Access Policy (RestrictAccess sur la MI)
#   - transport rule de détection + BCC
# Appelé par deploy.yml (job optionnel). Idempotent.
#
# Auth EXO app-only par CERTIFICAT (seule exception "secret" : EXO_CERT_B64).
# Variables d'env attendues : EXO_APP_ID, EXO_ORG, EXO_CERT_B64 (pfx base64), MI_APP_ID.
# ============================================================================
param(
  [Parameter(Mandatory)][string]$SvcMailbox,
  [Parameter(Mandatory)][string]$ScopeGroupMail,
  [string]$SocMailbox = ""
)
$ErrorActionPreference = "Stop"

# --- Auth app-only via certificat ---
$certBytes = [Convert]::FromBase64String($env:EXO_CERT_B64)
$certPath  = Join-Path $env:RUNNER_TEMP "exo.pfx"
[IO.File]::WriteAllBytes($certPath, $certBytes)
$certPwd = if ($env:EXO_CERT_PWD) { $env:EXO_CERT_PWD } else { "" }
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certPath, $certPwd, 'Exportable,PersistKeySet')

Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline -AppId $env:EXO_APP_ID -Organization $env:EXO_ORG -Certificate $cert -ShowBanner:$false

$miAppId = $env:MI_APP_ID

# Retry : après création boîte/groupe, la réplication annuaire Exchange peut lagger
# (Get-ApplicationAccessPolicy renvoie alors "object ...\* couldn't be found").
function Invoke-WithRetry([scriptblock]$Action, [int]$Max = 8, [int]$DelaySec = 30) {
  for ($i = 1; $i -le $Max; $i++) {
    try { return & $Action }
    catch {
      Write-Host "  tentative $i/$Max : $($_.Exception.Message)"
      if ($i -eq $Max) { throw }
      Start-Sleep $DelaySec
    }
  }
}

# --- Groupe de scope (créer si absent, garantir le membre) ---
if (-not (Get-DistributionGroup -Identity $ScopeGroupMail -ErrorAction SilentlyContinue)) {
  New-DistributionGroup -Name ($ScopeGroupMail.Split('@')[0]) -Type Security `
    -PrimarySmtpAddress $ScopeGroupMail -Members $SvcMailbox | Out-Null
  Write-Host "Groupe de scope créé."
} elseif (-not (Get-DistributionGroupMember -Identity $ScopeGroupMail | Where-Object { $_.PrimarySmtpAddress -eq $SvcMailbox })) {
  Add-DistributionGroupMember -Identity $ScopeGroupMail -Member $SvcMailbox
  Write-Host "Boîte ajoutée au groupe de scope."
}

# --- Application Access Policy (idempotent, avec retry sur réplication annuaire) ---
$policyExists = Invoke-WithRetry { @(Get-ApplicationAccessPolicy | Where-Object { $_.AppId -eq $miAppId }).Count -gt 0 }
if (-not $policyExists) {
  Invoke-WithRetry { New-ApplicationAccessPolicy -AppId $miAppId -PolicyScopeGroupId $ScopeGroupMail -AccessRight RestrictAccess -Description "AuthFail MI mail scope" | Out-Null }
  Write-Host "Application Access Policy créée (propagation ~30 min)."
} else {
  Write-Host "Application Access Policy déjà présente."
}

# --- Transport rule (idempotent) ---
if (-not (Get-TransportRule -Identity "SEC-AuthFail-Detect-Trigger" -ErrorAction SilentlyContinue)) {
  $params = @{
    Name                        = "SEC-AuthFail-Detect-Trigger"
    Priority                    = 1
    FromScope                   = "NotInOrganization"
    SentToScope                 = "InOrganization"
    HeaderMatchesMessageHeader  = "Authentication-Results"
    HeaderMatchesPatterns       = @("spf=fail", "dkim=fail")
    BlindCopyTo                 = $SvcMailbox
    SetHeaderName               = "X-SO-AuthFail"
    SetHeaderValue              = "True"
    ApplyHtmlDisclaimerLocation = "Prepend"
    ApplyHtmlDisclaimerText     = "<div style='border:2px solid #c00;padding:8px;background:#fff3f3'>Expediteur non authentifie (SPF/DKIM). Verifiez avant de repondre, cliquer ou ouvrir une piece jointe.</div>"
    ApplyHtmlDisclaimerFallbackAction = "Wrap"
  }
  if ($SocMailbox) {
    $params.GenerateIncidentReport = $SocMailbox
    $params.IncidentReportContent  = @("Sender", "Recipients", "Subject", "Headers")
  }
  Invoke-WithRetry { New-TransportRule @params | Out-Null }
  Write-Host "Transport rule créée."
} else {
  Write-Host "Transport rule déjà présente."
}

Disconnect-ExchangeOnline -Confirm:$false
Write-Host "Configuration Exchange terminée."

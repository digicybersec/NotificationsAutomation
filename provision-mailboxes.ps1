# ============================================================================
# Provisionne les boîtes nécessaires (app-only headless), AVANT le déploiement infra.
# Appelé par deploy.yml (étape optionnelle createMailboxes). Idempotent.
#
# Auth EXO app-only par CERTIFICAT. Env : EXO_APP_ID, EXO_ORG, EXO_CERT_B64.
# ============================================================================
param(
  [Parameter(Mandatory)][string]$SvcMailbox,
  [string]$SendMailbox = ""
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

function Ensure-SharedMailbox([string]$addr) {
  if (-not (Get-Mailbox -Identity $addr -ErrorAction SilentlyContinue)) {
    New-Mailbox -Shared -Name ($addr.Split('@')[0]) -PrimarySmtpAddress $addr | Out-Null
    Write-Host "Boîte partagée créée : $addr"
  } else {
    Write-Host "Boîte déjà présente : $addr"
  }
}

Ensure-SharedMailbox $SvcMailbox
if ($SendMailbox -and $SendMailbox -ne $SvcMailbox) {
  Ensure-SharedMailbox $SendMailbox
}

Disconnect-ExchangeOnline -Confirm:$false
Write-Host "Provisioning des boîtes terminé."
# Note : une boîte partagée fraîchement créée peut mettre quelques minutes à être
# pleinement adressable (appartenance au groupe, accès Graph). Le déploiement infra
# qui suit + le smoke test absorbent ce délai.

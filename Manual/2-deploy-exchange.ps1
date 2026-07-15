# ============================================================================
# ETAPE 2/2 — Exchange (boite partagee, groupe de scope, Application Access
# Policy, regle de detection). Connexion INTERACTIVE — aucun certificat requis.
# Recupere automatiquement l'ID de la Managed Identity cree a l'etape 1.
# ============================================================================
$ErrorActionPreference = "Stop"
Write-Host ""
Write-Host "=== AuthFail Notification - Deploiement Exchange (2/2) ===" -ForegroundColor Cyan
Write-Host ""

# --- Lire les infos de l'etape 1 ---
$infoPath = Join-Path $PSScriptRoot "deployment-info.json"
if (-not (Test-Path $infoPath)) {
  Write-Host "deployment-info.json introuvable." -ForegroundColor Red
  Write-Host "Lance d'abord l'etape 1 :  .\1-deploy-azure.ps1" -ForegroundColor Yellow
  exit 1
}
$info = Get-Content $infoPath -Raw | ConvertFrom-Json
Write-Host "Configuration recuperee de l'etape 1 :" -ForegroundColor Yellow
Write-Host ("  Boite   : {0}" -f $info.svcMailbox)
Write-Host ("  Groupe  : {0}" -f $info.scopeGroupMail)
Write-Host ("  MI AppId: {0}" -f $info.miAppId)
Write-Host ""

# --- Module + connexion Exchange (interactive) ---
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
  Write-Host "Installation du module ExchangeOnlineManagement..." -ForegroundColor Yellow
  Install-Module ExchangeOnlineManagement -Force -Scope CurrentUser -AllowClobber
}
Import-Module ExchangeOnlineManagement
Write-Host "Connexion a Exchange Online (une fenetre de login va s'ouvrir)..." -ForegroundColor Yellow
Connect-ExchangeOnline -ShowBanner:$false

# --- 1. Boite partagee ---
if (-not (Get-Mailbox -Identity $info.svcMailbox -ErrorAction SilentlyContinue)) {
  New-Mailbox -Shared -Name ($info.svcMailbox.Split('@')[0]) -PrimarySmtpAddress $info.svcMailbox | Out-Null
  Write-Host "OK - Boite partagee creee." -ForegroundColor Green
} else { Write-Host "Boite partagee deja presente." }

# --- 2. Groupe de scope + membre ---
if (-not (Get-DistributionGroup -Identity $info.scopeGroupMail -ErrorAction SilentlyContinue)) {
  New-DistributionGroup -Name ($info.scopeGroupMail.Split('@')[0]) -Type Security `
    -PrimarySmtpAddress $info.scopeGroupMail -Members $info.svcMailbox | Out-Null
  Write-Host "OK - Groupe de scope cree." -ForegroundColor Green
} elseif (-not (Get-DistributionGroupMember -Identity $info.scopeGroupMail | Where-Object { $_.PrimarySmtpAddress -eq $info.svcMailbox })) {
  Add-DistributionGroupMember -Identity $info.scopeGroupMail -Member $info.svcMailbox
  Write-Host "OK - Boite ajoutee au groupe." -ForegroundColor Green
} else { Write-Host "Groupe de scope deja pret." }

# --- 3. Application Access Policy ---
# Note : Get-ApplicationAccessPolicy LEVE une erreur quand il n'existe AUCUNE
# policy dans le tenant -> on catch et on considere qu'il faut la creer.
$policyExists = $false
try {
  $policyExists = @(Get-ApplicationAccessPolicy -ErrorAction Stop | Where-Object { $_.AppId -eq $info.miAppId }).Count -gt 0
} catch { }
if (-not $policyExists) {
  New-ApplicationAccessPolicy -AppId $info.miAppId -PolicyScopeGroupId $info.scopeGroupMail `
    -AccessRight RestrictAccess -Description "AuthFail MI mail scope" | Out-Null
  Write-Host "OK - Application Access Policy creee (propagation ~30 min)." -ForegroundColor Green
} else { Write-Host "Application Access Policy deja presente." }

# --- 4. Regle de transport (detection spf/dkim fail + BCC vers la boite) ---
if (-not (Get-TransportRule -Identity "SEC-AuthFail-Detect-Trigger" -ErrorAction SilentlyContinue)) {
  New-TransportRule -Name "SEC-AuthFail-Detect-Trigger" -Priority 1 `
    -FromScope NotInOrganization -SentToScope InOrganization `
    -HeaderMatchesMessageHeader "Authentication-Results" -HeaderMatchesPatterns "spf=fail","dkim=fail" `
    -BlindCopyTo $info.svcMailbox -SetHeaderName "X-SO-AuthFail" -SetHeaderValue "True" `
    -ApplyHtmlDisclaimerLocation Prepend `
    -ApplyHtmlDisclaimerText "<div style='border:2px solid #c00;padding:8px;background:#fff3f3'>Expediteur non authentifie (SPF/DKIM). Verifiez avant de repondre, cliquer ou ouvrir une piece jointe.</div>" `
    -ApplyHtmlDisclaimerFallbackAction Wrap | Out-Null
  Write-Host "OK - Regle de detection creee." -ForegroundColor Green
} else { Write-Host "Regle de detection deja presente." }

Disconnect-ExchangeOnline -Confirm:$false
Write-Host ""
Write-Host "TERMINE ! La solution est deployee." -ForegroundColor Green
Write-Host "La policy peut mettre ~30-60 min a se propager avant que les notifications partent." -ForegroundColor Yellow

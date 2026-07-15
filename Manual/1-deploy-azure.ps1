# ============================================================================
# ETAPE 1/2 — Ressources Azure (Logic App, storage, permissions Graph)
# Deploiement manuel, interactif. Suis simplement les questions a l'ecran.
# A la fin, l'ID de la Managed Identity est sauvegarde pour l'etape 2.
# ============================================================================
$ErrorActionPreference = "Stop"
Write-Host ""
Write-Host "=== AuthFail Notification - Deploiement Azure (1/2) ===" -ForegroundColor Cyan
Write-Host ""

# --- Verifier az CLI ---
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  Write-Host "Azure CLI n'est pas installe. Installe-le puis relance :" -ForegroundColor Red
  Write-Host "  winget install -e --id Microsoft.AzureCLI" -ForegroundColor Yellow
  exit 1
}

# --- Verifier le template (main.bicep + workflow.json, dans ce meme dossier) ---
$bicep    = Join-Path $PSScriptRoot "main.bicep"
$workflow = Join-Path $PSScriptRoot "workflow.json"
if (-not (Test-Path $bicep) -or -not (Test-Path $workflow)) {
  Write-Host "main.bicep et/ou workflow.json manquant(s) dans le dossier Manual." -ForegroundColor Red
  Write-Host "Ces 2 fichiers doivent etre a cote des scripts." -ForegroundColor Yellow
  exit 1
}

# --- Connexion Azure ---
$acct = az account show 2>$null | ConvertFrom-Json
if (-not $acct) { Write-Host "Connexion a Azure (une fenetre va s'ouvrir)..." -ForegroundColor Yellow; az login | Out-Null }

# --- Choix de la souscription (menu) ---
Write-Host "Souscriptions disponibles :" -ForegroundColor Yellow
$subs = az account list --query "[].{Name:name, Id:id}" -o json | ConvertFrom-Json
if ($subs -isnot [array]) { $subs = @($subs) }
for ($i = 0; $i -lt $subs.Count; $i++) {
  Write-Host ("  [{0}] {1}   ({2})" -f $i, $subs[$i].Name, $subs[$i].Id)
}
$sel = Read-Host "`nNumero de la souscription a utiliser"
$sub = $subs[[int]$sel]
az account set --subscription $sub.Id
Write-Host ("-> Souscription : {0}" -f $sub.Name) -ForegroundColor Green
Write-Host ""

# --- Parametres (valeurs par defaut entre crochets) ---
$rg     = Read-Host "Resource group [rg-authfail]";              if (-not $rg)     { $rg = "rg-authfail" }
$loc    = Read-Host "Region Azure [westeurope]";                 if (-not $loc)    { $loc = "westeurope" }
$prefix = Read-Host "Prefixe des ressources [authfail]";         if (-not $prefix) { $prefix = "authfail" }
$svc    = Read-Host "Adresse de la boite de service (ex: svc-authfail@client.com)"
while ($svc -notmatch "^[^@\s]+@[^@\s]+\.[^@\s]+$") { $svc = Read-Host "Adresse invalide. Reessaie (ex: svc-authfail@client.com)" }
$selfDom = ($svc -split "@")[1]
$cap    = Read-Host "Plafond notifications/heure [50]";          if (-not $cap)    { $cap = "50" }

# --- Deploiement de l'infrastructure ---
Write-Host "`nDeploiement de l'infrastructure Azure... (2-3 min)" -ForegroundColor Yellow
az group create -n $rg -l $loc | Out-Null
$principalId = az deployment group create -g $rg -f $bicep `
  -p prefix=$prefix svcMailbox=$svc sendMailbox=$svc selfDomain=$selfDom hourlyCap=$cap `
  --query "properties.outputs.logicAppPrincipalId.value" -o tsv
if (-not $principalId) { Write-Host "Echec du deploiement." -ForegroundColor Red; exit 1 }

# --- AppId de la Managed Identity (petite attente le temps que le SP soit visible) ---
Start-Sleep 15
$miAppId = az ad sp show --id $principalId --query appId -o tsv

# --- Permissions Graph Mail.* sur la Managed Identity ---
Write-Host "Attribution des permissions Graph a la Managed Identity..." -ForegroundColor Yellow
$graph = az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv
$roleFile = Join-Path $env:TEMP "authfail-role.json"
foreach ($role in "810c84a8-4a9e-49e6-bf7d-12d183f40d01","e2a3a72e-5f79-4c64-b1b1-878b674786c9","b633e1c5-b582-4048-a93e-9f11b44c7e96") {
  @{ principalId = $principalId; resourceId = $graph; appRoleId = $role } | ConvertTo-Json -Compress | Set-Content $roleFile -Encoding ascii
  az rest --method POST --url "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" `
    --headers "Content-Type=application/json" --body "@$roleFile" 2>$null | Out-Null
}

# --- Sauvegarde des infos pour l'etape 2 ---
$scopeGroup = "authfail-notify-scope@$selfDom"
@{
  resourceGroup = $rg; location = $loc; prefix = $prefix
  svcMailbox = $svc; selfDomain = $selfDom; scopeGroupMail = $scopeGroup
  miAppId = $miAppId; miPrincipalId = $principalId
} | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot "deployment-info.json") -Encoding ascii

Write-Host ""
Write-Host "OK - Ressources Azure deployees." -ForegroundColor Green
Write-Host ("   Managed Identity AppId : {0}" -f $miAppId)
Write-Host ""
Write-Host "==> ETAPE SUIVANTE : lance maintenant  .\2-deploy-exchange.ps1" -ForegroundColor Cyan

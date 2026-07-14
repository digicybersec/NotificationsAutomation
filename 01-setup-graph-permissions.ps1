# ============================================================================
# À exécuter APRÈS le déploiement Bicep.
# Assigne les permissions Graph app-only à la Managed Identity du Logic App,
# puis restreint Mail.* à la seule boîte de service (Application Access Policy).
#
# Prérequis : Microsoft.Graph PowerShell + ExchangeOnlineManagement
#   Install-Module Microsoft.Graph -Scope CurrentUser
#   Install-Module ExchangeOnlineManagement -Scope CurrentUser
# ============================================================================

param(
  [Parameter(Mandatory)] [string]$LogicAppPrincipalId,   # output Bicep: logicAppPrincipalId
  [Parameter(Mandatory)] [string]$SvcMailbox,            # svc-authfail@tondomaine.com
  [Parameter(Mandatory)] [string]$ScopeGroupMail         # groupe de sécu mail-enabled (créé plus bas)
)

# --- 1. Permissions Graph app-only sur la Managed Identity -------------------
Connect-MgGraph -Scopes "Application.ReadWrite.All","AppRoleAssignment.ReadWrite.All","Directory.ReadWrite.All"

$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

# Permissions APPLICATION nécessaires
$roles = @('Mail.Read','Mail.Send','Mail.ReadWrite')

foreach ($r in $roles) {
  $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq $r -and $_.AllowedMemberTypes -contains 'Application' }
  New-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $LogicAppPrincipalId `
    -PrincipalId       $LogicAppPrincipalId `
    -ResourceId        $graphSp.Id `
    -AppRoleId         $appRole.Id
  Write-Host "Assigné : $r"
}

# --- 2. Restreindre Mail.* à la seule boîte de service -----------------------
# La MI a un AppId (client id) distinct de son ObjectId. On le récupère :
$miSp = Get-MgServicePrincipal -ServicePrincipalId $LogicAppPrincipalId
$miAppId = $miSp.AppId

Connect-ExchangeOnline

# Groupe de sécu mail-enabled contenant UNIQUEMENT la/les boîte(s) autorisées.
# (À créer une fois si absent — décommenter :)
New-DistributionGroup -Name "AuthFail-Notify-Scope" -Type Security -PrimarySmtpAddress $ScopeGroupMail -Members $SvcMailbox

New-ApplicationAccessPolicy `
  -AppId $miAppId `
  -PolicyScopeGroupId $ScopeGroupMail `
  -AccessRight RestrictAccess `
  -Description "Limite les permissions Mail.* de la MI a la boite AuthFail"

Write-Host "`nApplication Access Policy créée."
Write-Host "⚠️ Propagation jusqu'à ~30 min. Tester ensuite avec Test-ApplicationAccessPolicy."
# Test-ApplicationAccessPolicy -Identity $SvcMailbox -AppId $miAppId

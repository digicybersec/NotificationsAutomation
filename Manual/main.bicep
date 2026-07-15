// ============================================================================
// AuthFail Sender Notification — Option B (Logic Apps + Graph app-only)
// Déploie : Storage (2 tables) + Logic App Consumption (Managed Identity)
//           + Log Analytics + diagnostic + role assignment Table.
// Auth Graph = app-only via Managed Identity (permissions assignées par le
// script 01-setup-graph-permissions.ps1 APRÈS ce déploiement).
// ============================================================================

@description('Nom court du projet, sert de préfixe aux ressources.')
param prefix string = 'authfail'

@description('Boîte de service qui reçoit la copie BCC (lecture + mark read).')
param svcMailbox string // ex: svc-authfail@tondomaine.com

@description('Boîte depuis laquelle part la notification (souvent = svcMailbox).')
param sendMailbox string = svcMailbox

@description('Domaine de tes boîtes internes, pour couper les boucles.')
param selfDomain string // ex: tondomaine.com

@description('Plafond de notifications par heure (coupe-circuit anti-backscatter). Au-dela, on enregistre mais on n\'envoie plus.')
param hourlyCap int = 50

param location string = resourceGroup().location

var storageName = toLower('${prefix}${uniqueString(resourceGroup().id)}')
var logicAppName = '${prefix}-notify-logic'
var lawName = '${prefix}-law'

// Storage Table Data Contributor (role well-known ID)
var tableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'

// ---------------------------------------------------------------------------
// Storage + tables
// ---------------------------------------------------------------------------
resource sa 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
  }
}

resource tableSvc 'Microsoft.Storage/storageAccounts/tableServices@2023-01-01' = {
  parent: sa
  name: 'default'
}

resource allowlistTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-01-01' = {
  parent: tableSvc
  name: 'Allowlist'
}

resource notifylogTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-01-01' = {
  parent: tableSvc
  name: 'NotifyLog'
}

// Denylist = exceptions (domaines à NE PAS notifier). Curée à la main.
resource denylistTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-01-01' = {
  parent: tableSvc
  name: 'Denylist'
}

// Counters = coupe-circuit horaire (1 entité par bucket yyyyMMddHH).
resource countersTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-01-01' = {
  parent: tableSvc
  name: 'Counters'
}

// ---------------------------------------------------------------------------
// Log Analytics (monitoring / argument presta)
// ---------------------------------------------------------------------------
resource law 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: lawName
  location: location
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 90 }
}

// ---------------------------------------------------------------------------
// Logic App (Consumption) + workflow injecté depuis workflow.json
// ---------------------------------------------------------------------------
var defText = loadTextContent('workflow.json')
var defInjected = replace(replace(replace(replace(replace(
  defText,
  '__SVC_MAILBOX__', svcMailbox),
  '__SEND_MAILBOX__', sendMailbox),
  '__STORAGE__', storageName),
  '__SELF_DOMAIN__', selfDomain),
  '__HOURLY_CAP__', string(hourlyCap))

resource logic 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    state: 'Enabled'
    definition: json(defInjected)
    parameters: {}
  }
}

resource logicDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-law'
  scope: logic
  properties: {
    workspaceId: law.id
    logs: [ { categoryGroup: 'allLogs', enabled: true } ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

// ---------------------------------------------------------------------------
// RBAC : la Managed Identity du Logic App peut lire/écrire les tables
// ---------------------------------------------------------------------------
resource tableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sa.id, logic.id, tableDataContributorRoleId)
  scope: sa
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', tableDataContributorRoleId)
    principalId: logic.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Outputs utiles pour le script Graph
// ---------------------------------------------------------------------------
output logicAppPrincipalId string = logic.identity.principalId
output logicAppName string = logicAppName
output storageAccount string = storageName

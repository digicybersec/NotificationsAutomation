# Onboarding TURNKEY d'un tenant neuf (avec certificat EXO)

Objectif : déployer **de zéro à fonctionnel** sur un nouveau tenant, en laissant le pipeline
créer aussi les **boîtes** + l'**Application Access Policy** + la **transport rule**
(`createMailboxes=true`, `configureExchange=true`).

**Pré-requis :** être **Global Admin** du tenant client + **Owner** d'une souscription Azure
dans ce tenant. Choisis un **nom d'environnement** (ex. `clientdemo`) — il doit être identique
partout. Décide aussi les adresses : `svcMailbox`, `scopeGroupMail`, le domaine (`selfDomain`).

> 🔐 **Sécurité** : le `.pfx` (base64) et son mot de passe sont des **secrets** (clé privée).
> Tu les mets **toi-même** dans GitHub (§C). Ne les colle jamais dans un chat.

---

## Partie A — App OIDC (déployeur) — déjà éprouvée sur digicybersec

Dans PowerShell, **connecté au NOUVEAU tenant** :
```powershell
az login
az account show --query "{tenant:tenantId, sub:id, name:name}" -o table   # vérifie le bon tenant

$ENV_NAME = "clientdemo"                 # <- ton nom d'environnement
$REPO     = "digicybersec/NotificationsAutomation"

$APP_ID = az ad app create --display-name "github-authfail-deployer" --query appId -o tsv
az ad sp create --id $APP_ID | Out-Null
$SP  = az ad sp show --id $APP_ID --query id -o tsv
$SUB = az account show --query id -o tsv
$TEN = az account show --query tenantId -o tsv

# Federated credential (repo + environment)
@{ name="gh-$ENV_NAME"; issuer="https://token.actions.githubusercontent.com";
   subject="repo:$REPO:environment:$ENV_NAME"; audiences=@("api://AzureADTokenExchange") } |
  ConvertTo-Json -Compress | Set-Content fc.json -Encoding ascii
az ad app federated-credential create --id $APP_ID --parameters '@fc.json' | Out-Null

# Owner sur la souscription
az role assignment create --assignee $APP_ID --role Owner --scope "/subscriptions/$SUB" | Out-Null

# Graph : les 2 rôles (méthode directe fiable)
$GRAPH = az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv
foreach ($r in "06b708a9-e830-4db3-a914-8e69da51d44f","9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30") {
  @{principalId=$SP; resourceId=$GRAPH; appRoleId=$r} | ConvertTo-Json -Compress | Set-Content r.json -Encoding ascii
  az rest --method POST --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP/appRoleAssignments" `
    --headers "Content-Type=application/json" --body '@r.json' | Out-Null
}
"APP_ID=$APP_ID ; TENANT=$TEN ; SUB=$SUB"
```

## Partie B — Certificat + Exchange app-only (LA nouveauté)

On réutilise la **même app** pour Exchange (plus simple).
```powershell
# 1. Certificat auto-signé (2 ans) : .cer (public, pour l'app) + .pfx (privé, pour le secret)
$CERT_PWD = "ChangeMe-Temp-123!"
$cert = New-SelfSignedCertificate -Subject "CN=authfail-exo" -CertStoreLocation "Cert:\CurrentUser\My" `
          -KeyExportPolicy Exportable -KeySpec Signature -NotAfter (Get-Date).AddYears(2)
Export-Certificate -Cert $cert -FilePath authfail-exo.cer | Out-Null
Export-PfxCertificate -Cert $cert -FilePath authfail-exo.pfx `
  -Password (ConvertTo-SecureString $CERT_PWD -AsPlainText -Force) | Out-Null

# 2. Uploader le certificat PUBLIC sur l'app (garde les creds existants)
az ad app credential reset --id $APP_ID --cert "@authfail-exo.cer" --append | Out-Null
#   -> vérifie : az ad app credential list --id $APP_ID -o table

# 3. Permission Exchange.ManageAsApp (assignation directe fiable)
$EXO = az ad sp show --id 00000002-0000-0ff1-ce00-000000000000 --query id -o tsv 2>$null
if (-not $EXO) { az ad sp create --id 00000002-0000-0ff1-ce00-000000000000 | Out-Null; $EXO = az ad sp show --id 00000002-0000-0ff1-ce00-000000000000 --query id -o tsv }
@{principalId=$SP; resourceId=$EXO; appRoleId="dc50a0fb-09a3-484d-be87-e023b12c6440"} |
  ConvertTo-Json -Compress | Set-Content e.json -Encoding ascii
az rest --method POST --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP/appRoleAssignments" `
  --headers "Content-Type=application/json" --body '@e.json' | Out-Null

# 4. Rôle Entra "Exchange Administrator" sur le SP (requis pour New-Mailbox / policy / rule)
@{principalId=$SP; roleDefinitionId="29232cdf-9323-42fd-ade2-1d097af3e4de"; directoryScopeId="/"} |
  ConvertTo-Json -Compress | Set-Content role.json -Encoding ascii
az rest --method POST --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments" `
  --headers "Content-Type=application/json" --body '@role.json' | Out-Null

# 5. Base64 du .pfx = valeur du secret EXO_CERT_B64
[Convert]::ToBase64String([IO.File]::ReadAllBytes("authfail-exo.pfx")) | Set-Content authfail-exo.b64 -Encoding ascii
"EXO_CERT_PWD = $CERT_PWD"
"EXO_CERT_B64 = (contenu de authfail-exo.b64)"
```

## Partie C — GitHub (secrets par TOI, variables par moi)

**Toi** — dans le repo : Settings → Environments → `clientdemo` → **Secrets** :
- `EXO_CERT_B64` = contenu du fichier `authfail-exo.b64`
- `EXO_CERT_PWD` = ton `$CERT_PWD`

(ou en gh CLI :)
```bash
gh secret set EXO_CERT_B64 --env clientdemo --repo digicybersec/NotificationsAutomation < authfail-exo.b64
gh secret set EXO_CERT_PWD --env clientdemo --repo digicybersec/NotificationsAutomation --body "ChangeMe-Temp-123!"
```

**Moi** — je crée l'environment + les **variables** (non secrètes) dès que tu me donnes :
`APP_ID`, `TENANT`, `SUB`, et `EXO_ORG` (ex. `client.onmicrosoft.com`).

## Partie D — Déclenchement turnkey complet

Je lance le workflow avec :
`createMailboxes=true`, `configureExchange=true`, `runSmokeTest=true`,
+ `svcMailbox`, `sendMailbox`, `selfDomain`, `scopeGroupMail`, `resourceGroup`, `location`, `prefix`.

Le pipeline crée alors **tout** : boîtes → infra → Graph → groupe + Application Access Policy +
transport rule → puis le smoke test attend la propagation.

---

## Points de vigilance (première exécution réelle)

- `az ad app credential reset --cert --append` : vérifie ensuite `az ad app credential list`.
- L'assignation du rôle **Exchange Administrator** peut mettre quelques minutes à être effective
  avant que `New-Mailbox` fonctionne en app-only.
- La création de boîte partagée est **asynchrone** — le smoke test (long poll) absorbe le délai,
  mais le job `configureExchange` (qui ajoute la boîte au groupe) peut devoir être **relancé**
  s'il tourne avant que la boîte soit pleinement provisionnée.
- Boîte d'envoi : idéalement un **sous-domaine dédié** (SPF/DKIM) pour la réputation.

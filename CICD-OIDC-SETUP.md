# CI/CD OIDC multi-clients — Onboarding d'un nouveau client

Le pipeline [`deploy.yml`](.github/workflows/deploy.yml) déploie chez **n'importe quel client**
sans rien coder en dur : la config est demandée au run (formulaire *Run workflow*), et les
identifiants Azure viennent d'un **GitHub Environment** portant le nom du client.

- **ARM + Graph** = **sans secret** (OIDC / federated credential).
- **Exchange** (Application Access Policy + transport rule) = **optionnel**, nécessite un
  **certificat** app-only (seule exception « secret »).

Répète ce runbook **une fois par client**. Le pipeline lui-même ne change jamais.

---

## 1. App registration Azure (dans le tenant DU CLIENT)

```bash
# connecté au tenant du client
az ad app create --display-name "github-authfail-deployer" --query appId -o tsv   # -> APP_ID
az ad sp create --id <APP_ID>
```

### Federated credential (le cœur du « sans secret »)
Autorise CE repo + cet environnement à obtenir un token, sans mot de passe :
```bash
az ad app federated-credential create --id <APP_ID> --parameters '{
  "name": "gh-<client>",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:digicybersec/NotificationsAutomation:environment:<client>",
  "audiences": ["api://AzureADTokenExchange"]
}'
```
> Le `subject` **doit** matcher exactement `environment:<client>` = le nom du GitHub Environment.

## 2. Droits Azure (ARM)

Le SP doit pouvoir déployer **et** créer le role assignment RBAC du Bicep → **Owner**
(ou Contributor + User Access Administrator) sur la souscription ou le RG cible :
```bash
az role assignment create --assignee <APP_ID> --role Owner \
  --scope /subscriptions/<SUB_ID>
```

## 3. Permissions Graph (app-only) — DEUX rôles requis

Le SP déployeur a besoin de **deux** permissions applicatives sur Microsoft Graph :
- `AppRoleAssignment.ReadWrite.All` (`06b708a9-e830-4db3-a914-8e69da51d44f`) — assigner Mail.* à la MI
- `Application.Read.All` (`9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30`) — **lire le SP de Graph** pour résoudre son ID (sinon `Insufficient privileges`)

> ⚠️ `az ad app permission add` + `admin-consent` s'est révélé **peu fiable** (la permission
> n'est pas toujours ajoutée/consentie). Méthode **directe et fiable** — on crée les deux
> assignations à la main (nécessite Global Admin) :

```bash
SP=$(az ad sp show --id <APP_ID> --query id -o tsv)
GRAPH=$(az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv)
for ROLE in 06b708a9-e830-4db3-a914-8e69da51d44f 9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30; do
  az rest --method POST \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{\"principalId\":\"$SP\",\"resourceId\":\"$GRAPH\",\"appRoleId\":\"$ROLE\"}"
done
# Vérif : doit lister les 2 appRoleId
az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP/appRoleAssignments" --query "value[].appRoleId" -o tsv
```

## 4. Exchange app-only (certificat) — REQUIS pour le mode turnkey

Nécessaire dès que tu automatises la **création des boîtes** (`createMailboxes`) ou la
configuration Exchange (`configureExchange`) — c'est-à-dire le déploiement turnkey complet.
Facultatif seulement si tu pré-crées les boîtes et configures Exchange à la main.
1. Sur l'app registration (ou une app dédiée) : ajouter la permission **Office 365 Exchange
   Online → Exchange.ManageAsApp** (Application) + **admin-consent**.
2. Attribuer le rôle Entra **Exchange Administrator** au SP.
3. Générer un **certificat**, l'uploader sur l'app, exporter le `.pfx`, l'encoder base64 :
   ```bash
   base64 -i cert.pfx | tr -d '\n' > cert.b64
   ```
4. Stocker côté GitHub (voir §5) : `EXO_APP_ID`, `EXO_ORG` (= domaine onmicrosoft du client),
   et le secret `EXO_CERT_B64`.

## 5. GitHub Environment = le client

Dans **Settings → Environments → New environment** → nomme-le exactement comme le `subject`
du federated credential (ex. `acme`). Ajoute :

**Variables** (non secrètes — OIDC) :
| Variable | Valeur |
|---|---|
| `AZURE_CLIENT_ID` | `<APP_ID>` |
| `AZURE_TENANT_ID` | tenant du client |
| `AZURE_SUBSCRIPTION_ID` | souscription cible |
| `EXO_APP_ID` *(si Exchange)* | AppId de l'app EXO |
| `EXO_ORG` *(si Exchange)* | `client.onmicrosoft.com` |

**Secrets** (seulement si Exchange) :
| Secret | Valeur |
|---|---|
| `EXO_CERT_B64` | le `.pfx` en base64 |

## 6. Lancer un déploiement

**Actions → Deploy AuthFail Notification (turnkey) → Run workflow** → remplis le formulaire :
`client` (= nom de l'environment), `resourceGroup`, `location`, `prefix`, `svcMailbox`,
`sendMailbox`, `selfDomain`, `scopeGroupMail`, `socMailbox` (option), `hourlyCap`, plus les
**3 interrupteurs turnkey** : `createMailboxes`, `configureExchange`, `runSmokeTest` (tous
cochés = déploiement complet de zéro à fonctionnel).

Le pipeline enchaîne, en **2 jobs** :

**Job `provision`**
1. login OIDC vers le tenant du client,
2. *(si `createMailboxes`)* crée les boîtes partagées (`provision-mailboxes.ps1`),
3. déploie l'infra (Bicep),
4. assigne Mail.Read / Mail.ReadWrite / Mail.Send à la MI,
5. *(si `configureExchange`)* groupe de scope + Application Access Policy + transport rule,
6. récap (principalId, appId).

**Job `validate`** *(si `runSmokeTest`)*
7. poll les runs du Logic App jusqu'à ce que l'accès boîte passe au vert (**attend la
   propagation** de l'Application Access Policy, ~30-60 min) → prouve que la chaîne fonctionne.

> ⏳ Le job `validate` peut tourner ~30-60 min (propagation). Si timeout, relance-le seul
> (*Re-run jobs*) plus tard — l'infra, elle, est déjà en place.
>
> 💡 Modes partiels : pour un client qui pré-crée ses boîtes / configure Exchange à la main,
> décoche `createMailboxes` et/ou `configureExchange` (le certificat EXO devient inutile).

---

## Pré-requis boîtes

En mode turnkey (`createMailboxes = true`), le pipeline **crée les boîtes partagées lui-même**
(`svcMailbox`, et `sendMailbox` si différente). ⚠️ La création de boîte est une action réelle
et peu réversible sur le tenant du client — c'est voulu en turnkey, mais garde-le en tête.

Si tu préfères les gérer à la main (`createMailboxes = false`), crée avant :
- **boîte de service partagée** (`svcMailbox`) qui reçoit la copie BCC,
- **boîte d'envoi** (`sendMailbox`, souvent = svc) avec SPF/DKIM OK.

Dans tous les cas, recommandé : un **sous-domaine d'envoi dédié** (ex. `notify.client.com`)
avec son propre SPF/DKIM/DMARC pour **isoler la réputation** (rappel : modèle B = backscatter).

## Pourquoi workflow_dispatch et pas « push auto »

En multi-clients, « déployer à chaque push » est ambigu (quel client ?). Le modèle correct
est **manuel paramétré** : tu choisis le client + la config au run. Si tu veux malgré tout un
déploiement auto vers **un** client de référence (staging), ajoute un trigger `push` ciblant
un environment fixe — dis-le-moi et je te l'ajoute.

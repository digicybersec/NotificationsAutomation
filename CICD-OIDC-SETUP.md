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

## 3. Permissions Graph (app-only, pour assigner Mail.* à la MI)

Le SP doit pouvoir **écrire des app role assignments** :
```bash
# AppRoleAssignment.ReadWrite.All (id 06b708a9-e830-4db3-a914-8e69da51d44f) sur Microsoft Graph
az ad app permission add --id <APP_ID> \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions 06b708a9-e830-4db3-a914-8e69da51d44f=Role
az ad app permission admin-consent --id <APP_ID>
```

## 4. (Optionnel) Exchange app-only — pour le job `runExchange`

Nécessaire seulement si tu veux automatiser l'Application Access Policy + la transport rule.
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

**Actions → Deploy AuthFail Notification → Run workflow** → remplis le formulaire :
`client` (= nom de l'environment), `resourceGroup`, `location`, `prefix`, `svcMailbox`,
`sendMailbox`, `selfDomain`, `scopeGroupMail`, `socMailbox` (option), `hourlyCap`,
`runExchange` (coche si tu as fait §4).

Le pipeline :
1. login OIDC vers le tenant du client,
2. déploie l'infra (Bicep),
3. assigne Mail.Read / Mail.ReadWrite / Mail.Send à la MI,
4. *(si coché)* crée le groupe de scope + Application Access Policy + transport rule,
5. affiche le récap (principalId, appId).

> ⏳ L'Application Access Policy met jusqu'à ~30 min à se propager avant que le Logic App
> puisse lire la boîte.

---

## Pré-requis boîtes (côté client, hors pipeline)

À créer avant (ou le pipeline échouera au runtime Graph) :
- **boîte de service partagée** (`svcMailbox`) qui reçoit la copie BCC,
- **boîte d'envoi** (`sendMailbox`, souvent = svc) avec SPF/DKIM OK,
- idéalement un **sous-domaine d'envoi dédié** pour isoler la réputation.

## Pourquoi workflow_dispatch et pas « push auto »

En multi-clients, « déployer à chaque push » est ambigu (quel client ?). Le modèle correct
est **manuel paramétré** : tu choisis le client + la config au run. Si tu veux malgré tout un
déploiement auto vers **un** client de référence (staging), ajoute un trigger `push` ciblant
un environment fixe — dis-le-moi et je te l'ajoute.

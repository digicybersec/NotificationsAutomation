# Déploiement depuis GitHub + bouton "Deploy to Azure"

Ce dossier est prêt à devenir un **repo GitHub** avec un bouton de déploiement en 1 clic.

## ⚠️ Ce que le bouton fait / ne fait pas

| | Couvert par le bouton (ARM) | À faire en post-step |
|---|:---:|:---:|
| Storage + tables (NotifyLog, Denylist, Counters) | ✅ | |
| Logic App + Managed Identity + Log Analytics + RBAC | ✅ | |
| **Permissions Graph app-only sur la MI** | ❌ | ✅ script `01` |
| **Application Access Policy** (scope mailbox) | ❌ | ✅ script `01` |
| **Transport rule** (détection + BCC) | ❌ | ✅ script `02` |

> ARM ne peut pas toucher Entra/Exchange. La partie Graph/Exchange reste **scriptée** (voir §4).

---

## 1. Structure du repo

Pousse le **contenu de ce dossier** (`optionB-logicapps/`) à la **racine** d'un repo GitHub :

```
azuredeploy.json          <- template ARM (cible du bouton, auto-généré)
createUiDefinition.json   <- formulaire de déploiement (portail)
main.bicep                <- source
workflow.json             <- définition du Logic App (inlinée dans azuredeploy.json)
01-setup-graph-permissions.ps1
02-transport-rule.ps1
.github/workflows/build-bicep.yml   <- recompile azuredeploy.json à chaque push
DEPLOY-GITHUB.md
```

> **Le repo doit être PUBLIC** — le portail Azure télécharge `azuredeploy.json` et
> `createUiDefinition.json` via leur URL raw, sans authentification. (Repo privé =
> il faudrait héberger le template ailleurs, ex. storage public + SAS.)

```bash
cd optionB-logicapps
git init -b main
git add .
git commit -m "AuthFail notification - deploy package"
gh repo create <OWNER>/authfail-notify --public --source=. --push
```

## 2. Le bouton (à coller dans le README, en remplaçant OWNER/REPO)

Avec le formulaire personnalisé :
```markdown
[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FOWNER%2FREPO%2Fmain%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FOWNER%2FREPO%2Fmain%2FcreateUiDefinition.json)
```

Version simple (formulaire auto-généré, sans createUiDefinition) :
```markdown
[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FOWNER%2FREPO%2Fmain%2Fazuredeploy.json)
```

Remplace `OWNER` et `REPO` (garde `main` ou mets ta branche). Rien d'autre à encoder.

## 3. Ce que fait le clic

Le bouton ouvre le portail → formulaire (préfixe, boîte de service, boîte d'envoi,
domaine interne, plafond horaire) → choix RG/région → **Create**. Ça déploie toute l'infra Azure.

## 4. Post-déploiement OBLIGATOIRE (Graph + Exchange)

Une fois l'infra créée, récupère le principalId et lance les scripts (depuis Cloud Shell) :

```bash
# principalId de la MI (requête directe sur la ressource — <prefix> = ce que tu as saisi, ex. authfail)
az resource show -g <RG> -n <prefix>-notify-logic \
  --resource-type Microsoft.Logic/workflows --query identity.principalId -o tsv
```
```powershell
# permissions Graph app-only + Application Access Policy
pwsh ./01-setup-graph-permissions.ps1 `
  -LogicAppPrincipalId <principalId> `
  -SvcMailbox <svc-authfail@domaine> `
  -ScopeGroupMail <authfail-notify-scope@domaine>

# transport rule (détection + BCC)
pwsh ./02-transport-rule.ps1
```
> ⏳ L'Application Access Policy met jusqu'à ~30 min (parfois plus) à se propager.

## 5. Recompilation automatique

Le workflow `.github/workflows/build-bicep.yml` recompile `azuredeploy.json` à chaque push
qui touche `main.bicep` ou `workflow.json` → le bouton reste toujours à jour. Tu ne modifies
jamais `azuredeploy.json` à la main.

---

## Aller plus loin — déploiement CI/CD (optionnel)

Le bouton = déploiement **manuel** depuis le portail. Pour un déploiement **automatique à
chaque push** (OIDC, sans secret), il faut :
1. Une app registration + **federated credential** GitHub → Azure.
2. Un workflow `deploy.yml` avec `azure/login@v2` (OIDC) + `az deployment group create`.
3. Idéalement, la partie Graph/Exchange automatisée via un service principal dédié.

Dis-le-moi si tu veux ce pipeline complet — je te le prépare (c'est ~1 fichier + la conf OIDC).

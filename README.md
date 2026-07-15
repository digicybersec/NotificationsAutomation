# AuthFail Notification — M365 / Logic Apps

Notifie automatiquement l'expéditeur d'un mail entrant en **échec SPF/DKIM** (message délivré,
sans bounce), via un **Logic App** en **app-only / Managed Identity**. Enregistre chaque domaine
détecté, applique un **coupe-circuit horaire** anti-backscatter et une **denylist** d'exceptions.

## Déploiement 1 clic

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fdigicybersec%2FNotificationsAutomation%2Fmain%2Fazuredeploy.json)

Le bouton déploie **l'infra Azure** : Logic App (Managed Identity), Storage + tables
(`NotifyLog`, `Denylist`, `Counters`), Log Analytics, RBAC.

> ⚠️ **La partie Graph/Exchange n'est pas couverte par ARM** (permissions app-only sur la MI,
> Application Access Policy, transport rule). Elle se fait en **post-déploiement scripté** —
> voir [`DEPLOY-GITHUB.md`](DEPLOY-GITHUB.md) §4.

## Architecture

```
Mail entrant externe (spf=fail / dkim=fail)
   └─ Transport rule : délivre + bannière destinataire + BCC vers la boîte de service
        └─ Logic App (poll app-only) : enregistre le domaine → garde-fous → notifie l'expéditeur
             ├─ NotifyLog : registre (FirstSeen, LastSeen, DetectionCount, First/LastNotifiedUtc)
             ├─ Denylist  : domaines à ne jamais notifier
             └─ Counters  : coupe-circuit horaire (hourlyCap)
```

## Contenu du repo

| Fichier | Rôle |
|---|---|
| `azuredeploy.json` | Template ARM (cible du bouton, auto-généré depuis `main.bicep`) |
| `createUiDefinition.json` | Formulaire de déploiement portail |
| `main.bicep` / `workflow.json` | Sources (le workflow est inliné à la compilation) |
| `01-setup-graph-permissions.ps1` | Post-step : permissions Graph + Application Access Policy |
| `02-transport-rule.ps1` | Post-step : transport rule de détection + BCC |
| `DEPLOY-GITHUB.md` | Guide de déploiement complet |
| `FEATURE-UPDATE-B.md` | Modèle de notification, schéma des tables, note de risque |
| `.github/workflows/build-bicep.yml` | Recompile `azuredeploy.json` à chaque push |

## Paramètres

`prefix`, `svcMailbox`, `sendMailbox`, `selfDomain`, `hourlyCap` (défaut 50).

## ⚠️ Note de sécurité

Ce modèle notifie **par défaut** tout expéditeur externe en échec d'authentification. Ces mails
étant majoritairement usurpés, les notifications peuvent partir vers des adresses falsifiées
(*backscatter*). Garde-fous intégrés : dédup 24 h/domaine + coupe-circuit horaire + denylist.
Recommandé : **sous-domaine d'envoi dédié** pour isoler la réputation. Détails dans
[`FEATURE-UPDATE-B.md`](FEATURE-UPDATE-B.md).

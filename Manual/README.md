# Déploiement manuel (2 scripts, sans GitHub)

Version **simple et locale** : tu lances 2 scripts dans l'ordre, tu réponds à quelques
questions, c'est tout. **Aucune automatisation GitHub, aucun certificat** — les connexions
Azure et Exchange se font par login interactif (fenêtre de navigateur).

## Prérequis

- **Windows PowerShell**
- **Azure CLI** : `winget install -e --id Microsoft.AzureCLI` (puis rouvrir PowerShell)
- Être **Global Administrator** du tenant Microsoft 365 **et** **Owner** d'une souscription Azure
- Avoir **cloné tout le dépôt** (les scripts utilisent `main.bicep` à la racine)
- Le module Exchange s'installe tout seul si besoin

## Étape 1 — Ressources Azure

```powershell
cd Manual
.\1-deploy-azure.ps1
```

Le script :
1. te connecte à Azure,
2. te fait **choisir ta souscription** dans une liste,
3. te demande les paramètres (des valeurs par défaut sont proposées — appuie sur Entrée pour les garder),
4. déploie le Logic App + le stockage + les permissions,
5. **note automatiquement l'ID de la Managed Identity** dans un fichier `deployment-info.json`.

## Étape 2 — Exchange

```powershell
.\2-deploy-exchange.ps1
```

Une fenêtre de connexion Exchange s'ouvre. Le script crée, dans l'ordre :
1. la **boîte partagée**,
2. le **groupe de sécurité** (scope),
3. l'**Application Access Policy** — il récupère **tout seul** l'ID de la Managed Identity
   depuis l'étape 1 (tu n'as rien à copier-coller),
4. la **règle de détection** SPF/DKIM.

## C'est fini

Attends **~30 à 60 min** (le temps que la policy Exchange se propage), puis les notifications
partent automatiquement.

---

### Pourquoi 2 scripts séparés ?

L'Application Access Policy (Exchange) a besoin de l'**ID de la Managed Identity**, qui n'existe
qu'**après** la création des ressources Azure. L'étape 1 crée cette identité et écrit son ID dans
`deployment-info.json` ; l'étape 2 le relit automatiquement. Tu n'as donc jamais à manipuler cet
ID toi-même — il suffit de lancer 1 puis 2.

### En cas de re-lancement

Les 2 scripts sont **idempotents** : si une ressource existe déjà, elle est ignorée. Tu peux
relancer sans risque.

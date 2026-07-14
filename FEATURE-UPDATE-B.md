# Mise à jour fonctionnelle — Modèle B (notify-par-défaut + denylist)

> **Choix client : notify par défaut, denylist pour exceptions.**
> Implémenté avec les garde-fous obligatoires ci-dessous. La note de risque
> résiduel (fin de doc) est à conserver au dossier.

## Ce qui change vs v1

| v1 (allowlist) | v2 (modèle B) |
|---|---|
| Ne notifie QUE les domaines allowlistés | **Notifie tout domaine détecté**, sauf denylist |
| `Allowlist` = gate d'autorisation | `Allowlist` **abandonnée** (table laissée mais ignorée) |
| — | `NotifyLog` devient le **registre auto-rempli** de tous les domaines |
| — | `Denylist` = exceptions à ne pas notifier |
| — | `Counters` = **coupe-circuit horaire** anti-backscatter |

## Schéma des tables

### `NotifyLog` (registre auto-rempli — 1 ligne / domaine)
| Colonne | Écrite par | Sens |
|---|---|---|
| `RowKey` | auto | le domaine |
| `FirstSeenUtc` | auto, 1 fois | 1ʳᵉ détection |
| `LastSeenUtc` | auto, à chaque fois | dernière détection |
| `DetectionCount` | auto, +1 | nb de détections |
| `FirstNotifiedUtc` | auto, 1 fois | **date de 1ʳᵉ notification** ✅ (ta demande) |
| `LastNotifiedUtc` | auto | dernière notif (dédup 24 h) |

### `Denylist` (exceptions — curée à la main)
`PartitionKey=domain`, `RowKey=<domaine>`. Présence = **on ne notifie jamais** ce domaine (on l'enregistre quand même).

### `Counters` (coupe-circuit)
`PartitionKey=hour`, `RowKey=yyyyMMddHH`, `Count`. Incrémenté à chaque envoi. Au-delà de `hourlyCap`, on **arrête d'envoyer** pour l'heure en cours (on continue d'enregistrer).

## Logique du workflow (v2)

Pour chaque mail non lu de la boîte de service :
1. **Anti-boucle** (mailer-daemon / postmaster / no-reply / self) → sinon on ignore.
2. **Enregistre toujours** le domaine dans `NotifyLog` (FirstSeen/LastSeen/Count).
3. On **notifie SI** :
   - domaine **absent de `Denylist`**, ET
   - **pas notifié < 24 h** (`LastNotifiedUtc`), ET
   - **cap horaire non atteint** (`Counters` < `hourlyCap`).
4. Si notifié → set `FirstNotifiedUtc` (une seule fois) + `LastNotifiedUtc` + incrément compteur.
5. `Mark read`.

## « Nombre de jours écoulés depuis la 1ʳᵉ notif »

**Non stocké** (ce serait faux dès le lendemain). Calculé **à la lecture** depuis `FirstNotifiedUtc`.

- Dans un dashboard / une requête : `jours = maintenant − FirstNotifiedUtc`.
- Exemple **KQL** (Log Analytics, si tu exportes la table) ou logique équivalente côté rapport :
  ```
  extend DaysSinceFirstNotified = datetime_diff('day', now(), todatetime(FirstNotifiedUtc))
  ```
- Si tu veux le voir dans un **Power BI / Workbook** branché sur la table : colonne calculée `DATEDIFF(FirstNotifiedUtc, UTCNOW(), DAY)`.

> Si le client exige absolument la colonne matérialisée dans la table : il faut un
> **Logic App quotidien** qui recalcule `DaysSinceFirstNotified` sur toutes les lignes.
> Moving part en plus, à éviter sauf exigence ferme.

## Gérer la denylist (exceptions)

Ajouter un domaine à ne jamais notifier :
```bash
az storage entity insert --account-name <storage> --account-key <key> \
  --table-name Denylist --entity PartitionKey=domain RowKey=domaine-a-exclure.com
```
(domaine en minuscules, sans `@`.)

## Paramètre de sécurité

`hourlyCap` (défaut **50**) — passe-le au déploiement :
```bash
az deployment group create -g rg-authfail -f main.bicep \
  -p svcMailbox=svc-authfail@yourdomain.com \
     sendMailbox=svc-authfail@yourdomain.com \
     selfDomain=yourdomain.com \
     hourlyCap=50
```
Garantie : **max `hourlyCap` envois/heure**, quoi qu'il arrive. Ajuste selon le volume légitime attendu.

---

## ⚠️ NOTE DE RISQUE RÉSIDUEL (à conserver au dossier)

Le modèle B **notifie par défaut tout expéditeur externe en échec SPF/DKIM**. Or ces
messages sont **majoritairement usurpés** → les notifications partent vers des **adresses
falsifiées** (tiers innocents ou attaquants) = **backscatter**.

Conséquences possibles, à avoir tracées :
- **Réputation** de la boîte/domaine d'envoi dégradée (risque de blocklist).
- **Volume** potentiellement élevé lors de campagnes de spoof (domaines rotatifs).
- Une **denylist ne peut pas suivre** un attaquant qui change de domaine.

**Mitigations mises en place** : dédup 24 h/domaine + coupe-circuit horaire (`hourlyCap`).
**Mitigations recommandées en complément** (à proposer au client) :
1. **Sous-domaine d'envoi dédié** (ex. `notify.yourdomain.com`) avec son propre SPF/DKIM/DMARC,
   pour **isoler la réputation** du domaine principal.
2. **Alerte SOC** quand le cap horaire est atteint (indicateur de tempête de spoof).
3. Revue périodique du registre `NotifyLog` pour alimenter la `Denylist`.

Position conseil : le modèle A (allowlist) restait préférable ; B est livré à la demande
explicite du client, avec garde-fous. Le vrai canal de feedback normalisé reste **DMARC**.

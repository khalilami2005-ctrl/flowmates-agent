# Livrer Flowmates

Ce que `release.yml` fait tout seul, ce qu'il faut lui donner avant, et ce qui
n'est pas encore automatisé. Écrit le 30 juillet 2026, après la première
construction signée réussie sur poste Windows.

---

## 1. La clé de signature des mises à jour

Elle vit **hors du dépôt**, dans `C:\Users\emmab\.flowmates-keys\` :

```
flowmates-updater.key       privée — secret absolu
flowmates-updater.key.pub   publique — déjà dans tauri.conf.json
```

Générée le 30/07/2026, **mot de passe vide**. Elle remplace une clé publique
orpheline : l'ancienne `pubkey` était bien dans `tauri.conf.json` mais sa moitié
privée n'existait sur aucune machine, ce qui rendait `pnpm build` impossible.

> **Sa perte est définitive.** La clé publique est compilée dans chaque binaire
> installé ; sans la privée correspondante, aucune de ces machines n'accepterait
> plus jamais de mise à jour. Il n'y a pas de récupération, seulement une
> réinstallation manuelle chez chaque utilisateur.
>
> Le remplacement n'est sans conséquence qu'**avant** la première release. Après,
> il coupe les mises à jour de tout le parc installé.

À faire une fois, maintenant : en garder une copie dans un gestionnaire de mots
de passe ou sur un support chiffré. Pas seulement sur ce PC.

---

## 2. Les secrets GitHub

*Settings → Secrets and variables → Actions → New repository secret*

| Secret | Valeur | Sans lui |
|---|---|---|
| `TAURI_SIGNING_PRIVATE_KEY` | le **contenu** de `flowmates-updater.key`, pas son chemin | la construction échoue |
| `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | vide | idem |
| `NEXT_PUBLIC_SUPABASE_URL` | `https://uqtgvqnhgcetkhypdpyh.supabase.co` | build local-only |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | la clé publique du projet | build local-only |

Les deux derniers sont facultatifs au sens strict : sans eux la construction
réussit, mais l'application livrée n'a **aucun backend** — connexion, synchro et
intégrations se déclarent indisponibles au lieu de contacter un hôte. C'est le
comportement voulu par `sync_env.rs`, pas une panne, mais ce n'est pas ce qu'on
veut livrer.

`TAURI_JIRA_*` et `TAURI_LINEAR_*` restent vides tant que les intégrations ne
sont pas configurées.

---

## 3. Publier

```
GitHub → Releases → Draft a new release
  Tag        v1.0.0        (doit correspondre à tauri.conf.json → version)
  Titre      Flowmates 1.0.0
  Notes      elles atterrissent dans latest-windows.json → notes
  → Publish release
```

Publier déclenche `release.yml`, qui construit sur `windows-latest`, signe les
artefacts, fabrique `latest-windows.json` et attache le tout à la release.

**Le brouillon ne déclenche rien** — le workflow écoute `release: [published]`.

---

## 4. Vérifier avant d'annoncer

La release doit porter trois fichiers :

```
Flowmates_1.0.0_x64-setup.exe        installateur NSIS
Flowmates_1.0.0_x64-setup.exe.sig    sa signature
latest-windows.json                  le manifeste que l'app interroge
```

Sans le `.sig`, la signature n'a pas eu lieu : le secret est absent ou mal collé.

Puis **essayer la mise à jour pour de vrai** : installer 1.0.0, publier 1.0.1,
vérifier qu'une machine déjà installée la prend. Un updater jamais essayé est un
updater cassé — on ne le découvre autrement que chez l'utilisateur.

---

## 5. Ce qui n'est pas réglé

### Google OAuth doit être en production

Tant que l'écran de consentement est en *Testing*, seuls les comptes listés en
« Test users » peuvent se connecter, et **leurs refresh tokens expirent au bout
de 7 jours** — de quoi chercher longtemps un bug de rafraîchissement qui n'existe
pas.

L'application ne demande que `email`, `profile` et `openid`, tous non sensibles :
la publication ne passe donc pas par la revue de Google, c'est deux clics sur
`console.cloud.google.com/auth/audience`.

### Pas de certificat de signature de code

SmartScreen affichera « éditeur inconnu » à chaque installation. Ce n'est pas
bloquant, mais le délai d'obtention se compte en semaines : à lancer avant d'en
avoir besoin.

C'est différent de la clé de la §1 — celle-ci signe les *mises à jour* pour
Tauri, un certificat signe l'*exécutable* pour Windows.

### L'installateur pèse 1,5 Go

94 % sont les deux fichiers de poids (`local_llm/*.gguf`, 1 320 Mo), déclarés
dans `tauri.conf.json → bundle.resources`. Conséquences : les releases GitHub
plafonnent à 2 Go par fichier, et **chaque mise à jour redescend 1,5 Go** même
pour un correctif de trois lignes.

Le seul levier réel est de ne pas les embarquer et de les télécharger après
l'installation (~190 Mo d'installateur). Le code s'y prête : la résolution passe
par `paths.rs::resource_local_llm_dir()` et `agent.rs:1118` en dérive les deux
chemins. Il faudrait y ajouter `data_dir()/local_llm` en tête, un téléchargeur
reprenable — 1,3 Go sur une connexion d'entreprise, ça coupe —, une vérification
SHA-256, et une interface qui reste utilisable pendant : l'agent mesure déjà sans
le modèle.

Le prix à payer est la démonstration client sans réseau, que le bundling actuel
permet.

### Jamais essayés

Multi-écran et facteurs d'échelle différents · détection du verrouillage de
session · non-survivance de `llama-server` après un arrêt forcé · invitations
d'équipe · l'updater lui-même.

---

## 6. Construire à la main

Utile pour reproduire un problème de CI localement.

```powershell
$env:TAURI_SIGNING_PRIVATE_KEY = [IO.File]::ReadAllText("C:\Users\emmab\.flowmates-keys\flowmates-updater.key").Trim()
$env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = ""
$env:NEXT_PUBLIC_SUPABASE_URL = "https://uqtgvqnhgcetkhypdpyh.supabase.co"
$env:NEXT_PUBLIC_SUPABASE_ANON_KEY = "<clé publique du projet>"
corepack pnpm build
```

Les artefacts sortent dans `apps/agent/src-tauri/target/release/bundle/`.

Deux pièges rencontrés :

- **`--password ""` ne marche pas** sous PowerShell, qui supprime la chaîne vide.
  Écrire `"--password="` avec le signe égal.
- **Ne jamais écrire `tauri.conf.json` avec `Set-Content -Encoding utf8`** : en
  PowerShell 5.1 cela ajoute un BOM, et Tauri échoue sur
  `expected value at line 1 column 1`. Passer par
  `[IO.File]::WriteAllText($path, $txt, (New-Object Text.UTF8Encoding($false)))`.

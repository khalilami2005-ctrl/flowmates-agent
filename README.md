# Flowmates — Windows

Agent de mesure d'activité pour Windows, en Rust + Tauri 2. Il observe le contexte
de travail, le fait analyser par un modèle de vision **local**, et produit des
rapports. Rien de ce qui décrit l'écran ne quitte la machine.

C'est la déclinaison Windows de Flowmates. La version macOS vit dans un dépôt
séparé et partage la marque, pas le dépôt.

---

## Ce qui tourne en local, et ce qui n'existe pas encore

Le moteur d'inférence (`llama.cpp`) et les poids sont embarqués dans
l'application. Aucun aller-retour réseau n'est nécessaire pour analyser un écran.

**Aucune adresse de serveur et aucune clé ne sont compilées dans ce binaire.** Une
construction livrée sans configuration n'a pas de cloud : la mesure locale,
l'analyse locale et les rapports locaux fonctionnent ; l'authentification, la
synchronisation et les intégrations se déclarent indisponibles au lieu de
contacter un hôte. Voir `apps/agent/src-tauri/src/sync_env.rs` — le test
`no_host_is_compiled_in` est là pour que ça le reste. Le renderer applique la même
règle dans `auth-service.js`.

Renseigner `NEXT_PUBLIC_SUPABASE_URL` et `NEXT_PUBLIC_SUPABASE_ANON_KEY` dans
`.env.local` active ces fonctions. Le backend correspondant est à construire :
il n'est pas dans ce dépôt.

---

## Démarrage

### Prérequis

- **Windows 10 22H2 ou Windows 11**, x86-64
- **Rust stable** avec la chaîne `x86_64-pc-windows-msvc`
- **Visual Studio Build Tools** (« Desktop development with C++ »)
- **Node.js 20** ou plus récent, **pnpm 8.15**
- **WebView2** — présent d'origine sur Windows 11 ; l'installateur l'embarque

### Lancer

```powershell
git clone https://github.com/khalilami2005-ctrl/flowmates-agent.git
cd flowmates-agent
pnpm install
node scripts/fetch-models.mjs --check   # vérifie la présence des poids
pnpm dev
```

Le moteur `llama-server.exe` et ses DLL sont dans `local_llm/bin/`, versionnés
avec le dépôt. **Les poids du modèle, eux, n'y sont pas** : ils pèsent 1,3 Go et
se récupèrent depuis une release GitHub. Voir « Poids du modèle » plus bas.

### Construire

```powershell
pnpm build     # produit un installateur NSIS et un MSI
```

Les artefacts atterrissent dans `apps/agent/src-tauri/target/release/bundle/`.

`createUpdaterArtifacts` est actif : la construction signe les artefacts de mise
à jour et réclame la clé privée. Sa contrepartie publique est dans
`tauri.conf.json`, et **sa perte est définitive** — aucune copie installée
n'accepterait plus jamais de mise à jour.

---

## Poids du modèle

`scripts/fetch-models.mjs` attend deux fichiers dans `local_llm/` :

| Fichier | Taille |
|---|---|
| `Qwen3-VL-2B-Instruct-Q3_K_M.gguf` | 896 Mo |
| `mmproj-Qwen3VL-2B-Instruct-Q8_0.gguf` | 424 Mo |

Ils se téléchargent depuis la release `models-v1` de ce dépôt. **Tant que cette
release n'existe pas, `pnpm build` échouera à cette étape.** Pour la créer, depuis
une machine qui possède déjà les fichiers :

```bash
gh release create models-v1 --title "Poids du modèle de vision" --notes ""
gh release upload models-v1 \
  local_llm/Qwen3-VL-2B-Instruct-Q3_K_M.gguf \
  local_llm/mmproj-Qwen3VL-2B-Instruct-Q8_0.gguf
```

`FLOWMATES_MODELS_REPO` et `FLOWMATES_MODELS_TAG` permettent de pointer ailleurs.

---

## Architecture

```text
apps/agent/
  src-tauri/       application Tauri, sources Rust
    llama_windows_job.rs  Job Object : tue llama-server avec l'agent
    llama_port.rs         choix de port sans collision
    screenshot_disk.rs    captures chiffrées par DPAPI
    ocr.ps1               OCR via PowerShell
  src/renderer/    interface HTML/CSS/JS
local_llm/
  bin/             llama-server.exe et ses DLL
  *.gguf           poids du modèle de vision (hors dépôt)
scripts/
  fetch-models.mjs récupère les poids
docs/
  resource-analysis.md consommation mesurée
tools/
  popular-apps-catalog/ catalogue d'applications pour la classification
```

Le traitement lourd — résumé de contexte, filtrage, inférence d'intention — passe
par le `llama-server` embarqué. Seuls des agrégats déjà filtrés peuvent atteindre
un backend, et uniquement si l'utilisateur en a configuré un et rejoint une équipe.

---

## Vérifications

```powershell
pnpm test                               # tests Rust
cargo fmt --manifest-path apps/agent/src-tauri/Cargo.toml -- --check
cargo clippy --manifest-path apps/agent/src-tauri/Cargo.toml --all-targets -- -D warnings
node scripts/fetch-models.mjs --check
```

---

## Publication

Publier une release GitHub déclenche `.github/workflows/release.yml`, qui
construit sur `windows-latest`, signe les artefacts de mise à jour et attache
l'installateur ainsi que `latest-windows.json` à la release. C'est ce fichier que
l'application interroge.

Secrets nécessaires : `TAURI_SIGNING_PRIVATE_KEY` et
`TAURI_SIGNING_PRIVATE_KEY_PASSWORD`. Les secrets de backend et d'intégrations
sont facultatifs — sans eux, la construction est purement locale.

---

## Licence

Aucune licence n'est publiée pour l'instant. Le droit d'auteur s'applique seul :
**tous droits réservés**. Le dépôt est public — le code est donc lisible, mais
ni réutilisable ni redistribuable sans accord écrit.

Les licences des dépendances tierces restent dues et sont dans
[`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md).

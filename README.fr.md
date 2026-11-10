<p align="center">
  <img src="docs/images/icon.png" width="128" alt="Icône de Rowster">
</p>

<h1 align="center">Rowster</h1>

<p align="center">Un client de bases de données natif, gratuit et open source pour macOS, avec la sécurité intégrée.</p>

<p align="center">
  <a href="https://github.com/romainrg/Rowster/releases/latest"><img src="https://img.shields.io/github/v/release/romainrg/Rowster?sort=semver&style=for-the-badge&logo=apple&logoColor=white&label=T%C3%A9l%C3%A9charger&color=0A84FF" alt="Télécharger Rowster pour macOS"></a><br>
  <sub>Gratuit et open source · macOS 14 ou ultérieur · Apple silicon et Intel</sub>
</p>

<p align="center"><a href="README.md">English version</a></p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/data-grid-dark.png">
  <img src="docs/images/data-grid-light.png" alt="Une table ouverte dans Rowster, triée sur deux colonnes">
</picture>

Rowster parcourt, filtre, modifie et interroge des bases PostgreSQL, MySQL, MariaDB et SQLite. Il est écrit en Swift, avec ses propres pilotes : aucune bibliothèque C embarquée, pas d'Electron. Il n'y a aucune limite d'onglets, de fenêtres ou de filtres, et rien à payer.

## Installation

Téléchargez les fichiers de la [dernière version](https://github.com/romainrg/Rowster/releases/latest). Choisissez l'un des deux installeurs :

- **DMG** : ouvrez `Rowster-<version>.dmg` et faites glisser **Rowster** sur le dossier **Applications**.
- **PKG** : double-cliquez sur `Rowster-<version>.pkg` et suivez l'installeur. Il installe toujours dans `/Applications`.

Aucun des deux n'est notarisé par Apple (il faut pour cela un compte développeur payant), donc macOS bloque la première ouverture. Essayez de l'ouvrir une fois, puis allez dans **Réglages Système › Confidentialité et sécurité**, faites défiler vers le bas et cliquez sur **Ouvrir quand même** à côté du message concernant Rowster (ou l'installeur, pour le PKG). Vous pouvez aussi retirer vous-même l'attribut de quarantaine :

```sh
xattr -dr com.apple.quarantine /Applications/Rowster.app
# pour l'installeur, avant de l'ouvrir :
xattr -dr com.apple.quarantine ~/Downloads/Rowster-<version>.pkg
```

Vérifiez votre téléchargement avec les sommes de contrôle publiées avec la version, depuis le dossier qui contient les fichiers :

```sh
shasum -a 256 -c SHA256SUMS
```

**Prérequis :** macOS 14 Sonoma ou plus récent. Ce qui a été laissé pour plus tard est dans [Limites](#limites-de-la-01).

## Fonctionnalités

- **PostgreSQL, MySQL, MariaDB et SQLite**, avec des pilotes écrits en Swift sur Network.framework. Les serveurs qui parlent le protocole PostgreSQL devraient fonctionner dans la mesure où ils l'implémentent.
- **TLS** en cinq modes, de désactivé à la vérification complète, avec un fichier d'autorité facultatif.
- **Tunnels SSH** par l'OpenSSH du système : votre `~/.ssh/config`, les agents (1Password, Secretive) et ProxyJump s'appliquent comme dans un terminal. Les questions de phrase de passe et de clé d'hôte sont posées dans l'app.
- **Grille de données** : 300 lignes par page par défaut, un tri multi-colonnes mémorisé par table, des largeurs de colonnes mémorisées, des BLOB affichés par leur taille et chargés à la demande.
- **Barre de filtres** (⌘F) : autant de conditions que vous voulez, une recherche dans toutes les colonnes, une condition SQL écrite à la main, et *Afficher le SQL*.
- **Inspecteur de ligne** (⌥⌘I) : toutes les valeurs d'une ligne, un arbre repliable pour le JSON, un aperçu en image ou en hexadécimal pour les valeurs binaires.
- **Clés étrangères** : une flèche ouvre la ligne référencée ; la survoler en affiche un aperçu.
- **Modifications en attente** : les changements sont surlignés, prévisualisés en SQL (⇧⌘P), puis validés dans une seule transaction (⌘S).
- **Éditeur SQL** : coloration par moteur, exécution de l'instruction sous le curseur (⌘↩) ou de tout (⇧⌘↩), un résultat par instruction, annulation, historique avec recherche.
- **Structure** : colonnes, index, contraintes et DDL.
- **Export** en CSV et JSON, écrit en flux ; copie de lignes en CSV, JSON, Markdown ou instructions `INSERT`.
- **Étiquettes et couleurs d'environnement**, avec la production ouverte en lecture seule.
- Anglais et français.

## Captures d'écran

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/welcome-dark.png">
  <img src="docs/images/welcome-light.png" width="620" alt="La fenêtre d'accueil, avec les connexions rangées en groupes">
</picture>
</p>

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/pending-changes-dark.png">
  <img src="docs/images/pending-changes-light.png" alt="Une cellule modifiée, une ligne supprimée et une nouvelle ligne, en attente">
</picture>
</p>

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/editor-dark.png">
  <img src="docs/images/editor-light.png" alt="L'éditeur SQL avec un résultat par instruction">
</picture>
</p>

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/filters-dark.png">
  <img src="docs/images/filters-light.png" alt="La barre de filtres avec trois conditions">
</picture>
</p>

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/inspector-dark.png">
  <img src="docs/images/inspector-light.png" alt="L'inspecteur de ligne avec un arbre JSON et une image">
</picture>
</p>

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/unlocked-dark.png">
  <img src="docs/images/unlocked-light.png" alt="Une connexion de production, en rouge, avec l'écriture déverrouillée">
</picture>
</p>

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/structure-dark.png">
  <img src="docs/images/structure-light.png" alt="La structure d'une table">
</picture>
</p>

## Sécurité

- **Aucune écriture n'a lieu sans que vous ayez vu le SQL.** Les changements faits dans la grille attendent que vous les validiez, dans une seule transaction, annulée entière si quoi que ce soit échoue.
- **La production est en lecture seule.** Une connexion étiquetée production s'ouvre en lecture seule, sur le serveur et dans l'app, et sa couleur est visible partout. L'écriture se déverrouille pour une fenêtre à la fois, après une confirmation et, si vous l'activez, Touch ID.
- **Les instructions destructrices sont confirmées** : `DROP`, `TRUNCATE`, et `DELETE` ou `UPDATE` sans `WHERE`, affichées en entier.
- **Les résultats sont bornés**, et toute instruction peut être annulée.
- **Les valeurs ne font jamais partie du SQL** que Rowster génère : ce sont des paramètres liés.
- **Les mots de passe ne sont que dans le Trousseau.** Le fichier qui liste vos connexions n'en contient aucun.
- **Pas de télémétrie.** Rowster ne contacte que les bases et les hôtes SSH que vous configurez.

Le mode lecture seule protège contre les accidents ; ses limites sont décrites dans [SECURITY.md](SECURITY.md).

## Compiler depuis les sources

Prérequis : macOS 14 ou plus récent, Xcode 16 ou plus récent, et XcodeGen (`brew install xcodegen`).

```sh
git clone https://github.com/romainrg/Rowster.git
cd Rowster
make run     # ou : make demo, pour l'essayer avec une base d'exemple et sans réseau
```

Les autres commandes sont dans [CONTRIBUTING.md](CONTRIBUTING.md).

## Limites de la 0.1

- Les versions sont signées ad hoc : macOS redemande l'accès à chaque mot de passe enregistré après une mise à jour, et Gatekeeper exige *Ouvrir quand même* au premier lancement.
- L'éditeur n'a pas encore de complétion, et une valeur de plusieurs lignes ne peut pas être modifiée dans la grille.
- Pas de certificats client TLS, pas de Kerberos, pas d'authentification `ed25519` de MariaDB.
- La structure est en lecture seule.

## Feuille de route

- **0.2** : complétion dans l'éditeur, Redis, serveur MCP intégré en lecture seule, requêtes enregistrées, Open Anything (⌘P), import CSV, liste des processus, `EXPLAIN` visuel.
- **0.3** : panneau assistant, modification de la structure, ClickHouse, libSQL/Turso, Cloudflare D1, SQL Server.
- Plus tard : signature Developer ID et notarisation.

## Contribuer

Les contributions sont les bienvenues : lisez [CONTRIBUTING.md](CONTRIBUTING.md). Les rapports de sécurité passent par [SECURITY.md](SECURITY.md). L'architecture est décrite dans [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Licence

[MIT](LICENSE) © 2026 Romain Gallien

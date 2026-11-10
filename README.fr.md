<p align="center">
  <img src="docs/images/icon.png" width="128" alt="Icône de Rowster">
</p>

<h1 align="center">Rowster</h1>

<p align="center">Un client de bases de données natif, gratuit et open source pour macOS, avec la sécurité intégrée.</p>

<p align="center"><a href="README.md">English version</a></p>

## État

Rowster est en cours de développement et n'a pas encore de version publiée. La version 0.1 est spécifiée dans [docs/specs/0.1.md](docs/specs/0.1.md) et construite incrément par incrément selon [docs/plans/0.1.md](docs/plans/0.1.md).

## Fonctionnalités

Prévues pour la 0.1 :

- **PostgreSQL, MySQL/MariaDB et SQLite**, avec des pilotes natifs écrits en Swift : aucune bibliothèque C embarquée, pas d'Electron.
- **TLS et tunnels SSH** par l'OpenSSH du système : `~/.ssh/config`, les agents et ProxyJump fonctionnent d'office.
- **Grille de données** avec pagination, barre de filtres, tri multi-colonnes mémorisé par table, et inspecteur de ligne (formulaire, arbre JSON, aperçu des BLOB).
- **Modifications en attente** : les changements sont surlignés, prévisualisés en SQL, puis validés dans une seule transaction.
- **Éditeur SQL** avec un onglet de résultat par instruction, l'annulation et un historique avec recherche.
- **Étiquettes et couleurs d'environnement**, avec la production ouverte en lecture seule.
- Aucune limite d'onglets, de fenêtres ou de filtres. Anglais et français.

## Sécurité

- Aucune écriture n'a lieu sans que vous ayez vu le SQL.
- Une connexion étiquetée production s'ouvre en lecture seule, et sa couleur est visible partout.
- `DROP`, `TRUNCATE`, et `DELETE` ou `UPDATE` sans `WHERE` sont confirmés.
- Les résultats sont bornés et toute requête peut être annulée.
- Les mots de passe ne sont stockés que dans le Trousseau. Pas de télémétrie : Rowster ne contacte que les bases et les hôtes SSH que vous configurez.

## Compiler depuis les sources

Prérequis : macOS 14 ou plus récent, Xcode 16 ou plus récent, et XcodeGen (`brew install xcodegen`).

```sh
git clone https://github.com/romainrg/Rowster.git
cd Rowster
make run     # ou : make demo, pour l'essayer avec une base d'exemple
```

Les autres commandes sont dans [CONTRIBUTING.md](CONTRIBUTING.md).

## Feuille de route

- **0.1** : PostgreSQL, MySQL/MariaDB, SQLite ; grille, filtres, inspecteur, modifications en attente ; éditeur ; production en lecture seule ; export CSV et JSON.
- **0.2** : Redis, serveur MCP intégré en lecture seule, requêtes enregistrées, Open Anything (⌘P), import CSV, liste des processus, `EXPLAIN` visuel.
- **0.3** : panneau assistant, modification de la structure, ClickHouse, libSQL/Turso, Cloudflare D1, SQL Server.
- Plus tard : signature Developer ID et notarisation.

## Contribuer

Les contributions sont les bienvenues : lisez [CONTRIBUTING.md](CONTRIBUTING.md). Les rapports de sécurité passent par [SECURITY.md](SECURITY.md).

## Licence

[MIT](LICENSE) © 2026 Romain Gallien

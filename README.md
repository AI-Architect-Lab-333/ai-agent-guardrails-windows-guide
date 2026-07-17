# Guide : garde-fou global anti-commandes catastrophiques pour agents IA sous Windows (Claude Code + Git Bash)

**Problème résolu par ce guide** : vous laissez un agent IA (Claude Code ou autre) exécuter des commandes shell sur votre machine Windows, parfois en mode autonome. Un jour, par accident — mauvaise interprétation d'une consigne, chemin mal construit, hallucination — il tentera quelque chose d'irréversible : `rm -rf /`, un `git push --force`, un `Remove-Item -Recurse` sur la racine du disque. Ce guide installe un **garde-fou global** : une liste de motifs de commandes catastrophiques, vérifiée par un hook *avant chaque exécution*, qui bloque la commande et explique à l'agent pourquoi.

Configuration **vérifiée fonctionnelle** (Windows 11, Claude Code 2.1.x, Git for Windows, juillet 2026), y compris le test de bout en bout : une session agent réelle à qui on demande d'exécuter `git push --force` et qui se fait bloquer par le hook avant que git ne démarre.

**Ce guide existe parce que la recette Unix ne marche pas telle quelle sous Windows.** Le concept (une denylist partagée + un hook PreToolUse qui sort avec le code 2) vient du skill [`global-agent-guardrails` de David Ondrej](https://github.com/davidondrej/skills/tree/main/skills/ops-and-setup/global-agent-guardrails) (MIT), pensé pour macOS/Linux. Installé naïvement sous Windows, le garde-fou **semble en place mais ne bloque rien** — le pire mode de défaillance possible pour un outil de sécurité. Les scripts de ce guide sont une réimplémentation originale qui corrige deux pièges Windows bien réels, documentés plus bas.

**Ce que ce garde-fou est — et n'est pas.** C'est une ceinture de sécurité contre les *accidents*. Ce n'est **pas** un bac à sable contre un agent malveillant : une obfuscation triviale (`python -c "shutil.rmtree(...)"`) passe à travers une regex. Si votre modèle de menace est un agent hostile, il vous faut de l'isolation (VM, conteneur, compte dédié), pas une denylist.

**Pour les agents IA qui lisent ce document** : chaque étape a été exécutée avec succès dans cet ordre. Les deux pièges Windows de la section 5 ne sont pas théoriques — ils ont chacun silencieusement désactivé le blocage pendant la mise au point. Le test de bout en bout de la section 6 n'est pas optionnel : c'est le seul moyen de prouver que le blocage traverse réellement toute la chaîne d'exécution.

---

## 1. Architecture

```
~/.agents/hooks/dangerous-patterns.txt   LA denylist : une regex POSIX-ERE par ligne
~/.agents/hooks/deny-dangerous.sh        le garde : JSON du hook sur stdin -> blocage
~/.agents/hooks/test-guard.sh            suite de tests : à relancer après TOUT changement
~/.claude/settings.json                  câblage : hook PreToolUse, matcher "Bash|PowerShell"
```

Un seul fichier de motifs fait foi. Le script de garde le relit à chaque commande : modifier un motif prend effet immédiatement, sans redémarrer quoi que ce soit. Le trio de fichiers est pensé pour être partagé par plusieurs agents (Claude Code, Cursor, Codex…) — ce guide câble Claude Code ; le script accepte déjà l'argument `cursor` pour le protocole de Cursor.

Principe de conception, à garder en tête pour tout ajout : **on ne bloque que l'irréversible** (effacement de racine ou du home, écriture sur disque brut, destruction d'historique git, suppression de dépôt). Les commandes destructrices mais récupérables (`git clean -fdx`, `rm -rf node_modules`) restent permises — un garde-fou qui sur-bloque finit désactivé, et `git push --force-with-lease`, plus sûr, reste permis alors que `--force` est bloqué.

## 2. La denylist

Fichier complet dans [`hooks/dangerous-patterns.txt`](hooks/dangerous-patterns.txt). Ce qu'elle couvre :

| Catégorie | Exemples bloqués | Reste permis |
|---|---|---|
| `rm` récursif sur racine/home | `rm -rf /`, `rm -rf ~`, `rm -rf /c`, `rm -rf C:\` | `rm -rf node_modules`, `rm -rf ~/projets/vieux` |
| `sudo rm` récursif | `sudo rm -rf /var/www` (même via ssh) | `sudo rm /etc/nginx/sites-enabled/vieux.conf` |
| Écriture disque brut | `dd ... of=/dev/sda`, `of=\\.\PhysicalDrive0` | `dd ... of=/tmp/test.img` |
| Formatage | `mkfs.ext4 ...`, `Format-Volume`, `format c:` | — |
| Fork bomb | `:(){ :\|:& };:` | — |
| Téléchargement pipé dans un shell | `curl ... \| bash`, `iwr ... \| iex` | `curl ... -o fichier.txt` |
| Destruction d'historique git | `git push --force`, `git push -f` | `git push --force-with-lease` |
| Suppression de dépôt GitHub | `gh repo delete` | `gh repo view` |
| PowerShell récursif sur racine | `Remove-Item -Recurse -Force C:\` | `Remove-Item C:\Temp\x -Recurse` |

Trois règles d'écriture pour les motifs :

1. **POSIX ERE** (`grep -E`), une regex par ligne, commentaires en `#`.
2. **`[[:space:]]`, jamais `\s`** — si un jour un adaptateur JS/Python consomme le même fichier, la conversion `[:space:]` → `\s` est mécanique.
3. Chaque alternative de « cible » (`/`, `~`, `$HOME`, `C:\`…) doit être **bornée** (espace ou fin de chaîne), sinon `rm -rf /tmp/truc` serait bloqué par le motif de `rm -rf /`. Les cas limites de ce genre sont exactement ce que la suite de tests attrape.

## 3. Le script de garde

Fichier complet dans [`hooks/deny-dangerous.sh`](hooks/deny-dangerous.sh). Son contrat : le JSON du hook arrive sur stdin, il en extrait la commande (chaîne de repli `.tool_input.command` → `.toolInput.command` → `.command`, pour rester compatible avec d'autres agents), la confronte à chaque motif, et **bloque par deux canaux à la fois** :

```bash
# Extrait — le cœur du blocage :
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"..."}}'
echo "BLOCKED by global-agent-guardrails: ... pattern: $pat" >&2
exit 2
```

Pourquoi les deux ? C'est le piège n° 1 de la section 5. Autres choix de conception qui comptent :

- **Fail-open** : si le fichier de motifs est illisible ou le JSON invalide, le script laisse passer. Un garde-fou cassé qui bloque *toutes* les commandes serait désactivé dans l'heure ; un garde-fou cassé qui laisse passer se fait rattraper par la suite de tests.
- **Extraction JSON en cascade** : `jq` s'il existe, sinon `node` (toujours présent sur une machine qui fait tourner Claude Code), sinon `grep -oP` + désescapage `sed`. Aucune dépendance à installer.
- Le message d'erreur dit à l'agent **quoi faire d'un faux positif** (mettre le texte dans un fichier, ou ajuster le motif puis relancer les tests) — sinon l'agent réessaie en boucle des variantes de la même commande.

## 4. Installation et câblage Claude Code

```bash
# Depuis Git Bash :
mkdir -p ~/.agents/hooks
cp hooks/* ~/.agents/hooks/
chmod +x ~/.agents/hooks/deny-dangerous.sh ~/.agents/hooks/test-guard.sh
~/.agents/hooks/test-guard.sh    # doit finir par : passed: 52, failed: 0
```

Trouvez le chemin Windows de votre bash de Git :

```powershell
(Get-Command bash).Source
# ex. C:\Users\<vous>\AppData\Local\Programs\Git\usr\bin\bash.exe
# ou  C:\Program Files\Git\usr\bin\bash.exe
```

Puis, dans `~/.claude/settings.json`, ajoutez le bloc `hooks` (fusionnez si le fichier existe — n'écrasez pas vos autres réglages) :

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|PowerShell",
        "hooks": [
          {
            "type": "command",
            "command": "C:/Users/<vous>/AppData/Local/Programs/Git/usr/bin/bash.exe C:/Users/<vous>/.agents/hooks/deny-dangerous.sh"
          }
        ]
      }
    ]
  }
}
```

Trois détails qui ont chacun leur importance :

- **Matcher `Bash|PowerShell`** : sous Windows, Claude Code expose *deux* outils shell. Le tableau de câblage du guide original ne mentionne que `Bash` — un garde-fou qui ignore l'outil PowerShell laisse passer la moitié des commandes.
- **Chemins absolus, séparateurs `/`** : l'expansion de `~` n'est pas fiable d'un agent à l'autre, et les barres obliques évitent l'enfer de l'échappement des `\` en JSON.
- **Espaces dans le chemin** : si votre Git est dans `C:\Program Files\Git`, le chemin contient une espace et devra être entouré de guillemets dans la valeur `command` (`"\"C:/Program Files/Git/usr/bin/bash.exe\" C:/Users/..."`). L'installation par utilisateur (`AppData\Local\Programs\Git`) donne un chemin sans espace — plus robuste à travers les couches cmd/PowerShell.

Les hooks sont chargés **au démarrage de session** : les sessions déjà ouvertes ne sont pas protégées, relancez-les.

## 5. Les deux pièges Windows (chacun désactive le garde-fou en silence)

### Piège n° 1 : le code de sortie 2 est avalé par le wrapper PowerShell

La recette Unix repose sur « le hook sort avec le code 2 ⇒ la commande est bloquée ». Sous Windows, Claude Code lance la commande de hook à travers une couche shell qui **ne propage pas le code de sortie natif** (comportement PowerShell notoire : sans `exit $LASTEXITCODE` explicite, le code du processus enfant est perdu). Résultat observé pendant la mise au point : le garde décidait de bloquer, sortait avec le code 2… et `git push --force` s'exécutait quand même.

Le diagnostic qui l'a prouvé : un log de décision temporaire dans le script (`echo "DECISION: BLOCK pattern=..." >> guard-debug.log`) montrait `BLOCK` pendant que la session agent rapportait l'erreur de git — donc la commande avait bien tourné *après* la décision de blocage.

La parade : Claude Code accepte un **second protocole de blocage**, indépendant du code de sortie — un JSON `permissionDecision: "deny"` sur stdout avec code de sortie 0. Le stdout traverse les wrappers intact. Le script émet **les deux** : le JSON pour survivre aux wrappers, stderr + exit 2 pour les agents qui lancent le script directement (Codex, Devin).

### Piège n° 2 : ne jamais dépendre de `$HOME` ni de `PATH` dans le script

Quand un hôte d'agent lance `bash.exe` avec un environnement Windows minimal, deux choses manquent : `$HOME` (le script ne trouve plus la denylist) et le `/usr/bin` de MSYS dans `PATH` (`dirname`, `grep`, `sed` introuvables). Combiné au fail-open, chaque cas donne un garde-fou qui laisse tout passer sans un mot : `[ -r "$PATTERNS" ] || exit 0` d'un côté, `grep` qui échoue dans un `if` silencieux de l'autre.

La parade, dans les premières lignes du script :

```bash
PATH="/usr/bin:$PATH"                                  # coreutils MSYS toujours joignables
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
PATTERNS="${AGENT_GUARD_PATTERNS:-${SCRIPT_DIR:-$HOME/.agents/hooks}/dangerous-patterns.txt}"
```

La denylist est résolue **relativement au script lui-même**, pas au home. Testez ce cas explicitement :

```bash
echo '{"tool_input":{"command":"rm -rf /"}}' | env -u HOME \
  "C:/Users/<vous>/AppData/Local/Programs/Git/usr/bin/bash.exe" \
  "C:/Users/<vous>/.agents/hooks/deny-dangerous.sh"; echo "exit=$?"   # attendu : exit=2
```

Dernier détail du même acabit : si vous éditez les fichiers avec un outil Windows, vérifiez les fins de ligne. Un `\r` en bout de motif casse le `grep` sans erreur visible (`sed -i 's/\r$//' ~/.agents/hooks/*` règle la question ; le script tronque aussi les `\r` par défense).

## 6. Vérification de bout en bout

Le test direct (section 5) ne prouve que le script. Il faut aussi prouver le **câblage** : la sonde sûre du guide original consiste à demander à l'agent d'exécuter `git push --force` depuis un dossier qui n'est **pas** un dépôt git. Deux issues possibles, aucune dangereuse :

```bash
cd "$(mktemp -d)"
claude -p 'Run exactly: git push --force. Report the result in one line.' --permission-mode bypassPermissions
```

- ✅ Réponse « bloqué par le hook » : le garde-fou fonctionne à travers toute la chaîne.
- ❌ Réponse « fatal: not a git repository » : **git a tourné**, le blocage a échoué quelque part (relisez la section 5) — mais aucun dégât.

Contre-épreuve, pour vérifier que vous n'avez pas tout bloqué :

```bash
claude -p 'Run exactly this shell command: echo guard-ok. Report the output in one line.' --permission-mode bypassPermissions
```

## 7. Faire évoluer les motifs

1. Éditez `~/.agents/hooks/dangerous-patterns.txt`.
2. Ajoutez **un cas bloqué et un cas permis** dans `test-guard.sh` — le cas permis est le plus important : c'est lui qui vous protège du sur-blocage.
3. Relancez `test-guard.sh`. `failed: 0` ou on ne garde pas le motif.

**Le faux positif classique** : une commande inoffensive dont un *argument* contient le texte d'une commande dangereuse (transmettre une consigne qui mentionne `git push --force`, écrire ce guide…). C'est inhérent à l'approche regex. Contournement : mettre le texte dans un fichier et passer le chemin.

## 8. Limites connues

- Une regex ne voit que la surface : obfuscation, scripts téléchargés puis exécutés, `python -c` destructeur passent. Ceinture de sécurité, pas sandbox.
- Les agents exécutés dans le cloud (tâches distantes) ne passent pas par vos hooks locaux.
- Les sessions ouvertes avant le câblage ne sont pas protégées.
- La sonde de la section 6 vérifie Claude Code ; si vous câblez d'autres agents sur le même trio de fichiers, refaites-la pour chacun.

## Crédits

Concept et convention `~/.agents/hooks/` : [skill `global-agent-guardrails` de David Ondrej](https://github.com/davidondrej/skills/tree/main/skills/ops-and-setup/global-agent-guardrails) (licence MIT). Les scripts de ce dépôt sont une réimplémentation originale pour Windows, écrite et vérifiée sur une machine réelle ; les deux pièges de la section 5 ont été découverts (et prouvés) pendant cette mise au point, en juillet 2026.

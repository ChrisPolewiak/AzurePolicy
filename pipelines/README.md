# pipelines/

Azure DevOps pipeline definitions. All pipelines are triggered manually (`trigger: none`).

| File | Stage | Consumes | Produces |
| --- | --- | --- | --- |
| `fetch-policies.yml` | A | GitHub Azure/Enterprise-Scale | artifact: `policy-source` |
| `rebuild-configuration.example.yml` ¹ | B | artifact: `policy-source` | artifact: `policy-generated` |
| `update-definitions.example.yml` ¹ | C | artifact: `policy-generated` | deploys policy definitions + initiatives to MG |
| `update-assignments.example.yml` ¹ | D | artifact: `policy-generated` | what-if or deploys policy assignments to tenant |
| `cleanup.yml` | E | (none) | lists or deletes managed policy resources in Azure |
| `sync-framework.example.yml` ¹ | — | GitHub ChrisPolewiak/AzurePolicy | commits updated framework files to ADO repo |

¹ Gitignored — copy from the `.example.yml` template at deployment time. See Initial ADO setup in [docs/README.md](../docs/README.md).

Pipelines C and D are independent — both consume `policy-generated` from Pipeline B
and can be run separately without re-running each other.

Artifact flow (key behavior):

- Stage A (`fetch-policies.yml`) publishes artifact `policy-source` (snapshot from `source/`).
- Stage B (`rebuild-configuration.yml`) downloads `policy-source`, generates files, and publishes artifact `policy-generated` (selected files from `bicep/` and `generated/`).
- Stage C (`update-definitions.yml`) downloads `policy-generated` and deploys; it does not publish a new artifact.
- Stage D (`update-assignments.yml`) downloads `policy-generated` and deploys/what-if; it does not publish a new artifact.

Each pipeline includes a final cleanup step (`condition: always()`) that removes restored/generated temporary files from the job workspace after execution.

Required ADO variables (`configuration/ado-env.yml`):

- `serviceConnectionName` - service connection used by AzureCLI tasks (pipelines C and D).
- `devopsManagedPool` - managed agent pool name used by all pipelines.

Copy `configuration/ado-env.example.yml` to `configuration/ado-env.yml` and fill in your values.
`ado-env.yml` is in `.gitignore` and stays local to your ADO repository.

Key manual-run parameters:

- `update-definitions.yml`: `targetInitiative` (default `*`), `targetDefinition` (default `*`), `deployPolicyDefinitions`, `deployInitiatives`
- `update-assignments.yml`: `deployPolicies`, `targetAssignment` (default `*`)
- `cleanup.yml`: `targetAssignment` (default `*`), `withDefinitions`, `delete` (default `false` = dry-run)
- `sync-framework.yml`: `frameworkVersion` (default `main`, tag or branch from GitHub), `dryRun` (default `true` = preview without commit)

## sync-framework.yml

Pipeline do synchronizacji plików szkieletu (framework) z repozytorium GitHub (`ChrisPolewiak/AzurePolicy`) do repozytorium ADO. Uruchamiany ręcznie — np. po wydaniu nowej wersji frameworka na GitHubie.

### Działanie

1. Pobiera (`checkout`) repozytorium ADO (`self`) oraz repozytorium GitHub (`framework`) jako `_framework_tmp`.
2. Kopiuje pliki z GitHub do ADO za pomocą `rsync`, **pomijając** pliki lokalne:
   - `source/own/` — własne definicje polityk
   - `configurations/` — lokalna konfiguracja wdrożeń
   - `scripts/deployment-config.json` — lokalny plik konfiguracyjny
   - `docs/*.tsv`, `docs/*.csv`, `docs/*.xlsx`, `docs/*.xls` — lokalne eksporty danych
3. Jeśli `dryRun=false`: commituje i pushuje zmiany do ADO z komunikatem `chore: sync framework <wersja> from GitHub [skip ci]`.
4. Jeśli `dryRun=true` (domyślnie): wyświetla podgląd zmian bez commitowania.

### Wymagania

- Zmienna `devopsManagedPool` w `configuration/ado-env.yml`.
- Plik `pipelines/sync-framework.yml` (gitignored) — skopiuj z `pipelines/sync-framework.example.yml` i ustaw własną nazwę service connection w polu `endpoint:`.
- Service connection GitHub w ADO (typ: GitHub) o nazwie zgodnej z `endpoint:` w Twoim `sync-framework.yml`.
- Agent musi mieć zainstalowane `rsync`.

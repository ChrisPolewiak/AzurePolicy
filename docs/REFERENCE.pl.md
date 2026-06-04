# Dokumentacja techniczna — Azure Policy as Code

Niniejszy dokument opisuje szczegóły techniczne repozytorium: formaty plików, opisy skryptów,
strukturę szablonów ARM JSON/Bicep oraz konfigurację centralną.

Instrukcja użytkowania (procesy dla operatora): [README.pl.md](README.pl.md)

---

## Spis treści

1. [Centralna konfiguracja — `deployment-config.json`](#centralna-konfiguracja--deployment-configjson)
2. [Skrypty](#skrypty)
   - [fetch-policies.sh](#fetch-policiessh)
   - [generate\_arm\_from\_source.py](#generate_arm_from_sourcepy)
   - [generate\_config\_from\_table.py](#generate_config_from_tablepy)
   - [validate-config.sh](#validate-configsh)
   - [create-ado-pipelines.sh](#create-ado-pipelinessh)
   - [cleanup.sh](#cleanupsh)
3. [Formaty plików TSV](#formaty-plików-tsv)
4. [Formaty plików JSON (generated/)](#formaty-plików-json-generated)
   - [initiatives.json](#initiativesjson)
   - [assignments.json](#assignmentsjson)
   - [parameters.json](#parametersjson)
5. [Struktura szablonów i Bicep](#struktura-szablonów-i-bicep)
6. [Śledzenie wersji snapshotu](#śledzenie-wersji-snapshotu)
7. [Rozbudowa — exemptions](#rozbudowa--exemptions)

---

## Centralna konfiguracja — `deployment-config.json`

Plik `configuration/deployment-config.json` zawiera wszystkie ścieżki i parametry wdrożenia.
Skrypty Pythona odczytują z niego domyślne wartości, dzięki czemu nie trzeba ich podawać w CLI.

```json
{
  "managementTag": "policy-by-code",
  "deployment": {
    "location": "germanywestcentral",
    "definitionManagementGroupId": "<GUID lub nazwa MG>"
  },
  "paths": {
    "configDir": "generated",
    "sourceDir": "source/EnterpriseALZ",
    "bicepDir": "bicep",
    "docsDir": "docs",
    "customDir": "source/own"
  },
  "sourceFiles": {
    "assignments": "configuration/policy-assignments.tsv",
    "assignmentsFallback": "configuration/policy-assignments.csv",
    "parameters": "configuration/policy-parameters.tsv",
    "parametersFallback": "configuration/policy-parameters.csv"
  },
  "outputFiles": {
    "initiatives": "generated/initiatives.json",
    "assignments": "generated/assignments.json",
    "parameters": "generated/parameters.json"
  },
  "bicepTemplates": {
    "policyDefinitions": "bicep/policyDefinitions",
    "policySetDefinitions": "bicep/policySetDefinitions",
    "assignments": "bicep/assignments.bicep",
    "policyAssignmentManagementGroup": "bicep/policyAssignmentManagementGroup.bicep",
    "policyAssignmentSubscription": "bicep/policyAssignmentSubscription.bicep"
  }
}
```

---

## Skrypty

### fetch-policies.sh

**Cel:** Pobiera snapshot definicji polityk z repozytorium
[Azure/Enterprise-Scale](https://github.com/Azure/Enterprise-Scale) i zapisuje je lokalnie.

**Użycie:**

```bash
scripts/fetch-policies.sh <tag-lub-commit-SHA>
```

**Działanie:**

1. Klonuje `Azure/Enterprise-Scale` do katalogu tymczasowego (`--depth 1`).
2. Sprawdza podany tag/commit.
3. Kopiuje zawartość `src/resources/Microsoft.Authorization/policyDefinitions/` do `source/policyDefinitions/`
   oraz `policySetDefinitions/` do `source/policySetDefinitions/` (za pomocą `rsync --delete`).
4. Zapisuje użytą wersję do `source/.snapshot-version`.

**Pliki wyjściowe:**

- `source/policyDefinitions/*.json` — indywidualne definicje polityk
- `source/policySetDefinitions/*.json` — inicjatywy (policy sets)
- `source/.snapshot-version` — aktualny tag/commit snapshotu

---

### generate_arm_from_source.py

**Cel:** Generuje indywidualne szablony ARM JSON dla definicji i inicjatyw na podstawie plików JSON w `source/`.
Uruchamiany po `fetch-policies.sh` w pipeline `rebuild-configuration`.

**Użycie:**

```bash
python3 scripts/generate_arm_from_source.py [--source-dir SOURCE] [--bicep-dir BICEP]
```

| Argument | Domyślnie (z deployment-config.json) | Opis |
|---|---|---|
| `--source-dir` | `source/` | Katalog ze snapshotami JSON |
| `--bicep-dir` | `bicep/` | Katalog wyjściowy dla szablonów ARM JSON |

**Działanie:**

1. Skanuje `source/policyDefinitions/*.json` → generuje `bicep/policyDefinitions/<name>.json`
2. Skanuje `source/policySetDefinitions/*.json` → generuje `bicep/policySetDefinitions/<name>.json`
3. Pomija warianty chmurowe `*.AzureChinaCloud.json` i `*.AzureUSGovernment.json` dla policy definitions, aby uniknąć duplikatów nazw.

Wygenerowane pliki **nie powinny być edytowane ręcznie** — każde uruchomienie skryptu je nadpisuje.

---

### generate_config_from_table.py

**Cel:** Przekształca dane tabelaryczne z TSV/CSV (eksport Excela) na pliki JSON używane przez wdrożenia przypisań.
Uruchamiany lokalnie lub w pipeline `update-assignments`.

**Użycie:**

```bash
python3 scripts/generate_config_from_table.py [opcje]
```

| Argument | Domyślnie | Opis |
|---|---|---|
| `--input` | `docs/policy-assignments.tsv` | Plik TSV/CSV z przypisaniami |
| `--output-dir` | `generated/` | Katalog wyjściowy dla JSON |
| `--params-input` | `configuration/policy-parameters.tsv` | Plik TSV/CSV z parametrami |
| `--suffix` | *(puste)* | Sufiks w nazwie pliku (np. `test` → `assignments-test.json`) |
| `--limit` | *(brak)* | Przetwórz tylko pierwsze N wierszy |
| `--location` | z `deployment-config.json` | Wartość `location` w każdym assignment |
| `--all` | *(nie ustawiony)* | Przetwórz wszystkie wiersze, łącznie z `Deploy=FALSE` |

**Przykłady:**

```bash
# Podgląd testowy — 3 rekordy, pliki z sufiksem -test
python3 scripts/generate_config_from_table.py --limit 3 --suffix test

# Generowanie docelowych plików
python3 scripts/generate_config_from_table.py

# Windows (PowerShell)
py .\scripts\generate_config_from_table.py --limit 3 --suffix test
```

**Obsługa delimitera:**

Skrypt automatycznie wykrywa separator kolumn:

- `.tsv` → `\t` (tab)
- `.csv` → `,` lub `;` (Polish Excel locale — heurystyka na podstawie pierwszego wiersza)

**Priorytet pliku wejściowego** (jeśli `--input` nie podano):

1. `sourceFiles.assignments` z `deployment-config.json`
2. `sourceFiles.assignmentsFallback` z `deployment-config.json`
3. Hardcoded: `configuration/policy-assignments.tsv`, `.csv`
4. Legacy fallback: `config/policy.tsv`

---

### validate-config.sh

**Cel:** Waliduje poprawność struktury plików `generated/*.json` przed wdrożeniem.

**Użycie:**

```bash
scripts/validate-config.sh
```

Sprawdza:
- poprawność JSON w `generated/initiatives.json`, `generated/assignments.json`, `generated/parameters.json`
- wymagane pola w każdym obiekcie (np. `name`, `definitionFile` w initiatives; `name`, `scope` w assignments)
- spójność referencji (każde `parametersKey` w assignments istnieje w `parameters.json`)

---

### create-ado-pipelines.sh

**Cel:** Tworzy wszystkie definicje pipeline’ów ADO z plików YAML w katalogu `pipelines/` przy użyciu Azure CLI (`az pipelines create`). Idempotentny — pomija pipeline'y, które już istnieją.

**Wymagania:**

- Azure CLI z rozszerzeniem `azure-devops` (`az extension add --name azure-devops`)
- Aktywne logowanie: `az login` lub kontekst service principal
- Plik `pipelines/sync-framework.yml` musi istnieć w repozytorium ADO przed utworzeniem tego pipeline'a (jest gitignored; najpierw skopiuj z `sync-framework.example.yml`)

**Użycie:**

```bash
scripts/create-ado-pipelines.sh --org <org-url> --project <project> [opcje]
```

| Opcja | Domyślnie | Opis |
| --- | --- | --- |
| `--org <url>` | *(wymagane)* | Pełny URL organizacji ADO **wraz z `https://`**, np. `https://dev.azure.com/MyOrg` |
| `--project <name>` | *(wymagane)* | Nazwa projektu ADO |
| `--repo <name>` | jak `--project` | Nazwa repozytorium ADO |
| `--branch <name>` | `main` | Domyślny branch dla wszystkich pipeline’ów |
| `--folder <path>` | `\AzurePolicy` | Ścieżka folderu w UI ADO |
| `--name-suffix <s>` | *(brak)* | Sufiks dołączany do każdej nazwy pipeline’a, np. `-DEV` lub `-PRD` |
| `--dry-run` | | Wyświetla co byłoby utworzone, bez wprowadzania zmian |

> **Uwaga:** `--org` wymaga pełnego adresu URL ze schematem `https://`, a nie samej nazwy organizacji.
> Skrypt weryfikuje ten format i kończy działanie z błędem, jeśli poda się samą nazwę.

**Tworzone pipeline'y:**

| Nazwa (bazowa) | Nazwa z sufiksem (przykład) | Ścieżka YAML |
| --- | --- | --- |
| `A-fetch-policies` | `A-fetch-policies-DEV` | `pipelines/fetch-policies.yml` |
| `B-rebuild-configuration` | `B-rebuild-configuration-DEV` | `pipelines/rebuild-configuration.yml` |
| `C-update-definitions` | `C-update-definitions-DEV` | `pipelines/update-definitions.yml` |
| `D-update-assignments` | `D-update-assignments-DEV` | `pipelines/update-assignments.yml` |
| `E-cleanup` | `E-cleanup-DEV` | `pipelines/cleanup.yml` |
| `F-sync-framework` | `F-sync-framework-DEV` | `pipelines/sync-framework.yml` |

> **Konfiguracja wielu środowisk:** pipeline'y B, C i D (`rebuild-configuration.yml`, `update-definitions.yml`,
> `update-assignments.yml`) zawierają zakodowane na stałe referencje `source:` do nazw pipeline’ów upstream.
> Te pliki są gitignored. Skopiuj z szablonów `.example.yml` i zastąp `<SUFFIX>`
> w każdym polu `source:` wartością podaną jako `--name-suffix`.

**Przykłady:**

```bash
# Podgląd z sufiksem środowiska
scripts/create-ado-pipelines.sh \
  --org https://dev.azure.com/MyOrg \
  --project AzurePolicy \
  --name-suffix -DEV \
  --dry-run

# Utwórz pipeline'y z sufiksem
scripts/create-ado-pipelines.sh \
  --org https://dev.azure.com/MyOrg \
  --project AzurePolicy \
  --name-suffix -DEV

# Jedno środowisko (bez sufiksu)
scripts/create-ado-pipelines.sh \
  --org https://dev.azure.com/MyOrg \
  --project AzurePolicy
```

---

### cleanup.sh

**Cel:** Wylistowuje lub usuwa przypisania polityk Azure, UAMIs oraz opcjonalnie definicje polityk
i inicjatywy zarządzane przez to repozytorium. Odpytuje Azure bezpośrednio — nie korzysta
z lokalnych plików `generated/*.json`.

Domyślne zachowanie (bez `--delete`): **tylko listowanie** — żadne zmiany nie są wykonywane.

**Użycie:**

```bash
scripts/cleanup.sh [--delete] [--with-definitions] [--assignment <name>]
```

| Flaga | Opis |
|---|---|
| *(brak flag)* | Tryb listowania: wyświetla zarządzane zasoby znalezione w Azure — bez zmian |
| `--delete` | Usuwa wylistowane zasoby |
| `--with-definitions` | Uwzględnia też niestandardowe definicje polityk i inicjatywy |
| `--assignment <name>` | Zawęża do jednego przypisania (ARM resource name / InternalID) |

**Sposób wykrywania zasobów:**

| Zasób | Metoda |
|---|---|
| Przypisania polityk | `az graph query` na tabeli `PolicyResources` po `properties.metadata.assignedBy` |
| UAMIs (tryb selektywny) | Wyodrębniane z `identity.userAssignedIdentities` znalezionego przypisania |
| UAMIs (tryb pełny) | `az identity list` filtrowane po tagu `managedBy` w skonfigurowanej grupie zasobów |
| Definicje polityk | `az policy definition list` filtrowane po `properties.metadata.managedBy` |
| Inicjatywy | `az policy set-definition list` filtrowane po `properties.metadata.managedBy` |

Wszystkie wartości są porównywane z `managementTag` w `configuration/deployment-config.json`.

**Przykłady:**

```bash
# Lista zarządzanych zasobów (bez zmian)
scripts/cleanup.sh

# Lista zasobów wraz z definicjami
scripts/cleanup.sh --with-definitions

# Usunięcie wszystkich zarządzanych przypisań i UAMIs
scripts/cleanup.sh --delete

# Usunięcie jednego przypisania i jego UAMI
scripts/cleanup.sh --assignment AP202604290022 --delete
```

---

## Formaty plików TSV

Pełna dokumentacja kolumn z przykładami: [docs/TSV-FORMAT.md](docs/TSV-FORMAT.md)

---

## Formaty plików JSON (generated/)

Pliki generowane przez `generate_config_from_table.py` i konsumowane przez Bicep przy wdrożeniu.

### initiatives.json

Tablica obiektów; każda inicjatywa pojawia się maksymalnie raz (deduplikacja po nazwie).

```json
[
  {
    "internalId": "ap001",
    "name": "Enforce-ALZ-Decomm",
    "definitionFile": "source/policySetDefinitions/Enforce-ALZ-Decomm.json",
    "enabled": true
  }
]
```

| Pole | Opis |
|---|---|
| `internalId` | Wartość z kolumny `InternalID` pierwszego wiersza dla tej inicjatywy |
| `name` | Nazwa inicjatywy (klucz dla assignmentów) |
| `definitionFile` | Ścieżka względem root repo do pliku JSON snapshotu |
| `enabled` | Zawsze `true` dla wierszy z `Deploy=TRUE` |

### assignments.json

Tablica obiektów; jedno przypisanie na wiersz TSV z `Deploy=TRUE`.

```json
[
  {
    "internalId": "ap001",
    "name": "Enforce-ALZ-Decomm-mg-root",
    "scope": {
      "type": "managementGroup",
      "id": "mg-contoso-root"
    },
    "enforcementMode": "Default",
    "location": "germanywestcentral",
    "managed": "policy-by-code",
    "metadata": {
      "assignedBy": "policy-by-code"
    },
    "initiativeName": "Enforce-ALZ-Decomm",
    "parametersKey": "Enforce-ALZ-Decomm-Default"
  }
]
```

**Pole `managed`:** Wartość pochodzi z `managementTag` w `configuration/deployment-config.json`.
Umożliwia szybkie filtrowanie w lokalnych plikach JSON.

**Pole `metadata.assignedBy`:** Przekazywane do Azure przy wdrożeniu przypisania.
Portal Azure wyświetla je jako pole **"Assigned by"** w szczegółach przypisania.
Skrypt `cleanup.sh` używa tego pola do wyszukiwania zarządzanych przypisań w Azure.

Wartość obu pól pochodzi z `managementTag` w `configuration/deployment-config.json`.

### parameters.json

Obiekt słownikowy; klucze to `Parameter Set` z tabeli przypisań.

```json
{
  "Enforce-ALZ-Decomm-Default": {
    "allowedLocations": {
      "value": ["germanywestcentral", "northeurope"]
    },
    "effect": {
      "value": "Audit"
    }
  }
}
```

---

## Struktura szablonów i Bicep

### bicep/main.bicep

`targetScope = 'tenant'` — wdrożenie na poziomie tenanta.

Orkiestruje trzy moduły:

| Moduł | Plik | Opis |
|---|---|---|
| `policyDefinitions` | `bicep/policyDefinitions.bicep` | Historycznie wdrażał definicje polityk do MG |
| `policySetDefinitions` | `bicep/policySetDefinitions.bicep` | Historycznie wdrażał inicjatywy do MG |
| `assignments` | `bicep/assignments.bicep` | Wdraża przypisania (MG i Sub) |

W aktualnym procesie CI/CD moduł `main.bicep` nie jest używany przez pipeline'y do wdrażania definicji i inicjatyw.
Definicje oraz inicjatywy są wdrażane przez `scripts/update-definitions.sh` jako oddzielne deploymenty ARM JSON per plik.

Parametry wejściowe `main.bicep`:

- `definitionManagementGroupId` — Management Group dla definicji
- `initiatives` — tablica z `generated/initiatives.json`
- `assignments` — tablica z `generated/assignments.json`
- `parameterSets` — obiekt z `generated/parameters.json`

### bicep/policyDefinitions/ (AUTO-GENERATED)

- Katalog z indywidualnymi szablonami ARM JSON, jeden plik na definicję polityki.
- Każdy plik zawiera pojedynczy resource `Microsoft.Authorization/policyDefinitions@2023-04-01`.
- Wdrażany w pętli przez `scripts/update-definitions.sh`.
- **Nie edytować ręcznie** — regenerowany przez `generate_arm_from_source.py`.

### bicep/policySetDefinitions/ (AUTO-GENERATED)

- Katalog z indywidualnymi szablonami ARM JSON, jeden plik na inicjatywę.
- Każdy plik zawiera pojedynczy resource `Microsoft.Authorization/policySetDefinitions@2023-04-01`.
- Wdrażany w pętli przez `scripts/update-definitions.sh`.
- **Nie edytować ręcznie** — regenerowany przez `generate_arm_from_source.py`.

### bicep/assignments.bicep

Iteruje po tablicy `assignments` i wywołuje moduły:
- `policyAssignmentManagementGroup.bicep` dla scope `managementGroup`
- `policyAssignmentSubscription.bicep` dla scope `subscription`

---

## Śledzenie wersji snapshotu

Plik `source/.snapshot-version` przechowuje tag lub commit SHA użyty podczas ostatniego
uruchomienia `fetch-policies.sh`.

```bash
# Sprawdź bieżącą wersję
cat source/.snapshot-version

# Porównaj z dostępnymi tagami na GitHub
# https://github.com/Azure/Enterprise-Scale/releases
```

Plik jest automatycznie aktualizowany przez skrypt i powinien być commitowany do repozytorium
razem z plikami w `source/`.

---

## Rozbudowa — exemptions

Aby dodać obsługę wyjątków (Policy Exemptions):

1. Utwórz `generated/exemptions.json` z tablicą wyjątków (analogicznie do `assignments.json`).
2. Utwórz `bicep/exemptions.bicep` z pętlą resource `Microsoft.Authorization/policyExemptions@2022-07-01-preview`.
3. Dodaj moduł `exemptions` do `bicep/main.bicep`.
4. Opcjonalnie rozszerz `generate_config_from_table.py` o obsługę dodatkowej zakładki Excel.

# Azure Policy by Code

Repozytorium wdraża definicje i przypisania Azure Policy w modelu Policy as Code, zgodnym z podejściem Azure Landing Zone (ALZ / Enterprise Scale).

Szczegóły techniczne (formaty plików, opisy skryptów, struktura Bicep): [REFERENCE.pl.md](REFERENCE.pl.md)

---

## Spis treści

1. [Struktura repozytorium](#struktura-repozytorium)
2. [Konfiguracja początkowa ADO](#konfiguracja-początkowa-ado-jednorazowo)
3. [Proces A — fetch-policies](#proces-a--fetch-policies)
4. [Proces B — rebuild-configuration](#proces-b--rebuild-configuration)
5. [Proces C — update-definitions](#proces-c--update-definitions)
6. [Proces D — update-assignments](#proces-d--update-assignments)
7. [Proces F — sync-framework](#proces-f--sync-framework)

---

## Struktura repozytorium

```text
.
├── bicep/
│   ├── policyDefinitions/                # AUTO-GENERATED ARM JSON — w .gitignore, przekazywany przez artefakt
│   ├── policySetDefinitions/             # AUTO-GENERATED ARM JSON — w .gitignore, przekazywany przez artefakt
│   ├── assignments.bicep                 # Iteruje po assignments.json i wywołuje moduły MG/Sub
│   ├── policyAssignmentManagementGroup.bicep  # Moduł przypisania do Management Group
│   └── policyAssignmentSubscription.bicep     # Moduł przypisania do Subscription
├── generated/
│   ├── initiatives.json                  # AUTO-GENERATED — w .gitignore, przekazywany przez artefakt
│   ├── assignments.json                  # AUTO-GENERATED — w .gitignore, przekazywany przez artefakt
│   └── parameters.json                   # AUTO-GENERATED — w .gitignore, przekazywany przez artefakt
├── source/
│   ├── EnterpriseALZ/
│   │   ├── policyDefinitions/            # Snapshot JSON z GitHub Azure/Enterprise-Scale
│   │   ├── policySetDefinitions/         # Snapshot JSON z GitHub Azure/Enterprise-Scale
│   │   └── .snapshot-version             # Aktualna wersja/tag snapshotu z GH
│   ├── own/
│   │   ├── policyDefinitions/            # Własne definicje polityk
│   │   └── policySetDefinitions/         # Własne inicjatywy polityk
├── configuration/
│   ├── deployment-config.json            # Lokalna konfiguracja runtime (ignorowana przez git)
│   ├── deployment-config.example.json    # Szablon deployment-config.json
│   ├── Azure-Policy.xlsx                 # Źródło prawdy — przypisania (do edycji)
│   ├── policy-assignments.tsv            # Export z Excela — dane dla skryptu
│   ├── policy-parameters.tsv             # Export z Excela — dane dla skryptu
│   └── README.md                         # Notatki migracyjne dla lokalizacji konfiguracji
├── docs/
├── pipelines/
│   ├── fetch-policies.yml                # Pipeline A: pobierz snapshot GH → artefakt policy-source
│   ├── rebuild-configuration.yml         # Pipeline B: pobierz policy-source → generuj → artefakt policy-generated
│   ├── update-definitions.yml            # Pipeline C: pobierz policy-generated → wdróż do MG
│   └── update-assignments.yml            # Pipeline D: pobierz policy-generated → what-if → wdróż do tenant
├── scripts/
│   ├── fetch-policies.sh                 # Pobiera snapshot z GitHub Azure/Enterprise-Scale
│   ├── rebuild-configuration.sh          # Generuje ARM JSON + config JSON + walidacja
│   ├── update-definitions.sh             # Wdraża policyDefinitions i policySetDefinitions do Management Group
│   ├── update-assignments.sh             # What-if + opcjonalny deploy przypisań do tenant
│   ├── generate_arm_from_source.py  # Generuje ARM JSON szablony dla polityk i inicjatyw
│   ├── generate_config_from_table.py     # Generuje generated/*.json z plików TSV/CSV
│   └── validate-config.sh                # Waliduje poprawność generated/*.json przed wdrożeniem
└── REFERENCE.md                          # Dokumentacja techniczna
```

---

## Konfiguracja początkowa ADO (jednorazowo)

Przed pierwszym uruchomieniem dowolnego pipeline’a utwórz lokalne pliki konfiguracyjne w repozytorium ADO:

1. Skopiuj `configuration/ado-env.example.yml` jako `configuration/ado-env.yml`.
2. Uzupełnij wartości:
   - `devopsManagedPool` — nazwa puli agentów ADO (np. `Default` lub pula self-hosted).
   - `serviceConnectionName` — nazwa Azure DevOps service connection do zadań Azure CLI.
3. Skopiuj `pipelines/sync-framework.example.yml` jako `pipelines/sync-framework.yml`.
4. W pliku `sync-framework.yml` ustaw pole `endpoint:` na nazwę swojego GitHub service connection w ADO.
5. Oba pliki są w `.gitignore` — pozostają tylko w repozytorium ADO, nigdy nie trafiają na GitHub.

> Konfiguracja service connection: ADO **Project Settings** → **Service connections** → **New service connection** → **Azure Resource Manager** → Service principal (automatic).
> Nadaj mu uprawnienia **Contributor** + **User Access Administrator** na poziomie Management Group.

---

## Proces A — fetch-policies

Stosuj gdy Microsoft wypuścił nową wersję definicji w repozytorium
[Azure/Enterprise-Scale](https://github.com/Azure/Enterprise-Scale) i chcesz zaktualizować snapshoty.

Pipeline wykonuje `fetch-policies.sh` i **publikuje artefakt `policy-source`** (katalog `source/`), który jest wejściem dla Procesu B.

> `source/` jest w `.gitignore` — nie trafia do repozytorium, żyje tylko jako artefakt pipeline'a.

### Krok A1 — Sprawdź aktualną wersję snapshotu

Sprawdź listę tagów/commitów na GitHubie: <https://github.com/Azure/Enterprise-Scale/releases>

### Krok A2 — Uruchom pipeline fetch-policies

Uruchom pipeline **`fetch-policies`** (ręcznie, trigger: none):

| Parametr | Domyślnie | Opis |
| --- | --- | --- |
| `policyVersion` | `main` | Tag lub commit SHA z Azure/Enterprise-Scale |

Pipeline wykonuje:

1. `fetch-policies.sh <policyVersion>` — klonuje Enterprise-Scale i kopiuje JSON do `source/`
2. Publikuje artefakt **`policy-source`** (`source/`)

### Krok A2 (alternatywa — lokalnie)

```bash
./scripts/fetch-policies.sh
```

---

## Proces B — rebuild-configuration

Stosuj gdy zmieniasz **które inicjatywy są aktywne** (dodajesz/usuwasz inicjatywy z `configuration/Azure-Policy.xlsx`) lub aktualizujesz definicje z nowego snapshotu.

Pipeline pobiera artefakt `policy-source` z Procesu A, generuje wszystkie pliki i **publikuje artefakt `policy-generated`** (ARM JSON + config JSON), który jest wejściem dla Procesów C i D.

> `bicep/policyDefinitions/*.json`, `bicep/policySetDefinitions/*.json` i `generated/*.json`
> są w `.gitignore` — nie trafiają do repozytorium, żyją tylko jako artefakty pipeline'a.

### Krok B1 — Zaktualizuj listę inicjatyw i przypisań w Excelu

Otwórz `configuration/Azure-Policy.xlsx` i zmodyfikuj odpowiednie zakładki (przypisania i/lub parametry).

### Krok B2 — Eksportuj zmiany do TSV

W Excelu dla każdej zmienionej zakładki:

1. Zaznacz całą tabelę (łącznie z nagłówkami) → skopiuj (`Ctrl+C`)
2. Otwórz odpowiedni plik TSV w VS Code:
   - przypisania → `configuration/policy-assignments.tsv`
   - parametry → `configuration/policy-parameters.tsv`
3. Zaznacz całą zawartość (`Ctrl+A`), wklej (`Ctrl+V`), zapisz

### Krok B3 — Zatwierdź zmiany i uruchom pipeline

```bash
git add configuration/policy-assignments.tsv configuration/policy-parameters.tsv
git commit -m "feat: update initiatives — <opis zmian>"
git push
```

Uruchom pipeline **`rebuild-configuration`** (ręcznie, trigger: none):

| Parametr | Domyślnie | Opis |
| --- | --- | --- |
| `policyVersion` | `main` | Tag lub commit SHA z Azure/Enterprise-Scale (źródło artefaktu A) |

Przy uruchomieniu ADO zapyta o wybór runa Pipeline A — wybierz ten z właściwą wersją
albo zostaw domyślny (ostatni udany).

Pipeline wykonuje:

1. Pobiera artefakt **`policy-source`** z Pipeline A
2. `rebuild-configuration.sh` — generuje ARM JSON + config JSON + walidacja
3. Publikuje artefakt **`policy-generated`** (`bicep/` + `generated/`)

### Krok B3 (alternatywa — lokalnie)

```bash
# Zakładając że source/ jest już wypełniony przez fetch-policies.sh
./scripts/rebuild-configuration.sh
```

> **Następny krok:** Uruchom **Proces C** (`update-definitions`) i/lub **Proces D** (`update-assignments`).

---

## Proces C — update-definitions

Stosuj po **Procesie B** — wdraża zaktualizowane definicje polityk i inicjatywy (`bicep/policyDefinitions/*.json`, `bicep/policySetDefinitions/*.json`) do Management Group.

Pipeline pobiera artefakt `policy-generated` z Procesu B (zawiera ARM JSON + config JSON) i uruchamia `update-definitions.sh`.

### Krok C1 — Uruchom pipeline update-definitions

Uruchom pipeline **`update-definitions`** (ręcznie, trigger: none):

| Parametr | Domyślnie | Opis |
| --- | --- | --- |
| `location` | `germanywestcentral` | Lokalizacja metadanych wdrożenia |
| `targetInitiative` | `''` | Opcjonalnie: wdrażaj tylko jedną inicjatywę |
| `targetDefinition` | `''` | Opcjonalnie: wdrażaj tylko jedną definicję polityki |
| `deployPolicyDefinitions` | `true` | Wdrażaj etap definicji polityk |
| `deployInitiatives` | `true` | Wdrażaj etap definicji inicjatyw |

Wymagane zmienne (`configuration/ado-env.yml`):

- `serviceConnectionName` — nazwa Azure DevOps service connection używanej przez `AzureCLI@2` (`azureSubscription`).
- `devopsManagedPool` — nazwa puli agentów używanej przez pipeline (`pool.name`).

Przy uruchomieniu ADO zapyta o wybór runa Pipeline B — wybierz właściwy lub zostaw domyślny (ostatni udany).

Pipeline wykonuje:

1. Pobiera artefakt **`policy-generated`** z Pipeline B
2. `update-definitions.sh` — walidacja + pętla `az deployment mg create` dla każdego pliku w `bicep/policyDefinitions/*.json` (definicje używają `metadata.targetManagementGroup`, jeśli istnieje; w przeciwnym razie używany jest fallback `definitionManagementGroupId`)
3. `update-definitions.sh` — pętla `az deployment mg create` dla każdego pliku w `bicep/policySetDefinitions/*.json`

Przykłady selektywnego uruchomienia z UI pipeline:

- ustaw `targetInitiative=Enforce-Guardrails-VirtualDesktop`, aby wdrożyć tylko jedną inicjatywę
- ustaw `targetDefinition=Deploy-ANMVnetPeering`, aby wdrożyć tylko jedną definicję polityki
- ustaw `deployPolicyDefinitions=false`, aby pominąć etap definicji polityk
- ustaw `deployInitiatives=false`, aby pominąć etap definicji inicjatyw

### Krok C1 (alternatywa — lokalnie)

```bash
# Zakładając że bicep/ i generated/ są wypełnione przez rebuild-configuration.sh
./scripts/update-definitions.sh

# Tylko z nadpisaniem lokalizacji:
./scripts/update-definitions.sh --location germanywestcentral

# Opcjonalnie: nadpisanie management group dla inicjatyw (oraz fallback dla definicji bez metadata.targetManagementGroup):
./scripts/update-definitions.sh --location germanywestcentral --management-group your-management-group-id
```

---

## Proces D — update-assignments

Stosuj gdy chcesz zaktualizować **przypisania i parametry** — bez zmiany definicji inicjatyw.
Można uruchamiać niezależnie od Procesów A–C pod warunkiem, że artefakt `policy-generated` z Procesu B jest dostępny (lub pliki są lokalnie wygenerowane).

### Krok D1 — Edytuj plik Excel z przypisaniami

Otwórz `configuration/Azure-Policy.xlsx`.

Tabela zawiera m.in. kolumny pomocnicze (nie przetwarzane przez skrypt):

- **AzAdvertizer Link** — link do podglądu polityki na azadvertizer.net
- **Version** — wersja definicji z GH, na której oparliśmy przypisanie

Kolumny przetwarzane przez skrypt — opis w [REFERENCE.md → Kolumny TSV](REFERENCE.md#kolumny-w-policy-assignmentstsv).

### Krok D2 — Edytuj parametry (jeśli potrzeba)

Otwórz `configuration/Azure-Policy.xlsx` → zakładka **Parameters** i zaktualizuj wartości parametrów dla odpowiednich zestawów (Parameter Set).

### Krok D3 — Eksportuj zmiany do TSV

W Excelu dla każdej zmienionej zakładki:

1. Zaznacz całą tabelę z danymi (łącznie z nagłówkami)
2. Skopiuj (`Ctrl+C`)
3. Otwórz odpowiedni plik TSV w VS Code:
   - przypisania → `configuration/policy-assignments.tsv`
   - parametry → `configuration/policy-parameters.tsv`
4. Zaznacz całą zawartość (`Ctrl+A`) i wklej (`Ctrl+V`)
5. Zapisz

### Krok D4 — Zatwierdź zmiany i uruchom pipeline

```bash
git add configuration/policy-assignments.tsv configuration/policy-parameters.tsv
git commit -m "feat: update policy assignments — <opis zmian>"
git push
```

Uruchom pipeline **`update-assignments`** (ręcznie, trigger: none):

| Parametr | Domyślnie | Opis |
| --- | --- | --- |
| `location` | `germanywestcentral` | Lokalizacja metadanych wdrożenia |
| `deployPolicies` | `false` | Czy wdrożyć przypisania do Azure (`false` = tylko what-if) |
| `targetAssignment` | `''` | Opcjonalnie: przetwarzaj tylko jedną nazwę przypisania |

Wymagane zmienne (`configuration/ado-env.yml`):

- `serviceConnectionName` — nazwa Azure DevOps service connection używanej przez `AzureCLI@2` (`azureSubscription`).
- `devopsManagedPool` — nazwa puli agentów używanej przez pipeline (`pool.name`).

Uwaga: docelowy scope przypisania zawsze pochodzi z elementu w `generated/assignments.json`
(`scope.type` + `scope.id`). ID definicji jest rozwiązywane z danych przypisania
(`policyDefinitionId` jeśli jest, w przeciwnym razie nazwy).
`definitionManagementGroupId` jest pobierane z `configuration/deployment-config.json`
(domyślne ustawienia deploymentu), a nie z Library.
Dla RBAC UAMI efektywny scope nadań ról pochodzi z `generated/assignment-identities.json`
(`roleAssignments[].scope`), a nie z `definitionManagementGroupId`.

Przy uruchomieniu ADO zapyta o wybór runa Pipeline B — wybierz właściwy lub zostaw domyślny (ostatni udany).

Pipeline wykonuje:

1. Pobiera artefakt **`policy-generated`** z Pipeline B
2. `update-assignments.sh` — generuje `generated/*.json` + walidacja + `az deployment tenant what-if`
3. *(opcjonalnie gdy `deployPolicies=true`)* `az deployment tenant create`

> **Tip:** Domyślnie (`deployPolicies=false`) pipeline wykonuje tylko what-if bez wdrożenia.
> Ustaw `deployPolicies=true` dopiero po weryfikacji wyniku what-if.

### Krok D4 (alternatywa — lokalnie)

```bash
# Tylko what-if (podgląd zmian)
./scripts/update-assignments.sh

# Faktyczne wdrożenie
./scripts/update-assignments.sh --deploy

# Z nadpisaniem parametrów:
./scripts/update-assignments.sh --deploy --location germanywestcentral --management-group your-management-group-id

# Tylko jedno przypisanie (what-if):
./scripts/update-assignments.sh --assignment AP2026-04-28_0015

# Tylko jedno przypisanie (wdrożenie) — przydatne przy testowaniu lub wdrażaniu po kolei:
./scripts/update-assignments.sh --assignment AP2026-04-28_0015 --deploy
```

---

## Proces F — sync-framework

Stosuj gdy w repozytorium GitHub (`ChrisPolewiak/AzurePolicy`) ukazuje się nowa wersja frameworka (pipeline'y, skrypty, moduły Bicep) i chcesz ciągnąć ją do repozytorium ADO bez nadpisywania lokalnej konfiguracji.

> Pipeline synchronizuje **wyłącznie pliki frameworka** — nigdy nie dotyka `source/own/`, `configurations/`, `scripts/deployment-config.json` ani lokalnych eksportów danych w `docs/`.

### Wymaganie wstępne — service connection do GitHub

Zanim pipeline będzie mógł być uruchomiony po raz pierwszy, utwórz **service connection** do GitHuba w Azure DevOps o dokładnie takiej nazwie jak oczekuje pipeline:

```
sc-chrispolewiak-github-azurepolicy
```

Kroki:

1. W ADO przejdź do **Project Settings → Service connections → New service connection**.
2. Wybierz **GitHub**.
3. Wybierz metodę uwierzytelnienia — rekomendowana: **GitHub App** lub **Personal Access Token (PAT)**.
   - PAT wymaga co najmniej zakresu `repo` (odczyt).
4. W polu **Service connection name** wpisz dowolną nazwę (zgodną z Twoją polityką nazewnictwa).
5. Zaznacz **Grant access permission to all pipelines** (lub ogranicz do pipeline `sync-framework`).
6. Zapisz.

Następnie zaktualizuj pole `endpoint:` w lokalnym pliku `pipelines/sync-framework.yml` tak, by zgadzało się z wybraną nazwą.

### Krok F1 — Uruchom pipeline sync-framework

Uruchom pipeline **`sync-framework`** (ręcznie, trigger: none):

| Parametr | Domyślnie | Opis |
| --- | --- | --- |
| `frameworkVersion` | `main` | Tag lub branż z GitHuba `ChrisPolewiak/AzurePolicy` |
| `dryRun` | `true` | `true` = tylko podgląd (bez commitu), `false` = commit i push do ADO |

Pipeline wykonuje:

1. Pobiera (`checkout`) repozytorium ADO (`self`) z `persistCredentials: true`.
2. Pobiera (`checkout`) repozytorium GitHub (`framework`) do katalogu `_framework_tmp`.
3. Kopiuje pliki z GitHub do ADO przez `rsync`, **pomijając** ścieżki lokalne:
   - `source/own/` — własne definicje polityk
   - `configurations/` — lokalna konfiguracja wdrożeń
   - `scripts/deployment-config.json`
   - `docs/*.tsv`, `docs/*.csv`, `docs/*.xlsx`, `docs/*.xls`
4. Jeśli `dryRun=false`: commituje i pushuje zmiany z komunikatem `chore: sync framework <wersja> from GitHub [skip ci]`.
5. Jeśli `dryRun=true` (domyślnie): wyświetla `git status` i `git diff --stat HEAD` bez commitowania.

> **Wskazówka:** Zawsze uruchamiaj najpierw z `dryRun=true`, żeby sprawdzić co się zmieni przed commitem.

---

## Dalsza rozbudowa

Rekomendowany kolejny krok:

- dodać obsługę exemptions przez `generated/exemptions.json` i `bicep/exemptions.bicep`.

---

## Licencja i podziękowania

Projekt udostępniony na licencji [MIT](LICENSE).

Definicje i inicjatywy polityk pochodzą z repozytorium
[Azure/Enterprise-Scale](https://github.com/Azure/Enterprise-Scale) firmy Microsoft,
również opublikowanego na licencji MIT.

Projekt powstał przy użyciu [Visual Studio Code](https://code.visualstudio.com/)
oraz [Claude AI](https://www.anthropic.com/claude) firmy Anthropic.

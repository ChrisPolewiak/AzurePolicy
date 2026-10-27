# Przewodnik operatora

[English](README.md) | [Dokumentacja techniczna](REFERENCE.pl.md) | [Format TSV](../configuration/TSV-FORMAT.md)

## Co uruchomić?

| Chcę... | Co robię |
| --- | --- |
| Wdrożyć po raz pierwszy | Konfiguracja poniżej, potem **A → B → C → D** |
| Zmienić scope, parametry lub aktywne wiersze przypisań | Excel, eksport TSV, potem **B → D** |
| Zmienić własną politykę lub inicjatywę | Edycja `source/own/`, potem **B → C → D** |
| Zaktualizować definicje Microsoft ALZ | **A → B → C → D** |
| Podejrzeć zmiany przypisań | **D** z `deployMode=whatif` |
| Usunąć zarządzane zasoby polityk | **E**, najpierw samo wyświetlenie listy |
| Zaktualizować skrypty, moduły i szablony pipeline'ów z GitHub | **F**, najpierw podgląd |

**B buduje, C i D wdrażają.** Sama zmiana Excela niczego nie zmienia w Azure.
Jeśli potrzebne są nowe definicje, wdróż je krokiem C przed D.
Usunięcie wiersza TSV nie jest poleceniem usunięcia przypisania z Azure; stare przypisania sprawdź osobno.

## Konfiguracja jednorazowa

Pracuj w **repozytorium wdrożeniowym Azure DevOps**. GitHub zawiera wspólny framework;
konfiguracja środowiska, Excel i własne definicje należą do repo wdrożeniowego.

1. Skopiuj [deployment-config.example.json](../configuration/deployment-config.example.json) do
   `configuration/deployment-config.json`. Ustaw główną MG, lokalizacje, znacznik właściciela
   (`managementTag`) oraz subskrypcję/RG dla UAMI polityk.
2. Utwórz wcześniej tę RG dla tożsamości.
3. Skopiuj [ado-env.example.yml](../configuration/ado-env.example.yml) do `configuration/ado-env.yml`.
   Uzupełnij `devops_runner_pool_name` i `devops_service_connection_name`.
4. Skonfiguruj service connection Azure Resource Manager z UAMI pipeline'u i workload identity
   federation. Autoryzuj ją dla pipeline'ów i nadaj role z tabeli poniżej.
5. Skopiuj sześć [przykładów pipeline'ów](../.pipelines/) z `*.example.yml` do `*.yml`
   i zarejestruj pipeline'y A–F w ADO. Zobacz [instrukcję konfiguracji](../.pipelines/README.md).
   Nazwy w `source:` muszą dokładnie odpowiadać nazwom w ADO:
   domyślnie `A-fetch-policies` i `B-rebuild-configuration`.
   Jeśli dodasz sufiks środowiska, stosuj go konsekwentnie.
6. Nie wysyłaj konfiguracji środowiska na publiczny GitHub. Przed pushem sprawdź śledzone pliki:
   `.gitignore` nie przestaje śledzić plików dodanych wcześniej.

Agent potrzebuje narzędzi używanych przez skrypty, m.in. Bash, Azure CLI, Python 3 i jq.

### Uprawnienia UAMI pipeline'u

Role nadaj na **principal/object ID**, nie client ID.
Ta tożsamość uruchamia pipeline; **UAMI polityk** to osobne tożsamości używane do remediacji.

| Scope | Rola | Po co |
| --- | --- | --- |
| **Root MG** (zalecane) lub główna MG obejmująca wszystkie zarządzane scope | **Resource Policy Contributor** | Zarządzanie politykami, inicjatywami, przypisaniami, remediacją i wdrożeniami polityk |
| **Dokładnie ten sam scope MG** | **Role Based Access Control Administrator**, z warunkiem delegowania | Tworzenie/usuwanie przypisań ról UAMI polityk; wyklucz **Owner**, **Role Based Access Control Administrator** i **User Access Administrator** dla obu operacji |
| **RG z UAMI polityk** | **Managed Identity Contributor** | Tworzenie, aktualizacja i usuwanie UAMI |
| **Ta sama RG z UAMI** | **Managed Identity Operator** | Podpinanie UAMI do przypisań polityk |

Nie nadawaj pipeline'owi Owner ani User Access Administrator. Uprawnienia MG są dziedziczone;
nie trzeba ich osobno nadawać na każdej podrzędnej MG/subskrypcji. Główna MG nie obejmuje
zasobów poza swoją hierarchią. Scope Root MG to nie tenant scope `/`.
Utworzenie RG wymaga osobnych uprawnień; niech administrator przygotuje ją wcześniej.
UAMI polityk dostają role wymagane przez polityki, nie rolę administratora RBAC pipeline'u.

**Tylko dla polityk Virtual Network Manager `addToNetworkGroup`:** wdrażająca UAMI potrzebuje
dodatkowo **Network Contributor** na każdej wskazanej network group albo roli niestandardowej z
`Microsoft.Network/networkManagers/networkGroups/join/action`.
Błąd `LinkedAuthorizationFailed` z tą akcją wskazuje na dostęp do powiązanej grupy albo
nieprawidłowy ID. Sprawdź ID/uprawnienia i ponów po propagacji; zmiana remediacyjnych
`roleDefinitionIds` nie naprawi autoryzacji wdrożenia.
Zobacz [wymagane uprawnienia Microsoft](https://learn.microsoft.com/en-us/azure/virtual-network-manager/concept-azure-policy-integration#required-permissions).

## Codzienna praca

1. Edytuj swój Excel w [configuration/](../configuration/) (np. `ALZPolicyAssignments.xlsx`).
2. Skopiuj każdą zmienioną tabelę **razem z nagłówkami** do `configuration/policy-assignments.tsv`
   lub `configuration/policy-parameters.tsv` w repo wdrożeniowym.
   Zapisz, zacommituj i wypchnij Excel/eksporty zgodnie z praktyką repozytorium.
3. Uruchom **B — rebuild-configuration**. Buduje pliki wdrożeniowe i waliduje konfigurację.
   Sprawdź podsumowanie w wynikach pipeline'u: wskazuje wiersz TSV, definicję i opis problemu.
   **Nieudany rebuild nie publikuje nowego artefaktu `policy-generated`.**
4. Jeśli zmieniły się definicje, uruchom **C — update-definitions**.
5. Uruchom **D — update-assignments** z `deployMode=whatif`. Przejrzyj what-if,
   a gdy wynik jest właściwy, uruchom ponownie z `deployMode=deploy`.
   Domyślnie deploy ponawia podgląd i wdraża tylko po jego sukcesie.
   `skipValidation=true` pomija ten podgląd wyłącznie w trybie `deploy`;
   nie wyłącza walidacji konfiguracji. Nie ma ręcznej pauzy między podglądem a wdrożeniem.

   Na końcu D znajdziesz tabelę błędów przypisań (scope, etap i komunikat), także
   w podsumowaniu ADO. Błędy deploymentu, what-if, UAMI lub RBAC powodują nieudany run;
   wcześniej wykonane zmiany nie są wycofywane.

   Linie `TIME` pokazują czas obsługi UAMI, deploymentu/what-if, odczytu principalId,
   poszczególnych nadań RBAC oraz łączny czas przetwarzania przypisań. Dla UAMI
   principalId jest odczytywany bezpośrednio z tożsamości, bez oczekiwania na pole przypisania.

**Wybierz wyniki właściwego uruchomienia pipeline'u.** A publikuje `policy-source`; B pobiera go i publikuje
`policy-generated`; C i D pobierają artefakt B. D używa wygenerowanej konfiguracji, nie
świeżo zmienionego TSV bezpośrednio. C czyta też TSV ze swojego checkoutu, więc używaj
tej samej rewizji źródeł co B. Po błędzie rebuilda nie wdróż przypadkiem starszego udanego artefaktu B.
Snapshot pochodzi z wybranego artefaktu A; samo ustawienie `policyVersion` w B go nie zastępuje.

### Gdy walidacja zgłosi problem

| Problem | Jak poprawić |
| --- | --- |
| Nieprawidłowa nazwa/ID lub typ definicji | Popraw odpowiedni wiersz w Excelu; sprawdź, czy to polityka (`Policy`), czy inicjatywa (`Initiative`) |
| Brak źródła lub wygenerowanego szablonu | Sprawdź nazwę definicji, własne źródła i wybrany snapshot A; popraw źródło zamiast ręcznie tworzyć plik wynikowy |
| Brak zestawu parametrów, wymaganego parametru lub nagłówka tabeli | Uzupełnij tabelę parametrów i sprawdź zgodność nazwy `Parameter Set`; eksportuj razem z nagłówkami |
| HTTP 404/410 z AzAdvertizer | Adres powstaje automatycznie z typu i ID; sprawdź te pola oraz `Type2` (`Own` dla własnych definicji). Link w TSV jest ignorowany |
| Ostrzeżenie o timeout, HTTP 429 lub 5xx | Serwis może być chwilowo niedostępny; sprawdź link i ponów później. Samo ostrzeżenie nie blokuje publikacji |

Po poprawce danych ponownie wyeksportuj TSV, zapisz zmiany w repo i uruchom B.
Błędy blokują nowy artefakt; nie omijaj ich przez wdrożenie starszego.

### Przydatne ustawienia Run pipeline

| Pipeline | Ustawienia |
| --- | --- |
| **A — fetch-policies** | `policyVersion`: tag/commit ALZ; domyślnie `main` |
| **C — update-definitions** | `deployPolicyDefinitions=true`, `targetDefinition=*`, `deployInitiatives=true`, `targetInitiative=*`; `location` dotyczy metadanych wdrożenia |
| **D — update-assignments** | `deployMode=whatif` (domyślnie) lub `deploy`; `skipValidation=false`; `targetAssignment=*` dla wszystkich lub jedna dokładna nazwa |
| **E — cleanup** | Domyślnie `targetAssignment=*`, `withDefinitions=false`, `delete=false` |
| **F — sync-framework** | `frameworkVersion=main`, `dryRun=true` daje podgląd; `false` robi commit i push do ADO |

Dla jednej definicji wyłącz też niepotrzebną fazę w C; oba selektory działają niezależnie.
Parametr D `deployPolicies` został zastąpiony przez `deployMode` i `skipValidation`.
Zaktualizuj zapisane wywołania pipeline'u oraz środowiskowy YAML wraz z nowym
szablonem `.pipelines/.templates/update-assignments-step.yml`.
Scope przypisania pochodzi z TSV; `MG` + `ROOT` oznacza `deployment.definitionManagementGroupId`.
Scope ról UAMI pochodzi z wygenerowanego `roleAssignments[].scope`, nie z jednej globalnej MG.

## Cleanup: podgląd, sprawdzenie, usunięcie

Dla pełnego sprzątania uruchom E z `targetAssignment=*`, `withDefinitions=true`, **`delete=false`**.
Sprawdź listę, potem ponów z **`delete=true`**. Każdy run pobiera aktualną listę od nowa.

- Właściciela określa `managementTag`: przypisania mają `metadata.assignedBy`,
  definicje/inicjatywy `metadata.managedBy`, UAMI `tags.managedBy`.
  Cleanup wybiera tylko zasoby z konfiguracyjnym znacznikiem właściciela.
  Używaj unikalnego `managementTag`, aby nie objąć zasobów zarządzanych przez inne wdrożenie.
- Kolejność: **przypisania → RBAC tożsamości → UAMI → inicjatywy → definicje**.
  RBAC jest wyszukiwany po `principalId` tożsamości, nie po tagu.
- Uwzględniane są oznaczone osierocone UAMI z konfiguracyjnej RG. Oznaczone UAMI używane
  przez wybrane przypisania mogą znajdować się również poza tą RG.
- UAMI używane przez pozostałe widoczne przypisania/zasoby i ich RBAC pozostają.
  Współdzielenie poza hierarchią sprawdź osobno: widoczność ogranicza MG i dostęp bieżącego konta.
- Można wybrać jedno przypisanie, ale nie razem z `withDefinitions=true`.
- Błąd zapytania/usuwania przerywa run. Wcześniejsze usunięcia nie są wycofywane.
- Pozostają zasoby bez znacznika, zasoby robocze utworzone przez remediation, RG i historia wdrożeń.
  Starsze definicje ALZ bez znacznika wymagają rebuilda i ponownego wdrożenia C przed cleanupem.

Resource Graph ma opóźnienia. Po propagacji ponów samo wyświetlenie listy i sprawdź pozostałości.
Usuwanie RBAC podlega również warunkowi delegowania UAMI pipeline'u.

## Aktualizacja frameworka

Uruchom F z `dryRun=true` i sprawdź diff przed zezwoleniem na commit/push.
Zachowuje `source/own/` i środowiskowe pliki YAML pipeline'ów.
**Nie zakładaj, że całe `configuration/` jest wykluczone:** obecne wykluczenie dotyczy starej
ścieżki `configurations/`. Sprawdź zmiany konfiguracji/przykładów i przed zastosowaniem
zadbaj o czyste repo wdrożeniowe oraz kopię zmian.
F nie aktualizuje istniejących środowiskowych YAML-i; porównaj je ręcznie z nowymi przykładami.

Formaty danych, opcje CLI i moduły opisuje [dokumentacja techniczna](REFERENCE.pl.md).

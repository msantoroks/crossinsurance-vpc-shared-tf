# Cross Insurance — Acessos necessários para integração Cloud Build

> Documento para a equipe de TI da **Cross Insurance**. Lista os acessos que
> precisamos no GCP e no GitHub de vocês para entregar a esteira de
> Terraform via Cloud Build (plan automático no `main`, apply manual com
> aprovação) idêntica à que está rodando hoje no nosso ambiente de teste
> (`ks-crossinsurance-proj-test-01..04`).

---

## TL;DR — Checklist do que precisamos

| # | O quê | Onde | Quem concede |
|---|---|---|---|
| 1 | Conta de usuário GCP para `***REMOVED***` e `marcelo.santoro@kloudstax.com` com **`roles/owner`** (ou conjunto equivalente, ver §2) nos projetos `<workload-prod>`, `<workload-stg>`, `<workload-dev>` e no projeto host (Shared VPC) | Cross GCP Org | Org Admin / Project Owner da Cross |
| 2 | Decisão sobre a **Service Account de execução** do Terraform: reutilizar a SA central `<sa-terraform-ci-cross>` (cross-project) **ou** criar uma SA local em cada projeto workload (ver §4) | Cross GCP | Equipe Cross |
| 3 | Caso opção (a) — confirmar/ajustar a **Org Policy** `iam.disableCrossProjectServiceAccountUsage` para `Not enforced` nos projetos workload (ver §5) | Cross GCP Org | Organization Policy Administrator |
| 4 | **Acesso de admin** ao repositório GitHub `<org-cross>/<repo-terraform>` para `msantoroks` (ou usuário equivalente da Kloudstax) **OU** instalação prévia do **Cloud Build GitHub App** no repo, com permissão concedida (ver §3) | GitHub da Cross | GitHub Org Admin / Repo Admin |
| 5 | Confirmação dos buckets GCS que vamos usar para **state** do Terraform e **registro central de CIDR** (ver §6) | Cross GCP | Equipe Cross |

---

## 1. Contexto

Estamos integrando, no ambiente da Cross, a mesma esteira que já rodamos
internamente:

- **Terraform** mono-repo no GitHub, com 1 stack por workload project.
- **Cloud Build** rodando o `terraform plan` automaticamente em cada push
  para a branch `main`, e o `terraform apply` por **invocação manual com
  aprovação obrigatória** (`require-approval`) por uma segunda pessoa.
- **State remoto** em GCS (1 bucket único, com prefixo por stack).
- **Registro central de CIDR** em GCS (arquivo único `cidr-registry.txt`)
  validado em todo plan/apply para impedir sobreposição de faixas entre
  projetos.

Para entregar isso no ambiente de vocês, precisamos dos acessos abaixo.

---

## 2. Acesso ao GCP da Cross

### 2.1. Usuários Kloudstax

Convidar para a Org / Projetos da Cross:

- `***REMOVED***`
- `marcelo.santoro@kloudstax.com`

Com **um** dos seguintes níveis (em ordem de preferência da Cross):

1. **`roles/owner`** em cada projeto workload (`<workload-prod>`,
   `<workload-stg>`, `<workload-dev>`) e no projeto host de Shared VPC.
   - Cobre tudo. Mais simples para integração.

2. **OU** combinação granular abaixo (se Owner for inviável):

   | Role | Projeto | Por quê |
   |---|---|---|
   | `roles/cloudbuild.builds.editor` | cada workload | criar/editar triggers, rodar builds |
   | `roles/cloudbuild.connectionAdmin` | cada workload | conectar o repositório GitHub |
   | `roles/iam.serviceAccountAdmin` | cada workload + host | criar SAs locais (se opção plano B) |
   | `roles/iam.serviceAccountUser` | na SA do Terraform | poder usar a SA em triggers |
   | `roles/resourcemanager.projectIamAdmin` | cada workload + host | gravar bindings IAM |
   | `roles/orgpolicy.policyAdmin` | nível org **ou** projeto | ajustar a org policy do §5 |
   | `roles/storage.admin` | host | criar/configurar bucket de state e CIDR |
   | `roles/compute.networkAdmin` | host | confirmar shared VPC e peering |

> Por escopo bem definido (sandbox de teste), o `Owner` durante a fase de
> setup e migração para granular depois é o caminho mais rápido.

### 2.2. Service Account do Terraform

Ver §4 — definimos qual SA será usada e quem concede acesso.

---

## 3. Acesso ao repositório GitHub da Cross

A integração entre Cloud Build e o repositório do Terraform exige que o
**Cloud Build GitHub App** esteja instalado no repositório de vocês com
permissão de leitura de código e gravação de status checks.

Hoje, ao tentar conectar pelo Cloud Build da Cross, o botão fica como
**"Request"** (em vez de "Connect"). Isso acontece porque:

1. Quem está fazendo a tentativa (`msantoroks`) **não é admin do
   repositório** da Cross.
2. **OU** o GitHub App ainda não está instalado na organização e o
   instalador requer permissão de Org Owner / Repo Admin.

### O que precisamos

**Opção A — preferida:** vocês instalam o **Cloud Build GitHub App** na
organização da Cross e dão acesso ao repositório
`<org-cross>/<repo-terraform>`. Tutorial: https://cloud.google.com/build/docs/automating-builds/github/connect-repo-github

**Opção B:** dar **`Admin`** no repositório a `msantoroks` (apenas
durante a integração — pode ser revogado depois) para que ele instale o
GitHub App e conecte os 4 projetos.

Sem **uma** dessas duas, o Cloud Build não consegue receber webhooks de
push, e portanto a esteira de plan/apply não funciona.

### Quando estiver tudo conectado

Para cada um dos N projetos workload (`prod`, `stg`, `dev`, etc.),
**precisamos repetir o `Connect repository`** dentro daquele projeto
específico — a conexão GitHub é por projeto, não por organização.

---

## 4. Service Account de execução do Terraform

Aqui temos duas estratégias possíveis. **Decisão em conjunto Kloudstax + Cross.**

### Opção A — Reutilizar a SA central que o Filipe já criou

Vocês já têm hoje uma SA central usada pelos Cloud Builds das contas dos
projetos do Filipe — algo como
`<sa-terraform-ci-cross>@<projeto-terraform-cross>.iam.gserviceaccount.com`.

**Vantagem:** uma única identidade audita todas as execuções de Terraform
em todos os projetos workload. Permissões são concedidas em um único
lugar.

**Pré-requisito:** essa SA precisa estar **liberada para impersonation
cross-project**, ou seja, a Org Policy
`iam.disableCrossProjectServiceAccountUsage` precisa estar
**`Not enforced`** (ver §5).

**Permissões mínimas que essa SA precisa receber:**

| Role | Onde | Por quê |
|---|---|---|
| `roles/editor` (ou roles granulares de network/compute) | Cada projeto workload | criar VPC, subnets, peering |
| `roles/logging.logWriter` | Cada projeto workload | Cloud Build com SA custom precisa escrever logs |
| `roles/compute.networkAdmin` | Projeto host (Shared VPC) | criar peering bidirecional workload ↔ shared |
| `roles/storage.objectAdmin` | Bucket de state | ler/gravar tfstate |
| `roles/storage.objectAdmin` | Bucket do CIDR registry | ler/atualizar cidr-registry.txt |
| `roles/iam.serviceAccountUser` (concedida ao ***REMOVED***/Marcelo na própria SA) | n/a | poder usar a SA ao criar triggers |

E, para que o Cloud Build do projeto workload consiga **invocar** essa SA
de outro projeto:

- A **service account default do Cloud Build** de cada projeto workload
  (`service-<PROJECT_NUMBER>@gcp-sa-cloudbuild.iam.gserviceaccount.com`)
  precisa receber `roles/iam.serviceAccountUser` e
  `roles/iam.serviceAccountTokenCreator` na SA central.

### Opção B — SA local em cada projeto workload (fallback)

Se a Org Policy do §5 estiver enforced e não puder ser desabilitada,
criamos **uma SA por projeto workload**:
`sa-terraform-ci@<workload-N>.iam.gserviceaccount.com`.

**Vantagem:** evita o problema de cross-project completamente. Funciona
mesmo com `iam.disableCrossProjectServiceAccountUsage = enforced`.

**Desvantagem:** N SAs para auditar/manter; cada uma precisa ganhar as
mesmas permissões da Opção A (sem o passo de impersonation cross-project).

> No nosso ambiente de teste interno **acabamos optando pela Opção B**
> justamente porque a org da Kloudstax tem essa policy enforced. Se a
> Cross também estiver, a Opção A não roda do dia 0.

---

## 5. Org Policy: `iam.disableCrossProjectServiceAccountUsage`

Se a Cross optar pela **Opção A** (SA central cross-project), essa policy
precisa estar **`Not enforced`** nos projetos workload.

### Como verificar

```bash
gcloud org-policies describe \
  iam.disableCrossProjectServiceAccountUsage \
  --project=<workload-N>
```

Se a saída mostrar `enforced: true` ou `inheritedFrom: ...` com
`enforced`, a policy está bloqueando.

### Como ajustar (precisa de Organization Policy Administrator)

Em **nível de projeto** (recomendado se a Org não puder ser tocada):

```bash
gcloud org-policies reset \
  iam.disableCrossProjectServiceAccountUsage \
  --project=<workload-N>
```

Ou, mais explícito:

```bash
cat <<EOF > policy.yaml
name: projects/<workload-N>/policies/iam.disableCrossProjectServiceAccountUsage
spec:
  rules:
  - enforce: false
EOF
gcloud org-policies set-policy policy.yaml
```

Repetir para cada projeto workload.

### Observação importante

Mesmo com a policy `Not enforced`, é **boa prática** restringir quem pode
impersonar a SA central via `roles/iam.serviceAccountUser` apenas a:

- Os usuários humanos que vão criar triggers (Kloudstax + responsáveis da
  Cross).
- A SA default do Cloud Build de cada projeto workload (que vai *executar*
  o build).

---

## 6. Buckets compartilhados (state + CIDR registry)

A esteira precisa de 2 buckets GCS — vocês podem decidir onde ficam:

| Bucket | Conteúdo | Tamanho esperado |
|---|---|---|
| `<bucket-tfstate>` | tfstate de todos os stacks (1 prefixo por workload) | < 100 MB total |
| `<bucket-cidr-registry>` | arquivo `cidr-registry.txt` (texto puro) | < 1 KB |

Recomendação: criar ambos no projeto **host** (o que tem a Shared VPC), com:

- **Versionamento ativado** no `<bucket-tfstate>` (essencial para recuperação).
- **Uniform bucket-level access**.
- **Localização**: a mesma região dos workloads (ex: `us-central1`)
  ou multi-região `us`/`eu`.

Os nomes podem seguir um padrão sugerido:

- `<projeto-host>-terraform-state`
- `<projeto-host>-vpc-cidr-validator`

Ou os nomes que vocês já usam — basta nos passar para configurarmos no
`deploy.sh` e nos `cloudbuild-*.yaml`.

---

## 7. Resumo executivo — Pedido para a TI da Cross

Para destravar a integração, precisamos:

1. **Convidar** `***REMOVED***` e `marcelo.santoro@kloudstax.com`
   nos projetos GCP da Cross com `Owner` durante a fase de setup
   (downgrade para roles granulares depois — ver §2.1).
2. **Decidir** entre Opção A (SA central, depende da org policy) e
   Opção B (SA local por projeto). Recomendamos Opção A se a org policy
   permitir; Opção B caso contrário.
3. Se Opção A → **garantir** que `iam.disableCrossProjectServiceAccountUsage`
   está `Not enforced` nos projetos workload (ver §5).
4. **Instalar o Cloud Build GitHub App** no repositório de Terraform da
   Cross **OU** dar `Admin` no repo a `msantoroks` para que ele faça a
   instalação (ver §3).
5. **Confirmar os nomes/localização dos buckets** de state e CIDR
   registry (ver §6) — ou nos autorizar a criá-los.
6. **Confirmar os IDs dos projetos** workload e do projeto host que serão
   alvos da esteira (`prod`, `stg`, `dev`, etc.) e os blocos CIDR
   pretendidos para cada VPC.

Com esses 6 itens em mãos, conseguimos:

- Conectar o repositório nos N projetos.
- Provisionar/reutilizar a SA conforme decidido.
- Criar os triggers (1 plan + 1 apply por projeto, total 2N triggers).
- Rodar o primeiro `plan` end-to-end e demonstrar o `apply` com
  aprovação manual.

Estimativa: **meio dia de trabalho** depois que os 6 itens forem
atendidos.

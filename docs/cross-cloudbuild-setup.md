# Setup do Cloud Build para o repo `infrastructure` — Handoff Cross

Documento operacional para o time da **Cross Insurance** replicar, no
ambiente da Cross, o mesmo cenário de CI/CD que já está validado no
ambiente de testes da KloudStax. O resultado final é o `terraform plan`
de cada stack (`dev`, `stg`, `prod`) rodando automaticamente no Cloud
Build a cada push em `main` do repositório, sem precisar de
`credentials/local.json` em CI.

> **Status atual:** Pipeline de plan validada e funcionando no projeto de
> testes `ks-crossinsurance-proj-test-sh` da KloudStax (consulte o
> Marcelo Santoro para ver o build executado em verde).
>
> **Escopo desta entrega:** apenas `terraform plan`. O `terraform apply`
> permanece manual via `./deploy.sh apply` em estação autorizada — a
> ativação de um trigger de apply foi adiada por decisão conjunta.

---

## 1. Visão geral

```
                      Push em main do GitHub
                                │
                                ▼
                     Cloud Build (HOST_PROJECT)
                                │
                  Roda como SA: TF_RUNNER_SA
                                │
                  ┌─────────────┼─────────────┐
                  │             │             │
                  ▼             ▼             ▼
           plan(dev)     plan(stg)     plan(prod)
                  │             │             │
                  └─────────────┼─────────────┘
                                ▼
              State no bucket gs://STATE_BUCKET
              (mesmo bucket usado hoje localmente)
                                │
                                ▼
       Workloads alvo (cada um com seu project_id):
        ks-crossinsurance-proj-test-{01,02,03}
        — substitua pelos seus projetos workload
```

## 2. Inventário do que a Cross precisa providenciar

Substitua os nomes da coluna "KloudStax (referência)" pelos equivalentes
da Cross.

| Item | KloudStax (referência) | Cross (preencher) | Já existe? |
|---|---|---|---|
| Projeto host do Cloud Build | `ks-crossinsurance-proj-test-sh` | _____ | _____ |
| Service Account de runtime do Terraform | `sa-terraform-ci@ks-crossinsurance-proj-test-sh.iam.gserviceaccount.com` | _____ | _____ |
| Bucket GCS de Terraform state | `ks-crossinsurance-proj-test-terraform-state` | _____ | _____ |
| Repositório Git contendo este código | `msantoroks/crossinsurance-vpc-shared-tf` (fork) | _____ | _____ |
| Projetos workload (alvo do Terraform) | `ks-crossinsurance-proj-test-{01,02,03}` | _____ | _____ |

> **Recomendação para Cross:** se a SA `terraform-cloudbuild@terraform-488619`
> (a que o Filipe usa no `okta-integration`) já tem
> `roles/resourcemanager.organizationAdmin` na organização da Cross, o caminho
> mais econômico é **reutilizar essa SA também aqui** e hospedar o Cloud Build
> no mesmo `terraform-488619`. Nesse caso a Cross pula as etapas 3 e 4 abaixo.

---

## 3. Pré-requisitos

A pessoa que vai executar o setup precisa ter, no projeto host
(`HOST_PROJECT`):

- `roles/owner` **ou** o conjunto:
  - `roles/serviceusage.serviceUsageAdmin`
  - `roles/iam.serviceAccountAdmin`
  - `roles/resourcemanager.projectIamAdmin`
  - `roles/cloudbuild.builds.editor`
  - `roles/storage.admin` (no projeto que hospeda o bucket de state)

E para a SA runtime atuar nos workloads (etapa 5):

- Quem cria precisa ter `roles/resourcemanager.projectIamAdmin` em cada
  workload, **ou** `roles/resourcemanager.organizationAdmin` na org
  (caso queira aplicar via grant org-wide).

---

## 4. Setup passo a passo

Defina as variáveis no shell **uma vez** antes de copiar os blocos:

```bash
# Substitua pelos valores da Cross
export HOST_PROJECT="<projeto-host-do-cloud-build>"
export TF_SA_NAME="sa-terraform-ci"
export TF_SA="${TF_SA_NAME}@${HOST_PROJECT}.iam.gserviceaccount.com"
export STATE_BUCKET="<nome-do-bucket-de-state>"
export STATE_BUCKET_PROJECT="${HOST_PROJECT}"   # ou outro projeto, se for o caso
export REPO_OWNER="<github-org>"
export REPO_NAME="infrastructure"
```

### 4.1. Habilitar APIs no projeto host

```bash
gcloud services enable \
  cloudbuild.googleapis.com \
  iamcredentials.googleapis.com \
  iam.googleapis.com \
  --project="${HOST_PROJECT}"
```

### 4.2. Criar (ou identificar) a Service Account runtime do Terraform

Pular se a Cross optou por reutilizar a SA do `okta-integration`.

```bash
gcloud iam service-accounts create "${TF_SA_NAME}" \
  --project="${HOST_PROJECT}" \
  --display-name="Terraform CI runtime (infrastructure repo)"
```

### 4.3. Permitir que o Cloud Build atue como `TF_SA`

A SA "default" do Cloud Build precisa de `serviceAccountUser` na
`TF_SA`. Sem isso, ao criar trigger com `--service-account=...`, o
build falha em "permission denied".

```bash
PROJECT_NUMBER="$(gcloud projects describe ${HOST_PROJECT} --format='value(projectNumber)')"
DEFAULT_CB_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

gcloud iam service-accounts add-iam-policy-binding "${TF_SA}" \
  --project="${HOST_PROJECT}" \
  --member="serviceAccount:${DEFAULT_CB_SA}" \
  --role="roles/iam.serviceAccountUser"
```

### 4.4. Conceder à `TF_SA` permissão de escrever logs do Cloud Build

```bash
gcloud projects add-iam-policy-binding "${HOST_PROJECT}" \
  --member="serviceAccount:${TF_SA}" \
  --role="roles/logging.logWriter"
```

### 4.5. Conceder à `TF_SA` acesso ao bucket de Terraform state

```bash
# Se o bucket ainda não existe:
gcloud storage buckets create "gs://${STATE_BUCKET}" \
  --project="${STATE_BUCKET_PROJECT}" \
  --location=us \
  --uniform-bucket-level-access
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning

# Acesso da SA ao bucket
gcloud storage buckets add-iam-policy-binding "gs://${STATE_BUCKET}" \
  --member="serviceAccount:${TF_SA}" \
  --role="roles/storage.objectAdmin"
```

> O bucket de state é o **mesmo** que o `deploy.sh` já usa hoje em
> `${TF_STATE_BUCKET:-ks-crossinsurance-proj-test-terraform-state}`.
> Se a Cross quiser outro nome, basta exportar `TF_STATE_BUCKET=...`
> no ambiente do build (e no laptop dos operadores), ou alterar o default
> dentro de `dev|stg|prod/deploy.sh` linha 16.

### 4.6. Conceder à `TF_SA` acesso aos projetos workload

A `TF_SA` precisa criar VPCs, subnets, peering e habilitar APIs nos
projetos `dev / stg / prd`. Os roles mínimos:

```bash
for WORKLOAD in <dev-project> <stg-project> <prd-project>; do
  for ROLE in \
      roles/compute.networkAdmin \
      roles/serviceusage.serviceUsageAdmin \
      roles/resourcemanager.projectIamAdmin \
      roles/iam.serviceAccountUser; do
    gcloud projects add-iam-policy-binding "${WORKLOAD}" \
      --member="serviceAccount:${TF_SA}" \
      --role="${ROLE}"
  done
done
```

> A Cross também precisa garantir o acesso da `TF_SA` ao **projeto shared**
> (`cross-network-shared`) com `roles/compute.networkAdmin` (necessário
> para o módulo de peering ler a VPC host).

> **Atalho equivalente:** se a Cross prefere conceder de uma vez na
> organização inteira (caminho que o Filipe usa no `okta-integration`):
> ```bash
> gcloud organizations add-iam-policy-binding "${ORG_ID}" \
>   --member="serviceAccount:${TF_SA}" \
>   --role="roles/resourcemanager.organizationAdmin"
> ```

### 4.7. Conectar o repositório no Cloud Build (via Console)

Como o repo está no GitHub.com (não Enterprise), a primeira conexão é
**obrigatoriamente** via Console (autorização OAuth do GitHub App):

1. Abrir: `https://console.cloud.google.com/cloud-build/triggers?project=${HOST_PROJECT}`
2. Botão **MANAGE REPOSITORIES** → **CONNECT REPOSITORY**.
3. Selecionar **GitHub (Cloud Build GitHub App)**.
4. Autorizar o app **Google Cloud Build** na conta/organização do GitHub.
5. Selecionar o repositório `${REPO_OWNER}/${REPO_NAME}`.
6. Marcar "I understand..." e clicar **Connect**.
7. Quando aparecer "Create a trigger?", clicar **Skip for now** — vamos
   criar via gcloud na próxima etapa.

> Se o repo da Cross estiver em **GitHub Enterprise**, o caminho é
> diferente: precisa criar uma `githubEnterpriseConfigs` antes (é o mesmo
> padrão usado no `okta-integration`, vide
> `okta-integration/docs/README.md` §7).

### 4.8. Criar os 3 triggers de plan (push automático em `main`)

```bash
SERVICE_ACCOUNT="projects/${HOST_PROJECT}/serviceAccounts/${TF_SA}"

for STACK in dev stg prod; do
  gcloud builds triggers create github \
    --project="${HOST_PROJECT}" \
    --region=global \
    --name="cross-infra-${STACK}-plan-main" \
    --description="Automatically plans the infrastructure/${STACK} Terraform stack on pushes to main." \
    --repo-owner="${REPO_OWNER}" \
    --repo-name="${REPO_NAME}" \
    --branch-pattern="^main$" \
    --build-config="cloudbuild-plan.yaml" \
    --substitutions="_STACK=${STACK}" \
    --included-files="${STACK}/**,modules/**,cloudbuild-plan.yaml" \
    --include-logs-with-status \
    --service-account="${SERVICE_ACCOUNT}"
done
```

O `--included-files` garante que push só em `dev/` não dispare
desnecessariamente os triggers de `stg` e `prod`. Push em `modules/**`
dispara os 3 (correto, porque o módulo é compartilhado).

### 4.9. Criar os 3 triggers de apply (manuais, com aprovação obrigatória)

Diferente do plan, o apply **nunca** roda automaticamente em push. Ele
só executa quando um operador autorizado clica "RUN" no trigger no
Console do Cloud Build, e mesmo aí o build fica em estado
`PENDING — Awaiting approval` até alguém com `roles/cloudbuild.builds.approver`
aprovar. Esse é o padrão usado pelo `okta-integration` e oferece audit
trail no Cloud Audit Logs (quem disparou + quem aprovou).

```bash
for STACK in dev stg prod; do
  gcloud builds triggers create manual \
    --project="${HOST_PROJECT}" \
    --region=global \
    --name="cross-infra-${STACK}-apply-main" \
    --description="Manually applies infrastructure/${STACK} from main after Cloud Build approval." \
    --repo="https://github.com/${REPO_OWNER}/${REPO_NAME}" \
    --repo-type=GITHUB \
    --branch=main \
    --build-config="cloudbuild-apply.yaml" \
    --substitutions="_STACK=${STACK}" \
    --require-approval \
    --service-account="${SERVICE_ACCOUNT}"
done
```

Conceder a permissão de aprovador para os operadores autorizados:

```bash
# Repita para cada usuário que pode aprovar applies
gcloud projects add-iam-policy-binding "${HOST_PROJECT}" \
  --member="user:<email-do-aprovador>" \
  --role="roles/cloudbuild.builds.approver"
```

> Dois cuidados:
> - Quem **dispara** o trigger pode ser diferente de quem **aprova**.
>   Para enforce, conceda apenas `roles/cloudbuild.builds.editor` ao
>   "operador que dispara" e `roles/cloudbuild.builds.approver` aos
>   demais. Quem precisa fazer os dois recebe os dois roles.
> - O Cloud Build pausa o build **antes** do primeiro step. O aprovador
>   vê branch, commit hash e substitutions, mas não vê o output do plan.
>   Por isso o trigger de plan rodou primeiro (em push para `main`) e
>   serve de evidência do que será aplicado.

---

## 5. Validação

### 5.1. Listar os triggers criados

```bash
gcloud builds triggers list \
  --project="${HOST_PROJECT}" \
  --region=global \
  --filter='name~cross-infra-' \
  --format='table(name,filename,substitutions._STACK,serviceAccount)'
```

Esperado: 3 linhas (`cross-infra-dev-plan-main`,
`cross-infra-stg-plan-main`, `cross-infra-prod-plan-main`).

### 5.2. Disparar manualmente o trigger de dev

```bash
gcloud builds triggers run cross-infra-dev-plan-main \
  --project="${HOST_PROJECT}" \
  --region=global \
  --branch=main
```

### 5.3. Acompanhar o build

```bash
gcloud builds list \
  --project="${HOST_PROJECT}" \
  --filter="trigger_id~cross-infra" \
  --format='table(id,status,createTime,duration)' \
  --limit=5
```

Ou pelo Console:

```
https://console.cloud.google.com/cloud-build/builds?project=${HOST_PROJECT}
```

O build executa, em ordem:

1. `tf-fmt-check` — `terraform fmt -recursive -check`
2. `tf-plan` — instala `bash`, `python3`, `py3-pip`, `jq`, instala
   `google-cloud-storage` via pip, e roda `cd ${_STACK} && ./deploy.sh plan`.

Sucesso esperado: build em verde, output do plan no log.

---

## 6. O que NÃO está incluído (intencionalmente)

| Item | Status | Motivo |
|---|---|---|
| Trigger de `terraform apply` automático em push | Não criado | Apply só roda via trigger **manual** com aprovação obrigatória (`--require-approval`). Push em `main` nunca dispara apply sozinho. |
| Bucket separado para CIDR registry | Reutilizando `gs://${STATE_BUCKET}` | Decisão para minimizar superfície de IAM. O objeto `cidr-registry.txt` vive lado a lado com os prefixos de state. |
| Lock distribuído entre stacks | Não habilitado nesta versão do `infrastructure/deploy.sh` | O `deploy.sh` desta árvore não usa `gcs_apply_lock.py`. State lock nativo do GCS continua ativo. |
| Trigger de plan em PR | Não criado | Plan só roda em push para `main`. Pode ser adicionado depois com `--pull-request-pattern`. |

---

## 7. Itens de bootstrap **uma única vez** (matriz resumida)

Resumo executivo do que precisa existir antes do primeiro plan rodar:

| # | Recurso | Quem provê | Comando da etapa |
|---|---|---|---|
| 1 | APIs habilitadas no host | Cross | 4.1 |
| 2 | SA `TF_SA` criada | Cross | 4.2 (ou reuso) |
| 3 | `serviceAccountUser` da SA default do Cloud Build na `TF_SA` | Cross | 4.3 |
| 4 | `logging.logWriter` na `TF_SA` | Cross | 4.4 |
| 5 | Bucket `STATE_BUCKET` existente + `objectAdmin` da `TF_SA` | Cross | 4.5 |
| 6 | Roles da `TF_SA` nos workloads (network/serviceUsage/IAM) | Cross | 4.6 |
| 7 | Repo Git conectado no Cloud Build | Cross | 4.7 (Console) |
| 8 | 3 triggers de plan criados (push em main) | Cross | 4.8 |
| 9 | 3 triggers de apply criados (manuais, require-approval) | Cross | 4.9 |
| 10 | `cloudbuild.builds.approver` concedido aos aprovadores | Cross | 4.9 |

---

## 8. Apêndice — Troubleshooting

### Build falha em `tf-plan` com `env: can't execute 'bash'`
A imagem `hashicorp/terraform` é Alpine. O `cloudbuild-plan.yaml` já
instala `bash` antes de chamar `./deploy.sh`. Se o erro voltar, confirmar
que o YAML em uso contém `apk add --no-cache bash python3 py3-pip jq`.

### `Repository mapping does not exist` ao criar trigger
A etapa 4.7 (conectar repo no Console) não foi feita ou foi feita em
outro projeto. Refazer no `${HOST_PROJECT}` correto.

### `Permission denied on resource ks-crossinsurance-proj-test-XX` durante o plan
A `TF_SA` ainda não tem roles no workload em questão. Re-rodar a etapa
4.6 garantindo que o projeto correto esteja na lista.

### `Service account ... does not have ... iam.serviceAccountUser`
A etapa 4.3 não foi executada — a SA default do Cloud Build não pode
agir como `TF_SA`. Re-rodar 4.3 e tentar novamente.

### Build trava esperando input no `terraform apply`
Não é o caso aqui (apply está desabilitado), mas se um dia for
reativado: o `deploy.sh` injeta `-auto-approve` automaticamente quando
detecta `BUILD_ID` (variável que o Cloud Build sempre define).

### Como rodar o plan localmente sem Cloud Build
```bash
cd infrastructure/dev   # ou stg / prod
# usando local.json
./deploy.sh plan
# ou usando ADC (gcloud auth application-default login antes)
USE_ADC=1 ./deploy.sh plan
```

### Como demonstrar o apply em ambiente de testes
1. Garantir que o trigger de plan rodou recentemente em verde (Etapa 5.2).
2. Disparar o trigger manual de apply:
   ```bash
   gcloud builds triggers run cross-infra-dev-apply-main \
     --project="${HOST_PROJECT}" \
     --region=global \
     --branch=main
   ```
3. Abrir o Console do Cloud Build no projeto host. Build aparece como
   "Awaiting approval". Aprovar.
4. Acompanhar a execução. Build verde = apply concluído.

---

## 9. Apêndice — Referência rápida das mudanças no repositório

Esta entrega introduziu, em relação à versão original do `infrastructure/`:

| Arquivo | Mudança |
|---|---|
| `cloudbuild-plan.yaml` | **Novo.** Config do Cloud Build, parametrizado por `_STACK`. |
| `cloudbuild-apply.yaml` | **Novo, desativado.** Estrutura completa comentada para reativação futura. |
| `dev/deploy.sh`, `stg/deploy.sh`, `prod/deploy.sh` | Aceitam Application Default Credentials quando `BUILD_ID` (Cloud Build) ou `USE_ADC=1` está setado, tornam `terraform.tfvars` opcional, pulam `connect-project.sh` em CI (que dependia de `ruby`) e adicionam `-auto-approve` automaticamente em CI. Mudanças retro-compatíveis: o uso local com `credentials/local.json` continua idêntico. |

Commits relevantes:

- `ci: add Cloud Build plan config and prepare deploy.sh for ADC`
- `fix(ci): install bash in Cloud Build runner`

---

## 10. Próximos passos sugeridos (pós-handoff)

Itens fora do escopo deste setup mas que o time da Cross talvez queira
discutir na sequência:

- Trigger de plan em PR para feedback antes do merge.
- Imagem builder própria (Artifact Registry) com `terraform + python +
  google-cloud-storage` pré-instalados, eliminando o `apk add` e o
  `pip install` em cada build.
- Notificação dos resultados do plan/apply em Slack ou Chat
  (`google_pubsub_topic` + `google_cloud_function`).
- Centralizar o setup acima em um Terraform de bootstrap (em outro repo,
  para não criar dependência circular).

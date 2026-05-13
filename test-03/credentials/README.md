# Credentials for this stack

Place the service account JSON used for Terraform here:

```text
credentials/local.json
```

Or set another file name via `DEPLOY_CREDENTIALS` (filename without `.json`):

```bash
export DEPLOY_CREDENTIALS=ci
./deploy.sh plan
```

CI usually sets `GOOGLE_APPLICATION_CREDENTIALS` instead.

Do not commit `*.json` keys.

# The public demo's hosts

A host runs the demo stack of [docs/DEPLOY_DEMO.md](../../docs/DEPLOY_DEMO.md) behind Caddy. The scripts here provision it and keep it current; the runbook stays the reference for the stack itself. A host is a Compute Engine VM that the Terraform configuration creates (the steps below), or any Debian or Ubuntu machine you can reach over SSH ([A host outside Google Cloud](#a-host-outside-google-cloud)).

| file | where it runs | what it does |
|---|---|---|
| `terraform/` | your machine | enables the APIs, reserves a static address, opens 80 and 443 (SSH through IAP only), creates the Earth Engine service account, the VM, and optionally a Cloud DNS zone with the A records |
| `startup.sh` | the VM, first boot, or a host outside Google Cloud, fed over SSH | installs Docker Engine with Compose v2 and Caddy, clones the repository at the requested tag, writes the Caddyfile and a `.env` with every non-secret value; outside Google Cloud, optionally the deploy account |
| `ssh-deploy.sh` | a host outside Google Cloud | the deploy account's only command: checks out a release, `master` or `dev`, then runs `configure.sh` and `update.sh`; what `deploy.yml` runs there over SSH |
| `finish.sh` | the VM, after you complete `.env` | validates the compose configuration, pulls the published images (or builds), starts the stack, runs the section-3 checks |
| `update.sh` | the VM | moves the checkout to a ref and the stack to the matching published images; what `deploy.yml` runs |
| `Caddyfile` | the VM | the TLS proxy for the domain, with `www` redirected for an apex domain |

Sizing: `e2-standard-2` (2 vCPU, 8 GB, about 50 USD a month) runs the models on CPU in some minutes; `e2-standard-4` halves that at twice the price. Below 8 GB the model steps can run out of memory. The disk is 30 GB: the images take about 1.2 GB, the model weights 0.5 GB, and the rest is for uploads and results.

## Steps

1. **Sign in and pick the project.** `gcloud auth login`, then note the project id (not the number) and make sure billing is on for it.
2. **Create the host with Terraform** (no secret enters the configuration or the state):

   ```sh
   cd deploy/gcp/terraform
   cp terraform.tfvars.example terraform.tfvars   # set project; ref = dev until the release is tagged
   terraform init
   terraform plan
   terraform apply
   ```

   The outputs give the static address, the zone's nameservers, the Earth Engine service account and the `ssh` command. Re-running `apply` is safe; `terraform destroy` removes everything except the APIs.
3. **DNS.** With `manage_dns = true` (the default) Terraform created a Cloud DNS zone: at the registrar, replace the nameservers with the four from the `name_servers` output and wait for the change to spread (minutes to a few hours). With `manage_dns = false`, create two A records at the registrar instead, `@` and `www`, to the static address. Caddy fetches the certificate as soon as the name resolves to the host.
4. **Earth Engine:** register the project for noncommercial use at <https://code.earthengine.google.com/register>. The VM runs as the `earth_engine_service_account` output, so there is no key to create or copy: `startup.sh` sets `GEE_USE_DEFAULT_CREDENTIALS=true` and the client library takes the credentials from the instance metadata. (Organisation policy forbids service-account keys on new projects anyway.)
5. **The GitHub OAuth app:** runbook section 5, with the callback `https://<domain>/v1/auth/github/callback`.
6. **On the VM:** complete `.env`, start. With the GitHub environment of the next section this step is not needed: the first "Deploy dt4lc.org" run writes those values and starts the stack.

   ```sh
   gcloud compute ssh dt4lc-demo --zone <zone> --tunnel-through-iap   # the ssh output
   sudo nano /opt/dt4lc/.env          # the OAuth app, the allowlists, the LLM key
   sudo /opt/dt4lc/deploy/gcp/finish.sh
   ```

   `startup.sh` logs to the serial console; `sudo journalctl -u google-startup-scripts` shows it. It takes a few minutes after the VM boots.
7. **Smoke test from outside:** the landing page, "Try with the Kakhovka sample", a sixth guest analysis refused, sign-in as an operator, `curl -s https://<domain>/v1/health`.
8. **Upgrades and backups:** runbook section 10. `resources/.cache/` holds the job database, uploads, outputs and the settings overrides.

## Automatic deploys from GitHub Actions

`.github/workflows/deploy.yml` does two things, and both are no-ops until the repository variables exist, so forks and contributors are unaffected:

- **containers:** after "Docker Build & Push" has published the images of a release tag, of `master` or of `dev`, it picks the host's GitHub environment (`dt4lc.org` for a tag or `master`, `dev.dt4lc.org` for `dev`, see [The dev host](#the-dev-host)), opens an IAP tunnel to that host, writes the environment's variables and secrets into the host's `.env` (`configure.sh`, names in the log, never values) and runs `update.sh` with that ref and image tag. When the environment sets `DEPLOY_SSH_HOST`, the host is outside Google Cloud and the same happens over one SSH connection instead ([A host outside Google Cloud](#a-host-outside-google-cloud)). A merge into `master` therefore reaches the demo a few minutes later as `latest`; a tag reaches it as its version. `workflow_dispatch` deploys a release tag, `master` or `dev` by hand.
- **Terraform:** `plan` on pull requests that touch `deploy/gcp/terraform/`, `apply` on `master` when `TF_APPLY_IN_CI` is `true`. This job stays off until `TF_STATE_BUCKET` is set: it needs the state in that bucket (`backend.gcs.tf.example`, then `terraform init -migrate-state` from the machine that applied) a deployer that may manage every resource in the configuration, not only the three roles the app deploy needs (`ci.tf`), and the same values as the local `terraform.tfvars` (the job passes only project, zone, domain and repository; anything else falls back to the defaults in `variables.tf`). Until then, apply locally; the app deploys do not depend on it. The CI identity trusts only jobs of the deploy environments (below), and this job declares none, so it also needs an environment of its own, or another identity, before it can authenticate.

Authentication to Google Cloud is Workload Identity Federation: Terraform creates a `dt4lc-deployer` service account that GitHub Actions of this repository may impersonate, and only from jobs of the environments in `github_environments`: `dt4lc.org`, whose branch rule admits `master` and `v*` tags, and `dev.dt4lc.org`, whose rule admits `master` and `dev`. A workflow on any other branch gets no token. No key is stored in GitHub for these hosts, and no project id or secret is in the repository. A host outside Google Cloud is the exception: its environment holds one deploy key, which can only deploy ([A host outside Google Cloud](#a-host-outside-google-cloud)).

Who can deploy, then, is who can get a commit onto `master` or tag it, and, while `dev` is in the rule of `dev.dt4lc.org`, onto `dev`: the deployer's roles are project-wide, so a workflow that holds its token can reach both hosts. The `master` ruleset requires a reviewed pull request, and a tag ruleset for `v*` should restrict tag creation to administrators, or anyone with write access could tag any commit and have it deployed. A manual "Docker Build & Push" publishes images only when run from `master` or a `v*` tag, so a branch build cannot overwrite a released image tag. The fast-forward sync's deploy key lives in the `sync-dev` environment, limited to `master`.

Set-up, once, by the project owner:

1. Apply locally (steps 1 and 2 above). `terraform output github_actions_variables` prints the values; with `dev_vm = true`, `terraform output github_actions_variables_dev` prints those of the dev host's environment.
2. In the repository: Settings → Secrets and variables → Actions → Variables: `GCP_PROJECT_ID`, `GCP_WIF_PROVIDER`, `GCP_DEPLOYER_SA`, `GCP_ZONE`, `GCP_VM`, `DEMO_DOMAIN`. For Terraform in CI, also `TF_STATE_BUCKET` (a bucket you created, see `backend.gcs.tf.example`) and `TF_APPLY_IN_CI`.
3. Make the two packages public (the package's settings → Change visibility), or the host cannot pull them; the release notes already tell readers to pull them.
4. Settings → Environments → New environment → `dt4lc.org` (the Deployments page then lists the site by its address); under "Deployment branches and tags" choose "Selected branches and tags" and add `master` and `v*`, so no other branch's workflow can read what follows. Its variables: `OAUTH_CLIENT_ID`, `OPERATOR_EMAILS`, `ALLOWED_EMAILS`, `ALLOWED_DOMAINS`, `LLM_PROVIDER_ORDER`; its secrets: `OAUTH_CLIENT_SECRET` and the provider keys you use among `GEMINI_API_KEY`, `OPENAI_API_KEY`, `GROQ_API_KEY`. GitHub reserves the `GITHUB_` prefix, hence the `OAUTH_` names; on the host they become `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET`. Every deploy writes the non-empty ones, so a value changed here reaches the host on the next deploy, "Run workflow" included. `SESSION_SECRET` stays on the host, generated at first boot. When the demo runs on a host outside Google Cloud, this environment also holds the values that reach it over SSH ([A host outside Google Cloud](#a-host-outside-google-cloud)).
5. For the dev host, the environment `dev.dt4lc.org`: [The dev host](#the-dev-host).
6. For the fast-forward sync of `dev`: a deploy key with write access (Settings → Deploy keys), its private half as the secret `SYNC_DEPLOY_KEY` of an environment `sync-dev` whose branch rule admits `master` only, and "Deploy keys" in the bypass list of the `dev` ruleset. Without it the sync opens a pull request instead.
7. A tag ruleset (Settings → Rules → Rulesets → New tag ruleset, target `v*`) that restricts creation, update and deletion to administrators.

Anyone deploying their own instance uses the same Terraform with their own `terraform.tfvars`; with `github_repository = ""` no CI identity is created.

## The dev host

A second VM, `dt4lc-dev`, serves the latest `dev` branch at <https://dev.dt4lc.org>, so merged work can be tried on the demo's set-up before a release. Anyone may open it; only signed-in team members can run analyses.

- **Size:** the same as the demo, `e2-standard-2` with 30 GB, about 50 USD a month more. The backend holds about 1.4 GiB idle and grows by a few hundred MiB per analysis, so a 4 GB machine would be marginal, and with the same size a result on dev reproduces on the demo.
- **Creating it:** `dev_vm = true` in `terraform.tfvars`, then `terraform plan` and `terraform apply`. Terraform adds a static address, the VM (`dev.tf`: the demo's image, firewall tags, OS Login and service account, checking out `dev` with the `dev` images) and, with `manage_dns`, the A record `dev.<domain>`; without `manage_dns`, create that record at the registrar. There is no `www` record for it, and `startup.sh` writes no `www` block into its Caddyfile. The outputs `dev_static_ip`, `dev_ssh` and `github_actions_variables_dev` give the address, the ssh command and the environment's two variables.
- **The second OAuth app:** an OAuth app has one callback URL, so the dev host has its own app (runbook section 5), with the callback `https://dev.dt4lc.org/v1/auth/github/callback`.
- **The environment `dev.dt4lc.org`** (Settings → Environments → New environment). Under "Deployment branches and tags", "Selected branches and tags": `master` and `dev`.
  - `master` is required. A workflow started by `workflow_run`, as the deploy after an image build is, runs with `GITHUB_REF` set to the default branch, whatever branch the triggering run built; the tag deploys pass the rule of `dt4lc.org` because `master` is in it, not because of `v*`. So the branch rule decides only which workflows may use an environment, and the host is selected by the environment the deploy job chooses from the built branch.
  - `dev` lets "Run workflow" start from `dev`'s copy of the workflow. It also lets any workflow on `dev` take the deployer identity, which reaches both hosts; leave it out to keep that to `master`, and run manual dev deploys from `master` with the ref `dev`.
  - Variables: `GCP_VM` = `dt4lc-dev` and `DEMO_DOMAIN` = `dev.dt4lc.org` (in this environment's jobs they override the repository variables of the same name, so the deploy reaches this host and the Deployments page links to it); `GUEST_ANALYSES_PER_HOUR` = `0` (a limit of 0 refuses every guest analysis, while guests can still open the site); `OAUTH_CLIENT_ID` of the second app; `OPERATOR_EMAILS`, `ALLOWED_EMAILS`, `ALLOWED_DOMAINS` and `LLM_PROVIDER_ORDER` as for the demo.
  - Secrets: `OAUTH_CLIENT_SECRET` of the second app and the provider keys among `GEMINI_API_KEY`, `OPENAI_API_KEY` and `GROQ_API_KEY`. An environment's secrets are its own, so they are set again here.
- **On a push to `dev`:** "Docker Build & Push" publishes `ghcr.io/ipt-mmda/dt4lc/backend:dev` and `frontend:dev`. When it succeeds, the deploy (the copy of `deploy.yml` on `master`, which `workflow_run` always runs) maps `dev` to the environment `dev.dt4lc.org`, writes its values into the dev host's `.env`, moves the checkout to `origin/dev` and runs `update.sh dev dev`. The fast-forward sync after a release pushes `dev` too, so the dev host follows a release. A push that changes only documentation builds and deploys nothing. The first deploy after `apply` writes the values and starts the stack; wait until the serial console shows `dt4lc: provisioned` before it, or start it with "Run workflow" and the ref `dev`.
- **What it shares:** dev has its own job database, uploads, results, settings and session secret (its own `resources/.cache/` and `.env`), so sign-ins and results do not carry over between the hosts. It runs as the same Earth Engine service account in the same project, and with the same provider key it shares the Gemini quota with the demo.

## A host outside Google Cloud

The same scripts run the demo on a plain Debian or Ubuntu host, at another provider or on your own hardware. Terraform does not create it, and GitHub Actions reaches it over SSH instead of an IAP tunnel.

- **What it needs:** Debian or Ubuntu on amd64, the architecture the images are built for (Debian 12 and Ubuntu 24.04 are known to work); the size of the Google VM (2 vCPU, 8 GB of memory, 30 GB of disk); an account with passwordless `sudo`; ports 22, 80 and 443 open to the internet; and outbound HTTPS to the distribution's mirrors, GitHub and its container registry, Docker's and Caddy's package repositories, Let's Encrypt, Google's APIs (Earth Engine, Gemini) and Hugging Face (the model weights).
- **Bootstrap,** from the repository on your machine: a key pair for the deploys, without a passphrase, then `startup.sh` fed to the host.

  ```sh
  ssh-keygen -t ed25519 -N '' -C 'dt4lc deploy' -f dt4lc-deploy-key
  ssh <user>@<host address> "sudo DT4LC_DOMAIN=dt4lc.org DT4LC_REF=v0.6.2 DT4LC_GEE_PROJECT=<Earth Engine project> DT4LC_DEPLOY_KEY='$(cat dt4lc-deploy-key.pub)' bash -s" < deploy/gcp/startup.sh
  ```

  The variables stand in for the VM's instance attributes: `DT4LC_DOMAIN` (default `dt4lc.org`), `DT4LC_REF`, a release tag (default `v0.6.2`), and `DT4LC_IMAGE_TAG` only when the image tag is not the one derived from the ref. `DT4LC_GEE_PROJECT` and `DT4LC_DEPLOY_KEY` are optional and explained below. The script installs Docker and Caddy, clones the repository at the ref, drafts `.env` and ends with `dt4lc: provisioned`; if it stops before that, fix the cause and run it again. Keep the private half, `dt4lc-deploy-key`, for the GitHub environment.
- **The deploy account.** With `DT4LC_DEPLOY_KEY` the script creates a system user, `dt4lc-deploy`, without a password. Its only key is that one, with `restrict` and a forced command: whatever the client asks for, the host runs `sudo -n /usr/local/sbin/dt4lc-deploy`, and a sudoers rule lets the account run that root-owned program and nothing else. The program is `ssh-deploy.sh`. It takes two words, a release tag, `master` or `dev`, and an image tag, in the shapes `deploy.yml` accepts, and refuses anything else; then it does what the two IAP steps do: it moves the checkout to the ref and runs that ref's `configure.sh`, with the NAME=VALUE lines it reads on stdin, and its `update.sh`. So the key opens no shell, forwards no port, copies no file and runs no other command; at most it deploys a release, `master` or `dev`. `startup.sh` installs its own copy of the program, because the release it checks out may be older than the program.
- **Earth Engine.** Outside Google Cloud there are no default credentials, so the backend uses a service account's key. Create a service account in a project whose organisation allows keys, give it `roles/earthengine.writer` and `roles/serviceusage.serviceUsageConsumer` on the Earth Engine project, create a JSON key, and copy it to the host without showing it:

  ```sh
  ssh <user>@<host address> 'sudo install -m 600 -o root -g root /dev/stdin /opt/dt4lc/resources/key_gee.json' < key.json
  ```

  With `DT4LC_GEE_PROJECT`, `startup.sh` has already set `GEE_PROJECT_ID` to that project and `GEE_SERVICE_ACCOUNT_KEY=/app/resources/key_gee.json`: the backend sees `resources/` at `/app/resources`, and git ignores the file. To rotate the key, replace the file the same way and restart the backend.
- **First start:** `sudo /opt/dt4lc/deploy/gcp/finish.sh`. Its notes about the missing sign-in and LLM values go away with the first deploy, which writes them.
- **The GitHub environment.** Next to the values of set-up step 4 above, the host's environment (`dt4lc.org` for the demo) holds:
  - `DEPLOY_SSH_HOST` (variable): the host's address or name;
  - `DEPLOY_SSH_KNOWN_HOSTS` (variable): the host's `known_hosts` line, from `ssh-keyscan -t ed25519 <host address>`, once `ssh-keygen -lf -` on that line shows the fingerprint that the host shows for `/etc/ssh/ssh_host_ed25519_key.pub`;
  - `DEPLOY_SSH_KEY` (secret): the private half of the deploy key;
  - `DEPLOY_SSH_USER` (variable), only when the account is not `dt4lc-deploy`.

  `deploy.yml` chooses the transport by `DEPLOY_SSH_HOST`. When the environment sets it, the job skips the Google Cloud steps and sends the environment's values over one SSH connection to the deploy account, with the ref and the image tag as its only words, and the account configures and updates the host. The host key is pinned (`StrictHostKeyChecking=yes` against that line, never a key learnt on the way), and the job stops when the line or the key is missing. Without `DEPLOY_SSH_HOST` the job runs as before, over IAP, so the Google hosts are unaffected; deleting the variable sends the next deploy back to the Google VM.
- **DNS.** With the Cloud DNS zone of the Terraform configuration, set `demo_address = "<host address>"` in `terraform.tfvars`: `terraform plan` then changes the `@` and `www` records in place, and nothing else. Without the zone, change the two A records at the registrar. Caddy asks for the certificate as soon as it starts and waits longer after each failure before it asks again, so once the name points at the host, `sudo systemctl restart caddy` there gets the certificate at once.
- **What differs from Google Cloud.** The Google path stores no secret in GitHub: the deploy job gets a short-lived token through Workload Identity Federation. The SSH path stores one, the deploy key. Only jobs of the host's environment can read it, and the environment's branch rule admits only `master` and `v*` tags; on the host the key can do nothing but deploy, as the forced command and the sudoers rule enforce. Who can deploy is the same either way: whoever can get a commit onto `master` or tag one. A host without disk snapshots also needs backups of `resources/` and `.env` (runbook section 10).

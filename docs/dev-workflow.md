# Development Workflow

This document describes the recommended workflow for developing SkillHub locally.

## Prerequisites

- Docker Desktop (for dependency services and staging)
- Java 21 (for running the backend locally)
- Node.js 22 + pnpm (for running the frontend locally)
- `gh` CLI (for creating pull requests): https://cli.github.com/

## Stage 1: Local Development (fast iteration)

Use this stage for active development — writing code, fixing bugs, iterating quickly.

### Start the full local stack

```bash
make dev-all
```

This starts:
- Dependency services (Postgres, Redis, MinIO) via Docker
- Backend (Spring Boot) directly on your machine at http://localhost:8080
- Frontend (Vite) directly on your machine at http://localhost:3000

SkillHub now pins a shared Docker Compose project name for local development, so multiple git worktrees can reuse the same dependency containers instead of fighting over `5432`, `6379`, and `9000`.

Dependency endpoints:

| Service  | Endpoint | Credentials |
|----------|----------|-------------|
| Postgres | `localhost:5432/skillhub` | `skillhub` / `skillhub_dev` |
| Redis    | `localhost:6379` | none |
| MinIO    | http://localhost:9000 (console http://localhost:9001) | `minioadmin` / `minioadmin` |

The dev backend uses local file storage by default. To run it against the bundled MinIO instead:

```bash
make dev-all DEV_STORAGE_PROVIDER=s3
```

### Security scanner (optional)

`make dev-all` does **not** start the security scanner: it is built from `./scanner` and needs Docker
Hub access for its Python base image, which is slow and can fail offline. Without it the backend is
started with `SKILLHUB_SECURITY_SCANNER_ENABLED=false`, so publishing still works.

To enable scanning:

```bash
make dev-scanner            # builds ./scanner, or uses SKILLHUB_SCANNER_IMAGE when set
make dev-server-restart     # restarts the backend with scanning enabled
```

If the local build cannot reach Docker Hub, run the scanner from a prebuilt image:

```bash
make dev-scanner DEV_SCANNER_IMAGE=ghcr.io/futurealab/skillhub-scanner:v0.2.222
```

Set `DEV_WITH_SCANNER=1` to have `make dev-all` attempt the scanner as part of the startup.

### Trusted-header (SSO) test stack

`docker-compose.trusted-header.yml` is a self-contained stack whose whole purpose is to exercise
trusted-header authentication: **nginx sits in front of the backend and injects the identity headers
on every forwarded request**, which is what a forward-auth gateway (oauth2-proxy, Authelia,
Authentik, nginx `auth_request`) does in production.

```bash
make trusted-header-test        # start the published release images + run assertions
make trusted-header-smoke       # re-run the assertions only
make trusted-header-test-down   # stop
make trusted-header-test-reset  # stop and drop its volumes
```

Endpoints:

| URL | What it is |
|-----|------------|
| http://localhost:8081 | The gateway. Headers are injected, so `/api/v1/auth/me` answers with the injected user and the SPA signs in without a login page. |
| http://localhost:18080 | The backend directly, with no headers. Used to prove that bypassing the gateway is rejected. |

What the stack does:

- Backend runs with `SKILLHUB_AUTH_TRUSTED_HEADER_ENABLED=true`,
  `SKILLHUB_AUTH_TRUSTED_HEADER_PER_REQUEST_AUTHENTICATION=true` and
  `SKILLHUB_AUTH_TRUSTED_HEADER_SESSION_OVERRIDE=true`, so every request carrying the headers is
  signed in (no login page, no bootstrap call) and those headers also replace an existing session.
- The gateway injects `X-Auth-Request-User`, `X-Forwarded-Email` and `X-Skillhub-Proxy-Secret`.
- `X-Test-User` / `X-Test-Email` on a request override the injected identity, which makes it easy to
  switch users (each new one is provisioned on first sight):
  `curl -H 'X-Test-User: alice' http://localhost:8081/api/v1/auth/me`
- The `skillhub_name` / `skillhub_email` cookies are mapped by the gateway onto the same trusted
  headers, which is how an embedding page (iframe) supplies the identity. A non-empty cookie wins
  over `X-Test-*` and over the fixed default:
  `curl -H 'Cookie: skillhub_name=alice; skillhub_email=alice@corp.example' http://localhost:8081/api/v1/auth/me`
  The backend still reads identity from headers only and never from a cookie. Two constraints come
  with this: `X-Auth-Request-User` doubles as the account binding key, so `skillhub_name` must stay
  stable for a given person — changing it provisions a new account instead of renaming the existing
  one; and the value must be **ASCII**, because nginx rejects non-ASCII header values (a browser
  sending a raw UTF-8 cookie gets `400`, and percent-encoding it with `encodeURIComponent` reaches
  the backend as the literal `%E5%BC%A0%E4%B8%89`). Use an ASCII login/employee id such as
  `zhangsan`, not a display name like `张三`.
- Without `SESSION_OVERRIDE` an existing session always wins: a browser that is already signed in
  keeps its identity even when the gateway asserts another one (this is why a hand-set cookie
  appears to be ignored while a `SESSION` cookie is present). With it enabled the headers win, so a
  cookie switches the user of a live session. Logging out does not stick in that mode — the gateway
  keeps asserting an identity, so the account is signed back in on the next request.
- The assertions also cover the negative paths: a direct request without headers, and one with a
  missing or wrong shared secret, must both return `401`.

Values can be overridden at invocation time, e.g.
`make trusted-header-test TRUSTED_HEADER_TEST_USER=alice TRUSTED_HEADER_TEST_EMAIL=alice@corp.example`,
or `TRUSTED_HEADER_TEST_SECRET=` to run without the shared secret (the secret assertions are then
skipped). `TRUSTED_HEADER_SERVER_IMAGE` and `TRUSTED_HEADER_GATEWAY_IMAGE` select which published
release images the stack runs; nothing is built from source.

> **Test-only:** the `X-Test-User` override is an impersonation backdoor by design. Never copy
> `docker/trusted-header/*.conf.template` into a real gateway, where the identity must come from the
> authenticated session.

### Backend restarts

**Frontend:** Vite HMR is enabled by default. Save a file and the browser updates instantly.

**Backend:** the local server now runs from a packaged Spring Boot jar instead of `spring-boot:run`. This avoids mixed classpaths across `skillhub-app`, `skillhub-auth`, `skillhub-domain`, and other sibling modules.

After editing backend code, restart the backend explicitly:

```bash
make dev-server-restart
```

If you are running the server in a foreground terminal instead of `make dev-all`, stop it and run `make dev-server` again. Expect a full restart in about 5-10 seconds, including rebuilding the backend modules.

### Mock authentication

Two mock users are available in local mode (no password needed):

| User ID       | Role        | Header                           |
|---------------|-------------|----------------------------------|
| `local-user`  | Regular user | `X-Mock-User-Id: local-user`   |
| `local-admin` | Super admin  | `X-Mock-User-Id: local-admin`  |

Local development also creates a password-based bootstrap admin by default.
Use `BOOTSTRAP_ADMIN_USERNAME` / `BOOTSTRAP_ADMIN_PASSWORD` to log in through
the normal local account form. The default local fallback credentials are
`admin` / `ChangeMe!2026`.
To disable it for local source startup, set the environment variable
`BOOTSTRAP_ADMIN_ENABLED=false` before starting the backend.
For container or release environments, set the same value in `.env.release`
or the Compose environment.

### Useful commands

| Command                          | Description                      |
|----------------------------------|----------------------------------|
| `make dev-all`                   | Start full local stack (deps + backend + frontend) |
| `make dev`                       | Start only dependencies (Postgres/Redis/MinIO) |
| `make dev-scanner`               | Start the optional security scanner |
| `make trusted-header-test`       | Start the trusted-header (SSO) test stack and assert it |
| `make trusted-header-smoke`      | Re-run the trusted-header assertions |
| `make trusted-header-test-down`  | Stop the trusted-header test stack |
| `make dev-all-down`              | Stop all local services          |
| `make dev-status`                | Check status of all services     |
| `make dev-logs`                  | Tail backend logs                |
| `SERVICE=frontend make dev-logs` | Tail frontend logs               |
| `make dev-all-reset`             | Full reset (clears data volumes) |
| `make dev-db-check`              | Verify the dev database credentials |
| `make dev-db-repair`             | Sync the dev database password (keeps data) |
| `make dev-server-restart`        | Restart backend after Java changes |
| `make namespace-smoke`           | Run namespace workflow smoke test |
| `make db-reset`                  | Reset database only              |

### Troubleshooting the local stack

**Backend log shows `FATAL: password authentication failed for user "skillhub"`.**
`POSTGRES_PASSWORD` in `docker-compose.yml` is applied only when the Postgres data volume is first
created, so a volume created earlier can keep a different password while the backend keeps using the
password from `application-local.yml`. `make dev` now runs `make dev-db-check` and fails with this
explanation. Repair it in place (no data loss):

```bash
make dev-db-repair
```

Or drop all dev data with `make dev-all-reset`. Note that inside the container `127.0.0.1`
connections use `trust` auth, so testing the password with a plain
`docker compose exec postgres psql -h 127.0.0.1` proves nothing — `make dev-db-check` connects over
the container's non-loopback address so the password is actually verified.

**`make dev-all` fails while building the scanner.** The scanner is built from `./scanner` and needs
Docker Hub access. It is optional: use `make dev-scanner` (or
`make dev-scanner DEV_SCANNER_IMAGE=<image>`), and see the section above.

**`.dev/server.log` grew very large.** Logs are rotated on start (the previous run is kept as
`.dev/server.log.1`) and capped by `DEV_LOG_MAX_BYTES` (default 64 MiB). A stream consumer that
cannot read its Redis stream now recreates the consumer group and rate-limits its error logging
instead of spinning.

### Claude + Codex parallel workflow

When two agents need to work in parallel, do not point both of them at the same checkout. Create isolated task worktrees instead:

```bash
make parallel-init TASK=legal-pages
```

That creates dedicated Claude, Codex, and integration worktrees as sibling directories. Keep `localhost:3000` reserved for the integration worktree only.

After the one-time setup, switch to the integration worktree for the daily merge + verification loop:

```bash
cd ../skillhub-integration-legal-pages
make parallel-up
```

Then verify the merged result at http://localhost:3000.

Because all worktrees share the same local dependency project, you only need one set of Postgres, Redis, and MinIO containers for all of them.

If you need to inspect or resolve merge conflicts before starting the app, you can still split the flow manually:

```bash
cd ../skillhub-integration-legal-pages
make parallel-sync
make dev-all
```

See [13-parallel-workflow.md](./13-parallel-workflow.md) for the full workflow, responsibilities, merge rules, and recovery guidance.

## Stage 2: Staging Regression (pre-PR validation)

Use this stage when a feature or bugfix is complete and you want to verify it works correctly in a Docker environment before pushing.

### What staging does

`make staging` runs a **hybrid** Docker environment:
- **Backend**: built as a Docker image from your local source
- **Frontend**: built as static files (`pnpm build`) and served by Nginx
- **Dependencies**: same Postgres/Redis/MinIO as local dev

This is faster than building both images but still validates the containerized backend and the production Nginx serving path.

### Run staging

```bash
make staging
```

This will:
1. Build the backend Docker image
2. Build the frontend static files
3. Start all services
4. Run smoke tests against the API
5. Print pass/fail summary

`scripts/smoke-test.sh` separates bootstrap creation from smoke credentials.
Admin smoke checks run only when `SMOKE_ADMIN_USERNAME` and
`SMOKE_ADMIN_PASSWORD` are provided. Use `SMOKE_ADMIN_CHECKS=false` when testing
a persistent environment where the current admin password is not part of the
smoke run.

If all tests pass, the environment stays running at:
- Web UI: http://localhost
- Backend API: http://localhost:8080

### Stop staging

```bash
make staging-down
```

### View staging logs

```bash
make staging-logs            # backend logs
SERVICE=web make staging-logs  # nginx logs
```

## Stage 3: Create Pull Request

After staging passes:

```bash
make pr
```

This will:
1. Check for uncommitted changes (prompts to commit if any)
2. Push your branch to origin
3. Create a pull request using `gh pr create --fill`

The PR title and body are auto-populated from your commit messages.

> **Note:** `make pr` requires an interactive terminal. Do not use it in CI.

## Full workflow summary

```
make dev-all          # start local dev
# ... write code, test in browser ...
make staging          # regression test in Docker
make staging-down     # stop staging
make pr               # push + create PR
```

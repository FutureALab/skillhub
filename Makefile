.PHONY: build build-backend build-backend-app build-builtin-skills build-cli build-frontend build-web check clean cli-install db-reset dev dev-all dev-all-down dev-all-reset dev-db-check dev-db-repair dev-down dev-logs dev-scanner dev-server dev-server-env dev-server-restart dev-status dev-web docs-build docs-dev docs-preview generate-api help lint-cli lint-web namespace-smoke suite-smoke suite-bundle-smoke parallel-down parallel-init parallel-sync parallel-up pr publish-cli publish-cli-major publish-cli-minor staging staging-down staging-logs test test-backend test-backend-app test-builtin-skills test-cli test-e2e-frontend test-e2e-smoke-frontend test-frontend test-redis-cluster test-web trusted-header-build trusted-header-smoke trusted-header-test trusted-header-test-down trusted-header-test-reset typecheck-cli typecheck-web validate-release-config web-deps web-install web-install-ci

DEV_DIR := .dev
DEV_SERVER_PID := $(DEV_DIR)/server.pid
DEV_WEB_PID := $(DEV_DIR)/web.pid
DEV_SERVER_LOG := $(DEV_DIR)/server.log
DEV_WEB_LOG := $(DEV_DIR)/web.log
DEV_WEB_URL := http://localhost:3000
DEV_WEB_HOST ?= 127.0.0.1
DEV_API_URL := http://localhost:8080
DEV_SCANNER_URL := http://localhost:8000
STAGING_API_URL := http://localhost:8080
STAGING_WEB_URL := http://localhost
STAGING_SERVER_IMAGE := skillhub-server:staging
DEV_PROCESS := bash scripts/dev-process.sh
DEV_SERVER_PREPARE := true
DEV_SERVER_CMD := ./scripts/run-dev-app.sh
# Dependency services started by `make dev` / `make dev-all`. The security scanner is intentionally
# NOT here: it is built locally and needs Docker Hub access, which must not block the dev stack.
DEV_DEPS_SERVICES ?= postgres redis minio
# Backend dev environment derived from the services that are actually running.
# Absolute so the launched process reads it after dev-process.sh switches to --cwd server.
DEV_SERVER_ENV := $(CURDIR)/$(DEV_DIR)/server.env
DEV_SERVER_LAUNCH := env $$(cat $(DEV_SERVER_ENV) 2>/dev/null | xargs) $(DEV_SERVER_CMD)
DEV_SERVER_BACKGROUND := $(DEV_PROCESS) start --pid-file $(DEV_SERVER_PID) --log-file $(DEV_SERVER_LOG) --cwd server -- bash -lc '$(DEV_SERVER_PREPARE) && exec $(DEV_SERVER_LAUNCH)'
# Set DEV_WITH_SCANNER=1 to start the scanner from `make dev-all` as well.
DEV_WITH_SCANNER ?= 0
# Prebuilt scanner image; when empty the scanner is built from ./scanner.
DEV_SCANNER_IMAGE ?=
# Set DEV_STORAGE_PROVIDER=s3 to run the dev backend against the bundled MinIO.
DEV_STORAGE_PROVIDER ?= local
DEV_S3_ENDPOINT ?= http://localhost:9000
DEV_S3_BUCKET ?= skillhub
DEV_S3_ACCESS_KEY ?= minioadmin
DEV_S3_SECRET_KEY ?= minioadmin
# Dev database credentials; must match docker-compose.yml and application-local.yml.
DEV_DB_USER ?= skillhub
DEV_DB_NAME ?= skillhub
DEV_DB_PASSWORD ?= skillhub_dev

# Trusted-header test stack (docker-compose.trusted-header.yml): nginx injects the identity headers.
TRUSTED_HEADER_PROJECT ?= skillhub-th
TRUSTED_HEADER_COMPOSE := docker compose -p $(TRUSTED_HEADER_PROJECT) -f docker-compose.trusted-header.yml
TRUSTED_HEADER_GATEWAY_URL ?= http://localhost:8081
TRUSTED_HEADER_DIRECT_URL ?= http://localhost:18080
TRUSTED_HEADER_TEST_USER ?= gateway-user-1
TRUSTED_HEADER_TEST_EMAIL ?= gateway-user-1@example.com
# `${VAR-default}` semantics: pass TRUSTED_HEADER_TEST_SECRET= to disable the shared-secret check.
TRUSTED_HEADER_TEST_SECRET ?= trusted-header-test-secret
TRUSTED_HEADER_SERVER_IMAGE ?= skillhub-server:trusted-header-test
TRUSTED_HEADER_SERVER_BASE_IMAGE ?= ghcr.io/futurealab/skillhub-server:v0.2.222
BACKEND_TEST_JAVA_OPTIONS ?= -XX:+EnableDynamicAgentLoading
PARALLEL_BASE_REF ?= origin/main
PARALLEL_WORKTREE_ROOT ?=
DEV_COMPOSE_PROJECT_NAME ?= skillhub
STAGING_COMPOSE_PROJECT_NAME ?= skillhub-staging
DEV_COMPOSE := docker compose -p $(DEV_COMPOSE_PROJECT_NAME) -f docker-compose.yml -f docker-compose.dev.yml
STAGING_BASE_COMPOSE := docker compose -p $(STAGING_COMPOSE_PROJECT_NAME)
STAGING_COMPOSE := $(STAGING_BASE_COMPOSE) -f docker-compose.yml -f docker-compose.staging.yml

help: ## 显示帮助
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

dev: ## 启动本地开发依赖服务（Postgres + Redis + MinIO）
	$(DEV_COMPOSE) up -d --wait --remove-orphans $(DEV_DEPS_SERVICES)
	@$(MAKE) --no-print-directory dev-db-check
	@$(MAKE) --no-print-directory dev-server-env
	@echo "Dependency services ready:"
	@echo "  Postgres: localhost:5432 (user skillhub / password skillhub_dev / db skillhub)"
	@echo "  Redis:    localhost:6379"
	@echo "  MinIO:    http://localhost:9000  (console http://localhost:9001, minioadmin / minioadmin)"
	@echo "Start backend with: make dev-server"
	@echo "Start frontend with: make dev-web"
	@echo "Start the security scanner with: make dev-scanner"

dev-db-check: ## 校验开发数据库凭据是否与配置一致
	@if ! $(DEV_COMPOSE) ps --status running --services 2>/dev/null | grep -qx postgres; then \
		echo "Postgres container is not running. Start it with: make dev"; \
		exit 1; \
	fi; \
	if $(DEV_COMPOSE) exec -T postgres sh -c 'PGPASSWORD="$$POSTGRES_PASSWORD" psql -h "$$(hostname -i)" -U $(DEV_DB_USER) -d $(DEV_DB_NAME) -tAc "select 1" >/dev/null 2>&1'; then \
		echo "Postgres credentials OK ($(DEV_DB_USER)@$(DEV_DB_NAME))."; \
	else \
		echo ""; \
		echo "Postgres rejected the dev credentials for role '$(DEV_DB_USER)'."; \
		echo "POSTGRES_PASSWORD is only applied when the data volume is first created, so an"; \
		echo "existing volume can keep an older password."; \
		echo ""; \
		echo "  修复（保留数据）: make dev-db-repair"; \
		echo "  完全重置（删数据）: make dev-all-reset"; \
		echo ""; \
		exit 1; \
	fi

dev-db-repair: ## 将开发数据库密码同步为配置期望值（保留数据）
	$(DEV_COMPOSE) exec -T postgres psql -U $(DEV_DB_USER) -d $(DEV_DB_NAME) \
		-c "ALTER ROLE $(DEV_DB_USER) WITH PASSWORD '$(DEV_DB_PASSWORD)';"
	@$(MAKE) --no-print-directory dev-db-check

dev-scanner: ## 启动安全扫描服务（可用 DEV_SCANNER_IMAGE 指定预构建镜像）
	@if [ -n "$(DEV_SCANNER_IMAGE)" ]; then \
		echo "Starting scanner from DEV_SCANNER_IMAGE=$(DEV_SCANNER_IMAGE)..."; \
		SKILLHUB_SCANNER_IMAGE=$(DEV_SCANNER_IMAGE) $(DEV_COMPOSE) up -d --wait skill-scanner \
			|| { echo "Scanner failed to start. Check the image reference or Docker Hub access."; exit 1; }; \
	else \
		echo "Starting scanner (SKILLHUB_SCANNER_IMAGE=${SKILLHUB_SCANNER_IMAGE:-unset}, builds from ./scanner when no image is configured)..."; \
		$(DEV_COMPOSE) up -d --wait skill-scanner \
			|| { \
				echo ""; \
				echo "Scanner failed to start. The local build needs Docker Hub access for"; \
				echo "python:3.11-slim-bookworm. Retry with a prebuilt image instead:"; \
				echo "  make dev-scanner DEV_SCANNER_IMAGE=<registry>/skillhub-scanner:<tag>"; \
				exit 1; \
			}; \
	fi
	@$(MAKE) --no-print-directory dev-server-env
	@echo "Scanner ready on $(DEV_SCANNER_URL)."
	@echo "If the backend is already running, run: make dev-server-restart"

dev-server-env: ## 依据当前运行的服务生成后端开发环境变量
	@mkdir -p $(DEV_DIR)
	@{ \
		if curl -sf $(DEV_SCANNER_URL)/health >/dev/null 2>&1; then \
			echo "SKILLHUB_SECURITY_SCANNER_ENABLED=true"; \
			echo "SKILLHUB_SECURITY_SCANNER_URL=$(DEV_SCANNER_URL)"; \
			echo "SKILLHUB_SECURITY_SCANNER_MODE=upload"; \
		else \
			echo "SKILLHUB_SECURITY_SCANNER_ENABLED=false"; \
		fi; \
		if [ "$(DEV_STORAGE_PROVIDER)" = "s3" ]; then \
			echo "SKILLHUB_STORAGE_PROVIDER=s3"; \
			echo "SKILLHUB_STORAGE_S3_ENDPOINT=$(DEV_S3_ENDPOINT)"; \
			echo "SKILLHUB_STORAGE_S3_BUCKET=$(DEV_S3_BUCKET)"; \
			echo "SKILLHUB_STORAGE_S3_ACCESS_KEY=$(DEV_S3_ACCESS_KEY)"; \
			echo "SKILLHUB_STORAGE_S3_SECRET_KEY=$(DEV_S3_SECRET_KEY)"; \
			echo "SKILLHUB_STORAGE_S3_FORCE_PATH_STYLE=true"; \
			echo "SKILLHUB_STORAGE_S3_AUTO_CREATE_BUCKET=true"; \
		fi; \
	} > $(DEV_SERVER_ENV)

dev-all: ## 一键启动本地开发环境（Postgres + Redis + MinIO + 后端 + 前端）
	@mkdir -p $(DEV_DIR)
	@$(MAKE) dev
	@$(MAKE) web-deps
	@if [ "$(DEV_WITH_SCANNER)" = "1" ]; then \
		$(MAKE) --no-print-directory dev-scanner || echo "Scanner could not be started; continuing without security scanning."; \
	fi
	@if $(DEV_PROCESS) status --pid-file $(DEV_SERVER_PID) >/dev/null 2>&1; then \
		echo "Backend already running with PID $$(cat $(DEV_SERVER_PID))"; \
	else \
		echo "Starting backend..."; \
		$(DEV_SERVER_BACKGROUND) >/dev/null; \
	fi
	@if $(DEV_PROCESS) status --pid-file $(DEV_WEB_PID) >/dev/null 2>&1; then \
		echo "Frontend already running with PID $$(cat $(DEV_WEB_PID))"; \
	else \
		echo "Starting frontend..."; \
		$(DEV_PROCESS) start --pid-file $(DEV_WEB_PID) --log-file $(DEV_WEB_LOG) --cwd web -- pnpm exec vite --host $(DEV_WEB_HOST) --strictPort >/dev/null; \
	fi
	@echo "Waiting for backend on $(DEV_API_URL) ..."
	@backend_ready=0; \
	for attempt in 1 2; do \
		for i in $$(seq 1 30); do \
			if curl -sf $(DEV_API_URL)/actuator/health >/dev/null; then \
				echo "Backend ready."; \
				backend_ready=1; \
				break 2; \
			fi; \
			if ! $(DEV_PROCESS) status --pid-file $(DEV_SERVER_PID) >/dev/null 2>&1; then \
				break; \
			fi; \
			sleep 2; \
		done; \
		if [ "$$attempt" -lt 2 ]; then \
			echo "Backend did not become ready on attempt $$attempt. Restarting..."; \
			$(DEV_PROCESS) stop --pid-file $(DEV_SERVER_PID); \
			sleep 2; \
			$(DEV_SERVER_BACKGROUND) >/dev/null; \
		fi; \
	done; \
		if [ "$$backend_ready" -ne 1 ]; then \
			echo ""; \
			echo "Backend failed to become ready. Check $(DEV_SERVER_LOG)"; \
			echo ""; \
			echo "Common issues:"; \
			echo "  1. Maven dependency download failed (network timeout)"; \
			echo "     -> Configure mirror in ~/.m2/settings.xml"; \
			echo "     -> See: https://maven.aliyun.com/mvn/guide"; \
			echo "  2. Java version mismatch (requires Java 21+)"; \
			echo "     -> Run: java -version"; \
			echo "  3. Port 8080 already in use"; \
			echo "     -> Run: lsof -i :8080"; \
			echo ""; \
			exit 1; \
		fi
	@if curl -sf $(DEV_SCANNER_URL)/health >/dev/null 2>&1; then \
		echo "Scanner ready."; \
	else \
		echo "Security scanner is not running; the backend was started with SKILLHUB_SECURITY_SCANNER_ENABLED=false."; \
		echo "  Enable it later with: make dev-scanner && make dev-server-restart"; \
	fi
	@echo "Waiting for frontend on $(DEV_WEB_URL) ..."
	@frontend_ready=0; \
	for i in $$(seq 1 60); do \
		if curl -sf $(DEV_WEB_URL) >/dev/null; then \
			echo "Frontend ready."; \
			frontend_ready=1; \
			break; \
		fi; \
		sleep 2; \
	done; \
	if [ "$$frontend_ready" -ne 1 ]; then \
		echo "Frontend failed to become ready. Check $(DEV_WEB_LOG)"; \
		exit 1; \
	fi
	@echo "Local environment is ready:"
	@echo "  Web UI:  $(DEV_WEB_URL)"
	@echo "  Backend: $(DEV_API_URL)"
	@echo "  MinIO:   http://localhost:9000  (console http://localhost:9001, minioadmin / minioadmin)"
	@echo "  Scanner: $(DEV_SCANNER_URL) (optional: make dev-scanner)"
	@echo "Mock auth users:"
	@echo "  local-user  -> X-Mock-User-Id: local-user"
	@echo "  local-admin -> X-Mock-User-Id: local-admin"
	@echo "Logs:"
	@echo "  Backend: $(DEV_SERVER_LOG)"
	@echo "  Frontend: $(DEV_WEB_LOG)"

dev-server: ## 启动后端开发服务器
	@$(MAKE) --no-print-directory dev-server-env
	cd server && bash -lc '$(DEV_SERVER_PREPARE) && exec $(DEV_SERVER_LAUNCH)'

dev-server-restart: ## 重启后端开发服务器
	@mkdir -p $(DEV_DIR)
	@$(MAKE) --no-print-directory dev-server-env
	@$(DEV_PROCESS) stop --pid-file $(DEV_SERVER_PID)
	@$(DEV_SERVER_BACKGROUND) >/dev/null
	@echo "Waiting for backend on $(DEV_API_URL) ..."
	@for i in $$(seq 1 30); do \
		if curl -sf $(DEV_API_URL)/actuator/health >/dev/null; then \
			echo "Backend ready."; \
			exit 0; \
		fi; \
		sleep 2; \
	done; \
	echo "Backend failed to become ready. Check $(DEV_SERVER_LOG)"; \
	exit 1

namespace-smoke: ## 运行命名空间工作流 smoke test
	./scripts/namespace-smoke-test.sh $(DEV_API_URL)

suite-smoke: ## 运行 Skill Suite 生命周期 smoke test
	./scripts/suite-smoke-test.sh $(DEV_API_URL)

suite-bundle-smoke: ## 运行带真实认证的 Suite Bundle 创建/更新 smoke test
	./scripts/suite-bundle-smoke-test.sh $(DEV_API_URL)

dev-down: ## 停止本地开发依赖服务（Postgres + Redis + MinIO）
	$(DEV_COMPOSE) down --remove-orphans

dev-all-down: ## 停止本地开发环境（依赖 + 后端 + 前端）
	@$(DEV_PROCESS) stop --pid-file $(DEV_SERVER_PID)
	@$(DEV_PROCESS) stop --pid-file $(DEV_WEB_PID)
	@$(MAKE) dev-down

dev-all-reset: ## 重置本地开发环境（清理 Postgres/Redis/MinIO 数据卷后重新启动）
	@$(DEV_PROCESS) stop --pid-file $(DEV_SERVER_PID)
	@$(DEV_PROCESS) stop --pid-file $(DEV_WEB_PID)
	$(DEV_COMPOSE) down -v --remove-orphans
	rm -rf $(DEV_DIR)
	@$(MAKE) dev-all

dev-status: ## 查看本地开发服务状态
	@echo "=== Dependency Services ==="
	@$(DEV_COMPOSE) ps
	@echo ""
	@echo "=== Backend ==="
	@if $(DEV_PROCESS) status --pid-file $(DEV_SERVER_PID) >/dev/null 2>&1; then \
		echo "  Running (PID $$(cat $(DEV_SERVER_PID)))"; \
	else \
		echo "  Not running"; \
	fi
	@echo "=== Frontend ==="
	@if $(DEV_PROCESS) status --pid-file $(DEV_WEB_PID) >/dev/null 2>&1; then \
		echo "  Running (PID $$(cat $(DEV_WEB_PID)))"; \
	else \
		echo "  Not running"; \
	fi

# --- trusted-header test stack: nginx injects the identity headers on every backend request -----

trusted-header-build: ## 构建标头认证测试镜像（当前源码 jar 叠加到已发布运行时镜像）
	cd server && ./mvnw -pl skillhub-app -am package -DskipTests -B -q
	cd server && docker build --pull=false \
		-f Dockerfile.overlay \
		--build-arg SERVER_BASE_IMAGE=$(TRUSTED_HEADER_SERVER_BASE_IMAGE) \
		-t $(TRUSTED_HEADER_SERVER_IMAGE) .

trusted-header-test: ## 启动标头认证测试栈（postgres/redis/后端/nginx 网关）并运行断言
	@$(MAKE) --no-print-directory trusted-header-build
	@TRUSTED_HEADER_SERVER_IMAGE=$(TRUSTED_HEADER_SERVER_IMAGE) \
	 TRUSTED_HEADER_TEST_USER=$(TRUSTED_HEADER_TEST_USER) \
	 TRUSTED_HEADER_TEST_EMAIL=$(TRUSTED_HEADER_TEST_EMAIL) \
	 TRUSTED_HEADER_TEST_SECRET=$(TRUSTED_HEADER_TEST_SECRET) \
	 $(TRUSTED_HEADER_COMPOSE) up -d --wait
	@echo ""
	@echo "Trusted-header test stack is up:"
	@echo "  Gateway (headers injected): $(TRUSTED_HEADER_GATEWAY_URL)"
	@echo "  Backend (direct, no headers): $(TRUSTED_HEADER_DIRECT_URL)"
	@echo "  Try: curl -s $(TRUSTED_HEADER_GATEWAY_URL)/api/v1/auth/me"
	@echo ""
	@TRUSTED_HEADER_TEST_USER=$(TRUSTED_HEADER_TEST_USER) \
	 TRUSTED_HEADER_TEST_EMAIL=$(TRUSTED_HEADER_TEST_EMAIL) \
	 TRUSTED_HEADER_TEST_SECRET=$(TRUSTED_HEADER_TEST_SECRET) \
	 ./scripts/trusted-header-smoke-test.sh $(TRUSTED_HEADER_GATEWAY_URL) $(TRUSTED_HEADER_DIRECT_URL)

trusted-header-smoke: ## 只运行标头认证断言（测试栈需已启动）
	@TRUSTED_HEADER_TEST_USER=$(TRUSTED_HEADER_TEST_USER) \
	 TRUSTED_HEADER_TEST_EMAIL=$(TRUSTED_HEADER_TEST_EMAIL) \
	 TRUSTED_HEADER_TEST_SECRET=$(TRUSTED_HEADER_TEST_SECRET) \
	 ./scripts/trusted-header-smoke-test.sh $(TRUSTED_HEADER_GATEWAY_URL) $(TRUSTED_HEADER_DIRECT_URL)

trusted-header-test-down: ## 停止标头认证测试栈
	$(TRUSTED_HEADER_COMPOSE) down --remove-orphans

trusted-header-test-reset: ## 停止标头认证测试栈并清空其数据卷
	$(TRUSTED_HEADER_COMPOSE) down -v --remove-orphans

dev-logs: ## 实时查看开发服务日志（backend/frontend，默认 backend）
	@SERVICE=$${SERVICE:-backend}; \
	if [ "$$SERVICE" = "backend" ]; then \
		tail -f $(DEV_SERVER_LOG); \
	elif [ "$$SERVICE" = "frontend" ]; then \
		tail -f $(DEV_WEB_LOG); \
	else \
		echo "Unknown service: $$SERVICE. Use SERVICE=backend or SERVICE=frontend"; \
		exit 1; \
	fi

build-backend: ## 构建后端
	cd server && ./mvnw clean package -DskipTests

test-backend: ## 运行后端单元测试
	cd server && JDK_JAVA_OPTIONS="$(BACKEND_TEST_JAVA_OPTIONS)" ./mvnw test

build-backend-app: ## 构建 skillhub-app 及其依赖模块
	cd server && ./mvnw -pl skillhub-app -am clean package -DskipTests

test-backend-app: ## 运行 skillhub-app 及其依赖模块测试
	cd server && JDK_JAVA_OPTIONS="$(BACKEND_TEST_JAVA_OPTIONS)" ./mvnw -pl skillhub-app -am test

build: build-backend build-frontend ## 完整构建前后端

build-builtin-skills: ## 校验并确定性打包官方内置 Skills
	python3 scripts/build-builtin-skills.py

test: test-backend test-frontend ## 运行前后端完整单元测试

test-builtin-skills: ## 验证内置 Skills 清单、打包结果和安全边界
	bash scripts/tests/build-builtin-skills-test.sh

check: build test ## 执行前后端完整构建和完整单元测试

clean: ## 清理构建产物
	cd server && ./mvnw clean
	$(DEV_COMPOSE) down -v
	rm -rf $(DEV_DIR)

generate-api: ## 生成 OpenAPI 类型（前端用）
	@echo "Generating OpenAPI types..."
	cd web && pnpm run generate-api

web-install: ## 安装前端依赖
	cd web && pnpm install

web-deps: ## 确保前端依赖可用（本地开发优先复用现有 node_modules）
	@if [ ! -d web/node_modules ]; then \
		echo "Installing frontend dependencies (node_modules missing)..."; \
		$(MAKE) web-install-ci; \
	elif [ ! -f web/node_modules/.modules.yaml ]; then \
		echo "Installing frontend dependencies (.modules.yaml missing)..."; \
		$(MAKE) web-install-ci; \
	elif [ web/pnpm-lock.yaml -nt web/node_modules/.modules.yaml ]; then \
		echo "Installing frontend dependencies (lockfile changed)..."; \
		$(MAKE) web-install-ci; \
	else \
		echo "Using existing frontend dependencies."; \
	fi

web-install-ci: ## 以 CI 方式安装前端依赖
	cd web && CI=true pnpm install --frozen-lockfile

dev-web: ## 启动前端开发服务器
	cd web && pnpm exec vite --host $(DEV_WEB_HOST)

build-frontend: web-deps ## 构建前端
	cd web && pnpm run build

test-frontend: web-deps ## 运行前端单元测试
	cd web && pnpm run test

test-e2e-frontend: web-deps ## 运行前端 E2E 测试（Playwright）
	cd web && pnpm run test:e2e

test-e2e-smoke-frontend: web-deps ## 运行前端 E2E smoke 测试（Playwright）
	cd web && pnpm run test:e2e:smoke

build-web: build-frontend ## 构建前端

test-web: test-frontend ## 运行前端测试

typecheck-web: ## 前端类型检查
	cd web && pnpm run typecheck

lint-web: ## 前端代码检查
	cd web && pnpm run lint

# CLI 相关目标

cli-install: ## 安装 CLI 依赖
	cd cli && bun install --frozen-lockfile

build-cli: ## 构建 CLI
	cd cli && bun run build

test-cli: ## 运行 CLI 单元测试
	cd cli && bun test

lint-cli: ## CLI 代码检查
	cd cli && bun run lint

typecheck-cli: ## CLI 类型检查
	cd cli && bun run typecheck

publish-cli: ## 发布 CLI（patch 版本）- 本地 build+test → 推 release 分支 → 开 PR，合并后手动 tag 触发 CI
	./scripts/publish-cli.sh patch

publish-cli-minor: ## 发布 CLI（minor 版本）- 本地 build+test → 推 release 分支 → 开 PR，合并后手动 tag 触发 CI
	./scripts/publish-cli.sh minor

publish-cli-major: ## 发布 CLI（major 版本）- 本地 build+test → 推 release 分支 → 开 PR，合并后手动 tag 触发 CI
	./scripts/publish-cli.sh major

db-reset: ## 重置数据库
	$(DEV_COMPOSE) down -v --remove-orphans
	$(DEV_COMPOSE) up -d --wait --remove-orphans postgres
	cd server && ./mvnw flyway:migrate -pl skillhub-app

validate-release-config: ## 校验发布环境变量文件（默认 .env.release）
	./scripts/validate-release-config.sh .env.release

staging: ## 构建并启动 staging 环境，运行 smoke test（混合模式：后端镜像 + 前端静态文件）
	@echo "=== [1/5] Building backend JAR and Docker image ==="
	cd server && ./mvnw package -DskipTests -B -q
	docker build -t $(STAGING_SERVER_IMAGE) -f server/Dockerfile.dev server
	@echo "=== [2/5] Building frontend static files ==="
	cd web && pnpm run build
	@echo "=== [3/5] Starting dependency services ==="
	$(STAGING_BASE_COMPOSE) up -d --wait
	@echo "=== [4/5] Starting staging services ==="
	$(STAGING_COMPOSE) up -d --wait server web
	@echo "=== [5/5] Running smoke tests ==="
	@if SMOKE_ADMIN_USERNAME=admin SMOKE_ADMIN_PASSWORD='Admin@staging2026' \
		bash scripts/smoke-test.sh $(STAGING_API_URL); then \
		echo ""; \
		echo "Staging passed. Environment is running:"; \
		echo "  Web UI:  $(STAGING_WEB_URL)"; \
		echo "  Backend: $(STAGING_API_URL)"; \
		echo ""; \
		echo "Run 'make staging-down' to stop."; \
		echo "Run 'make pr' to create a pull request."; \
	else \
		echo ""; \
		echo "Smoke tests FAILED. Printing logs..."; \
		$(STAGING_COMPOSE) logs server; \
		$(MAKE) staging-down; \
		exit 1; \
	fi

staging-down: ## 停止 staging 环境
	$(STAGING_COMPOSE) down --remove-orphans

staging-logs: ## 查看 staging 服务日志（SERVICE=server|web，默认 server）
	@SERVICE=$${SERVICE:-server}; \
	$(STAGING_COMPOSE) logs -f $$SERVICE

pr: ## 推送当前分支并创建 Pull Request（需要 gh CLI，仅限交互式终端）
	@if ! command -v gh >/dev/null 2>&1; then \
		echo "Error: gh CLI not found. Install from https://cli.github.com/"; \
		exit 1; \
	fi
	@if ! gh auth status >/dev/null 2>&1; then \
		echo "Error: gh CLI not authenticated. Run: gh auth login"; \
		exit 1; \
	fi
	@BRANCH=$$(git rev-parse --abbrev-ref HEAD); \
	if [ "$$BRANCH" = "main" ] || [ "$$BRANCH" = "master" ]; then \
		echo "Error: Cannot create PR from main/master branch."; \
		exit 1; \
	fi
	@if ! git diff --quiet || ! git diff --cached --quiet; then \
		echo "You have uncommitted changes:"; \
		git status --short; \
		echo ""; \
		printf "Commit all changes before creating PR? [y/N] "; \
		read -r answer; \
		if [ "$$answer" = "y" ] || [ "$$answer" = "Y" ]; then \
			git add -A; \
			git commit -m "chore: pre-PR commit"; \
		else \
			echo "Aborted. Commit or stash your changes first."; \
			exit 1; \
		fi; \
	fi
	@BRANCH=$$(git rev-parse --abbrev-ref HEAD); \
	echo "Pushing branch $$BRANCH to origin..."; \
	git push -u origin "$$BRANCH"
	@echo "Creating pull request..."
	@if gh pr view >/dev/null 2>&1; then \
		echo "A pull request already exists for this branch:"; \
		gh pr view --json url -q '.url'; \
		exit 0; \
	fi
	@gh pr create --fill --web || gh pr create --fill

parallel-init: ## 创建 Claude/Codex/integration 并行 worktree（TASK=<slug>）
	@if [ -z "$(TASK)" ]; then \
		echo "Usage: make parallel-init TASK=<task-slug> [PARALLEL_BASE_REF=origin/main] [PARALLEL_WORKTREE_ROOT=/path]"; \
		exit 1; \
	fi
	./scripts/parallel-init.sh "$(TASK)" "$(PARALLEL_BASE_REF)" "$(PARALLEL_WORKTREE_ROOT)"

parallel-sync: ## 在 integration worktree 合并 Claude/Codex 分支（自动识别当前 task）
	PARALLEL_WORKTREE_ROOT="$(PARALLEL_WORKTREE_ROOT)" ./scripts/parallel-sync.sh $(SOURCES)

parallel-up: ## 在 integration worktree 合并并启动联调环境（自动识别当前 task）
	PARALLEL_WORKTREE_ROOT="$(PARALLEL_WORKTREE_ROOT)" ./scripts/parallel-up.sh $(SOURCES)

parallel-down: ## 在 integration worktree 停止联调环境
	./scripts/parallel-down.sh

docs-dev: ## 启动文档开发服务器
	cd docs/skillhub && npm run dev

docs-build: ## 构建文档站点
	cd docs/skillhub && npm run build

docs-preview: ## 预览构建后的文档站点
	cd docs/skillhub && npm run preview

test-redis-cluster: ## 使用真实 Redis Cluster 验证 Spring Data、Session 和 Redisson Stream
	./scripts/redis-cluster-integration-test.sh

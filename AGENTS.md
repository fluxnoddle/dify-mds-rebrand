# AGENTS.md

> `CLAUDE.md` is a symlink to this file. Keep a single source of truth for both Claude Code and other AI coding agents.

## Project Overview

Dify is an open-source platform for developing LLM applications with an intuitive interface combining agentic AI workflows, RAG pipelines, agent capabilities, and model management.

The repo is a **pnpm workspace + Python monorepo** with three top-level deliverables:

- **Backend API** (`api/`): Python Flask app organized with Domain-Driven Design; managed by `uv`. Architecture is layered controller → service → core/domain, with Celery workers for async work and Redis as broker.
- **Frontend Web** (`web/`): Next.js 15 / React 19 / TypeScript app. Tests via Vitest + React Testing Library.
- **Shared packages** (`packages/`): workspace packages — most importantly `@langgenius/dify-ui` (overlay primitives and design tokens), `@dify/iconify-collections`, `@dify/tsconfig`.
- **End-to-end tests** (`e2e/`): Cucumber + Playwright suite — see `e2e/AGENTS.md`.
- **Deployment** (`docker/`): Docker Compose stacks for full deploy and middleware-only dev.

Runtime requirements: **Node 22.22.1** (`pnpm@10.33.2`, enforced by `package.json`), **Python via `uv`**. Use Corepack to pin pnpm.

## Where to read next

Most concrete rules live next to the code, not here:

- `api/AGENTS.md` — required reading before any backend edit (docstring rules, Pydantic v2, SQLAlchemy patterns, logging/error conventions, tenant scoping, async work via `services/async_workflow_service`).
- `web/AGENTS.md` — frontend rules; references `web/docs/test.md`, `web/docs/lint.md`, `web/docs/overlay-migration.md`.
- `packages/dify-ui/README.md` — permanent contract for overlay primitives, portals, and z-layering. Only import overlays from `@langgenius/dify-ui/*`; never from `@/app/components/base/*`.
- `e2e/AGENTS.md` — Cucumber/Playwright conventions.
- `dev/` — repo-local helper scripts (`./dev/setup`, `./dev/start-api`, `./dev/start-web`, `./dev/start-worker`, `./dev/start-docker-compose`, `./dev/basedpyright-check`, `./dev/pyrefly-check-local`).

## Setup (first time)

The repo root `Makefile` orchestrates dev env setup; the `dev/` scripts are an alternative entry point. Pick one and stick with it.

```bash
# Bring up middleware (Postgres, Redis, Weaviate) + install web/api deps + run migrations
make dev-setup

# Or, equivalently, via the dev scripts:
./dev/setup
./dev/start-docker-compose
```

JavaScript dependencies are managed at the **repo root workspace** (`package.json`, `pnpm-lock.yaml`, `pnpm-workspace.yaml`). Run `pnpm install` from the root — do not `cd web && pnpm install`.

## Running the stack locally

The Makefile **does not** start long-running services. Use `dev/` scripts (preferred) or invoke them yourself. Per `api/AGENTS.md`, agents must **never** start long-running services as part of a task (`uv run app.py`, `flask run`, `next dev`, etc.).

```bash
./dev/start-api      # Flask backend (runs migrations first)
./dev/start-web      # Next.js frontend on :3000
./dev/start-worker   # Celery worker
./dev/start-beat     # Celery beat (scheduled tasks, optional)
```

## Common commands

### Backend (`api/`)

Run via the Makefile from repo root (it wraps `uv run --project api ...`):

| Task | Command |
| --- | --- |
| Format | `make format` |
| Lint (ruff + import-linter + dotenv-linter, auto-fix) | `make lint` |
| Type check (basedpyright + pyrefly + mypy) | `make type-check` |
| Type check core only (faster) | `make type-check-core` |
| Run all unit tests (parallel) | `make test` |
| Run targeted tests | `make test TARGET_TESTS=./api/tests/unit_tests/path/...` |
| Ad-hoc CLI command | `uv run --project api <command>` |

Integration tests (`api/tests/integration_tests/`, `api/tests/test_containers_integration_tests/`) are **CI-only** — do not run them locally.

### Frontend (`web/`)

Frontend has its own `package.json`; run scripts via `pnpm -C web run <script>` from the root, or `pnpm <script>` from `web/`.

| Task | Command |
| --- | --- |
| Lint (ESLint, cached, multi-thread) | `pnpm lint` (root) or `pnpm lint:fix` |
| Type-aware lint (TSSLint) | `pnpm -C web run lint:tss` |
| Type check (`tsgo`, TS 7 native) | `pnpm -C web run type-check` |
| Unit tests (Vitest + happy-dom) | `pnpm -C web run test` |
| Test watch | `pnpm -C web run test:watch` |
| Single test file | `pnpm -C web run test path/to/file.spec.tsx` |
| Coverage | `pnpm -C web run test:coverage` |
| Dev server (do **not** launch from agent tasks) | `pnpm -C web run dev` |
| Component complexity analysis | `pnpm -C web run analyze-component <path>` |
| Storybook | `pnpm -C web run storybook` |

### Docker images

| Task | Command |
| --- | --- |
| Build web image | `make build-web` |
| Build api image | `make build-api` |
| Build all | `make build-all` |
| Build + push all | `make build-push-all` |

## Architecture at a glance

### Backend (`api/`) layout

The DDD/Clean Architecture split is enforced by `import-linter` (`make lint` runs `lint-imports`). Don't cross layers without going through the right boundary.

```
api/
├── controllers/        # HTTP layer (console, service_api, web, inner_api, mcp, trigger, files)
│                       # Parse Pydantic input → call services → return serialised response. No business logic.
├── services/           # Coordinate repositories, providers, and async tasks. Side effects live here.
├── core/               # Domain logic: agent, app, rag, workflow, tools, mcp, trigger, datasource,
│                       #   model_manager, provider_manager, indexing_runner, prompt, memory, etc.
├── models/             # SQLAlchemy models (inherit from models.base.TypeBase).
├── repositories/       # Reserved for very large tables / alternative storage strategies.
├── tasks/              # Celery tasks; enqueue via services/async_workflow_service.
├── extensions/         # Flask extensions (incl. ext_storage — use for all storage I/O).
├── libs/               # Cross-cutting helpers.
├── configs/            # Config; access via configs.dify_config (never read os.environ directly).
├── migrations/         # Alembic migrations.
└── tests/              # unit_tests/ (local), integration_tests/ + test_containers_integration_tests/ (CI only).
```

Tenant safety is a hard invariant: `tenant_id` must flow through every layer touching shared resources, and DB writes are scoped with `where Workflow.tenant_id == tenant_id` and protected via `FOR UPDATE` / row counts.

### Frontend (`web/`) layout

```
web/
├── app/                # Next.js App Router; pages + components live here.
├── service/            # Legacy API call sites — migrating to contract-first.
├── contract/           # oRPC contracts (consoleQuery / marketplaceQuery + TanStack Query helpers).
├── context/            # React contexts (e.g., ProviderContext, i18n).
├── hooks/              # Shared hooks.
├── models/             # TS models / domain types.
├── i18n/               # i18n resources — user-facing strings MUST go through `web/i18n/en-US/`.
├── __tests__/          # Cross-component integration specs.
├── __mocks__/          # Shared mock factories (used via vi.mock('module-name')).
└── docs/               # test.md, lint.md, overlay-migration.md — canonical specs.
```

Frontend specs live in a sibling `__tests__/` folder next to the source (`foo/index.tsx` → `foo/__tests__/index.spec.tsx`). See `web/docs/test.md` for the full contract.

### External clone note

If a parent directory contains another `dify/` checkout used purely as reference (e.g., research notes), do not edit upstream Dify from outside this tree — operate inside the actual project root and follow this `AGENTS.md`.

## Testing & quality practices

- Follow TDD: red → green → refactor.
- Backend tests use `pytest` with Arrange-Act-Assert structure.
- Frontend tests must comply with `web/docs/test.md` and the `frontend-testing` skill.
- Before opening a PR: `make lint && make type-check && make test` for backend; `pnpm lint`, `pnpm -C web run type-check`, `pnpm -C web run test` for frontend.
- Enforce strong typing; avoid `Any` / `any`. Prefer `TypedDict` over `dict[...]`/`Mapping[...]` for known-shape payloads.
- Self-documenting code; comments explain *why*, not *what*. Update nearby docstrings/comments when the code's invariants change — `api/AGENTS.md` treats them as part of the spec.

## Language style

- **Python**: type-annotated, ruff-formatted (`.ruff.toml`), 120-char lines, Pydantic v2 with `extra="forbid"` by default. Declare class member variables at the top of the class body (see `api/AGENTS.md` examples). Use `logging.getLogger(__name__)` — never `print`.
- **TypeScript**: strict config, ESLint (`pnpm lint:fix`) + TSSLint for type-aware rules, `tsgo` for type-check; no `any`.

## General practices

- Prefer editing existing files; add new documentation only when explicitly requested.
- Inject dependencies through constructors; preserve clean architecture boundaries.
- Raise domain-specific exceptions in services/core, translate to HTTP at controllers.
- Access storage via `extensions.ext_storage.storage` and outbound HTTP via `core.helper.ssrf_proxy`.
- Queue async work through `services/async_workflow_service`; implement Celery tasks under `tasks/` with explicit queue selection.
- Frontend user-facing strings must use `web/i18n/en-US/` — never hardcode.
- New overlays must come from `@langgenius/dify-ui/*`. The deprecated `@/app/components/base/*` overlay imports have an allowlist that should only shrink (see `web/docs/overlay-migration.md`).

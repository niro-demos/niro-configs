#!/usr/bin/env python3
"""Niro harness seed script for Dify.

Runs INSIDE the `api` container (cwd=/app/api, same interpreter/venv the
service itself uses), so it can import the application's own service layer
directly -- the same functions the `flask create-tenant` / `reset-password`
CLI commands and the console API use -- rather than re-implementing account
creation, password hashing, or tenant/RBAC bookkeeping.

It is idempotent: safe to re-run against an already-seeded database (existing
accounts are reused and their password reset to the value below; existing
apps/datasets are reused by name). `niro/harness/reset.sh` gets a fully clean
baseline instead by wiping the Postgres volume and re-running this script.

Output contract: prints exactly one JSON object to stdout (nothing else) on
success, describing every account/tenant/app/dataset/api-key created. The
host-side `seed.sh` pipes that JSON into `render_niro_files.py`, which
renders `niro/credentials.yaml` and `niro/fixtures.yaml` from it. Diagnostic
output goes to stderr so it never corrupts the stdout JSON contract.
"""

from __future__ import annotations

import base64
import json
import secrets
import sys

# cwd is /app/api inside the container (Dockerfile WORKDIR); app_factory,
# services, models etc. are importable exactly as the running api/worker
# processes import them.
from app_factory import create_app  # noqa: E402

SEED_PASSWORD = "Niro-Seed-Pw1"  # satisfies password_pattern (letters+digits, 8+)


def log(msg: str) -> None:
    print(f"[seed] {msg}", file=sys.stderr, flush=True)


def main() -> dict:
    _socketio, flask_app = create_app()
    with flask_app.app_context():
        from sqlalchemy import select

        from extensions.ext_database import db
        from libs.password import hash_password, valid_password
        from configs import dify_config
        from models.account import Account, AccountStatus, Tenant, TenantAccountRole
        from models.dataset import Dataset
        from models.enums import ApiTokenType
        from models.model import ApiToken, App, DifySetup
        from services.account_service import AccountService, RegisterService, TenantService
        from services.app_service import AppService, CreateAppParams
        from services.dataset_service import DatasetService

        session = db.session()

        def upsert_account(email: str, display_name: str) -> Account:
            """Create the account if missing; otherwise reuse it and pin its
            password to SEED_PASSWORD so credentials.yaml always matches the
            live database, whether this is a fresh seed or a re-run."""
            existing = AccountService.get_account_by_email_with_case_fallback(email, session=session)
            if existing:
                valid_password(SEED_PASSWORD)
                salt = secrets.token_bytes(16)
                b64_salt = base64.b64encode(salt).decode()
                b64_hash = base64.b64encode(hash_password(SEED_PASSWORD, salt)).decode()
                existing.password = b64_hash
                existing.password_salt = b64_salt
                existing.status = AccountStatus.ACTIVE
                session.commit()
                log(f"reused existing account {email}, password reset")
                return existing

            account = RegisterService.register(
                email=email,
                name=display_name,
                password=SEED_PASSWORD,
                language="en-US",
                status=None,  # register() defaults this to ACTIVE
                is_setup=True,  # bypass the "is registration allowed" system gate
                create_workspace_required=False,
                session=session,
            )
            log(f"created account {email}")
            return account

        def upsert_tenant(name: str) -> Tenant:
            existing = session.scalar(select(Tenant).where(Tenant.name == name).limit(1))
            if existing:
                log(f"reused existing tenant {name!r} ({existing.id})")
                return existing
            tenant = TenantService.create_tenant(name, is_setup=True, session=session)
            log(f"created tenant {name!r} ({tenant.id})")
            return tenant

        def ensure_member(tenant: Tenant, account: Account, role: str) -> None:
            # TenantService.create_tenant_member() rejects role="owner" whenever the
            # tenant already has ANY owner -- including re-assigning the same
            # account that already holds it -- so it isn't idempotent for owners.
            # Skip the call entirely when this account already has the target role.
            from models.account import TenantAccountJoin

            existing = session.scalar(
                select(TenantAccountJoin)
                .where(TenantAccountJoin.tenant_id == tenant.id, TenantAccountJoin.account_id == account.id)
                .limit(1)
            )
            if existing and existing.role == role:
                return
            TenantService.create_tenant_member(tenant, account, session, role=role)

        def ensure_app(tenant: Tenant, owner: Account, name: str, mode: str, description: str) -> App:
            tenant_id = str(tenant.id)
            existing = session.scalar(select(App).where(App.tenant_id == tenant_id, App.name == name).limit(1))
            if existing:
                log(f"reused existing app {name!r} ({existing.id})")
                return existing
            owner.set_current_tenant_with_session(tenant, session=session)
            app = AppService().create_app(
                tenant_id,
                CreateAppParams(name=name, description=description, mode=mode),
                owner,
                session=session,
            )
            log(f"created app {name!r} mode={mode} ({app.id})")
            return app

        def ensure_app_api_key(app: App, tenant_id: str) -> str:
            existing = session.scalar(
                select(ApiToken).where(ApiToken.type == ApiTokenType.APP, ApiToken.app_id == app.id).limit(1)
            )
            if existing:
                log(f"reused existing app api key for {app.name!r}")
                return existing.token
            token_value = ApiToken.generate_api_key("app-", 24, session=session)
            token = ApiToken()
            token.app_id = app.id
            token.tenant_id = tenant_id
            token.token = token_value
            token.type = ApiTokenType.APP
            session.add(token)
            session.commit()
            log(f"created app api key for {app.name!r}")
            return token_value

        def ensure_dataset(tenant: Tenant, owner: Account, name: str, description: str) -> Dataset:
            tenant_id = str(tenant.id)
            existing = session.scalar(
                select(Dataset).where(Dataset.tenant_id == tenant_id, Dataset.name == name).limit(1)
            )
            if existing:
                log(f"reused existing dataset {name!r} ({existing.id})")
                return existing
            owner.set_current_tenant_with_session(tenant, session=session)
            dataset = DatasetService.create_empty_dataset(
                tenant_id=tenant_id,
                name=name,
                description=description,
                indexing_technique=None,
                account=owner,
                permission="only_me",
                session=session,
            )
            session.commit()
            log(f"created dataset {name!r} ({dataset.id})")
            return dataset

        def ensure_dataset_api_key(dataset: Dataset, tenant_id: str) -> str:
            # NOTE: dataset API keys are tenant-scoped, not dataset-scoped, despite
            # the console's per-dataset key list UI: controllers/service_api/wraps.py
            # authenticates a DATASET-type ApiToken by (type, tenant_id) alone and
            # then looks the requested dataset up by (dataset_id from the URL,
            # tenant_id) -- it never compares against a per-key dataset id. The
            # ApiToken model also has no mapped `dataset_id` column (models/model.py
            # ApiToken is annotated "bug: this uses setattr so idk the field" --
            # the console's create-key endpoint setattrs a `dataset_id` that the ORM
            # silently drops), so there is nothing to persist here that the app
            # itself would honor. This key will authenticate against ANY dataset in
            # this tenant, which is the real (if surprising) production behavior.
            existing = session.scalar(
                select(ApiToken).where(ApiToken.type == ApiTokenType.DATASET, ApiToken.tenant_id == tenant_id).limit(1)
            )
            if existing:
                log(f"reused existing dataset api key for tenant {tenant_id}")
                return existing.token
            token_value = ApiToken.generate_api_key("ds-", 24, session=session)
            token = ApiToken()
            token.tenant_id = tenant_id
            token.token = token_value
            token.type = ApiTokenType.DATASET
            session.add(token)
            session.commit()
            log(f"created dataset api key for {dataset.name!r} (tenant-scoped)")
            return token_value

        # ------------------------------------------------------------------
        # The console gates EVERY login/API route behind `setup_required`,
        # which checks for a `dify_setups` marker row -- normally written by
        # the one-time POST /console/api/setup bootstrap flow. Seeding
        # accounts directly through the service layer (below) never touches
        # that endpoint, so without this the whole console API 401s with
        # "not_setup" regardless of how many valid accounts exist.
        # ------------------------------------------------------------------
        if session.scalar(select(DifySetup).limit(1)) is None:
            session.add(DifySetup(version=dify_config.project.version))
            session.commit()
            log("created dify_setups marker row (unblocks setup_required)")

        # ------------------------------------------------------------------
        # Tenant A ("Niro Org A"): full role matrix for vertical-escalation
        # testing (owner > admin > editor > normal > dataset_operator), plus
        # an app + dataset it owns.
        # ------------------------------------------------------------------
        tenant_a = upsert_tenant("Niro Org A")

        owner_a = upsert_account("owner-a@niro-dify.test", "Owner A")
        ensure_member(tenant_a, owner_a, TenantAccountRole.OWNER)

        admin_a = upsert_account("admin-a@niro-dify.test", "Admin A")
        ensure_member(tenant_a, admin_a, TenantAccountRole.ADMIN)

        editor_a = upsert_account("editor-a@niro-dify.test", "Editor A")
        ensure_member(tenant_a, editor_a, TenantAccountRole.EDITOR)

        normal_a = upsert_account("normal-a@niro-dify.test", "Normal A")
        ensure_member(tenant_a, normal_a, TenantAccountRole.NORMAL)

        dsop_a = upsert_account("dsop-a@niro-dify.test", "DatasetOperator A")
        ensure_member(tenant_a, dsop_a, TenantAccountRole.DATASET_OPERATOR)

        app_a = ensure_app(tenant_a, owner_a, "Niro Chatbot A", "chat", "Seeded chatbot app owned by Org A.")
        app_a_key = ensure_app_api_key(app_a, str(tenant_a.id))

        dataset_a = ensure_dataset(tenant_a, owner_a, "Niro Dataset A", "Seeded empty dataset owned by Org A.")
        dataset_a_key = ensure_dataset_api_key(dataset_a, str(tenant_a.id))

        # ------------------------------------------------------------------
        # Tenant B ("Niro Org B"): a second, fully independent tenant that
        # owns its own app, for cross-tenant (horizontal) isolation testing
        # against Tenant A's owner/normal accounts.
        # ------------------------------------------------------------------
        tenant_b = upsert_tenant("Niro Org B")

        owner_b = upsert_account("owner-b@niro-dify.test", "Owner B")
        ensure_member(tenant_b, owner_b, TenantAccountRole.OWNER)

        normal_b = upsert_account("normal-b@niro-dify.test", "Normal B")
        ensure_member(tenant_b, normal_b, TenantAccountRole.NORMAL)

        app_b = ensure_app(tenant_b, owner_b, "Niro Chatbot B", "chat", "Seeded chatbot app owned by Org B.")
        app_b_key = ensure_app_api_key(app_b, str(tenant_b.id))

        session.commit()

        result = {
            "seed_password": SEED_PASSWORD,
            "tenants": {
                "org_a": {"id": str(tenant_a.id), "name": tenant_a.name},
                "org_b": {"id": str(tenant_b.id), "name": tenant_b.name},
            },
            "accounts": {
                "owner_a": {"email": owner_a.email, "id": str(owner_a.id), "tenant": "org_a", "role": "owner"},
                "admin_a": {"email": admin_a.email, "id": str(admin_a.id), "tenant": "org_a", "role": "admin"},
                "editor_a": {"email": editor_a.email, "id": str(editor_a.id), "tenant": "org_a", "role": "editor"},
                "normal_a": {"email": normal_a.email, "id": str(normal_a.id), "tenant": "org_a", "role": "normal"},
                "dsop_a": {
                    "email": dsop_a.email,
                    "id": str(dsop_a.id),
                    "tenant": "org_a",
                    "role": "dataset_operator",
                },
                "owner_b": {"email": owner_b.email, "id": str(owner_b.id), "tenant": "org_b", "role": "owner"},
                "normal_b": {"email": normal_b.email, "id": str(normal_b.id), "tenant": "org_b", "role": "normal"},
            },
            "apps": {
                "app_a": {
                    "id": str(app_a.id),
                    "name": app_a.name,
                    "mode": "chat",
                    "tenant": "org_a",
                    "api_key": app_a_key,
                },
                "app_b": {
                    "id": str(app_b.id),
                    "name": app_b.name,
                    "mode": "chat",
                    "tenant": "org_b",
                    "api_key": app_b_key,
                },
            },
            "datasets": {
                "dataset_a": {
                    "id": str(dataset_a.id),
                    "name": dataset_a.name,
                    "tenant": "org_a",
                    "api_key": dataset_a_key,
                },
            },
        }
        return result


if __name__ == "__main__":
    # create_app() configures application logging with a StreamHandler bound
    # to sys.stdout (it logs e.g. outbound plugin-daemon HTTP calls at INFO),
    # which would otherwise interleave with -- and break -- the single JSON
    # object this script promises on stdout. Redirect stdout to stderr for
    # the duration of main() (before create_app() runs, so any handler it
    # builds binds to that redirected target), then print the real result
    # through the saved original stdout once everything else is done.
    real_stdout = sys.stdout
    sys.stdout = sys.stderr
    try:
        output = main()
    finally:
        sys.stdout = real_stdout
    print(json.dumps(output))

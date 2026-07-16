"""Niro pentest harness seed script.

Runs INSIDE the running `api` container (see seed.sh), using the API's own
Flask app context and service classes directly -- the same code paths the
HTTP console API uses -- so no HTTP round trip or web browser is needed to
provision test state.

Creates two isolated workspaces ("orgs"), each with an owner-role account
and a normal-role member account, plus one fixture app (workflow mode) and
one fixture dataset (economy/keyword indexing) per org. Both app creation
paths were chosen specifically because they need zero LLM/embedding
provider calls, since this harness has no real model-provider secret.

Idempotent: safe to re-run against an already-seeded database. Existing
accounts have their password reset to the value reported this run (so
credentials.yaml always matches what is actually in the database);
existing tenants/apps/datasets are reused rather than duplicated.

Prints exactly one JSON object to stdout, wrapped in marker lines, which
seed.sh extracts to build ../credentials.yaml and ../fixtures.yaml.
"""

from __future__ import annotations

import base64
import json
import secrets
import sys

MARKER_START = "===NIRO_SEED_JSON_START==="
MARKER_END = "===NIRO_SEED_JSON_END==="


def gen_password() -> str:
    # libs.password.password_pattern requires >=8 chars, letters + digits.
    return "Niro-" + secrets.token_hex(6) + "-Aa1"


def main() -> None:
    from app_factory import create_app

    _, app = create_app()
    with app.app_context():
        from configs import dify_config
        from extensions.ext_database import db
        from libs.password import hash_password
        from models.account import Account, Tenant, TenantAccountJoin, TenantAccountRole
        from models.dataset import Dataset
        from models.model import DifySetup
        from models.model import App
        from services.account_service import RegisterService, TenantService
        from services.app_service import AppService, CreateAppParams
        from services.dataset_service import DatasetService

        session = db.session

        # `setup_required` (controllers/console/wraps.py) gates almost every
        # console endpoint, including login, on a `DifySetup` row existing --
        # the marker the real /console/api/setup install flow writes. This
        # harness seeds tenants directly via TenantService instead of that
        # HTTP flow, so it must write the same marker itself or nothing
        # (including login) is reachable.
        if session.query(DifySetup).first() is None:
            session.add(DifySetup(version=dify_config.project.version))
            session.commit()

        def set_password(account: Account, password: str) -> None:
            salt = secrets.token_bytes(16)
            account.password = base64.b64encode(hash_password(password, salt)).decode()
            account.password_salt = base64.b64encode(salt).decode()
            session.add(account)
            session.commit()

        def ensure_account(email: str, name: str, password: str) -> Account:
            existing = session.query(Account).filter(Account.email == email).first()
            if existing:
                set_password(existing, password)
                return existing
            account = RegisterService.register(
                email=email,
                name=name,
                password=password,
                language="en-US",
                create_workspace_required=False,
                session=session,
            )
            return account

        def ensure_owner_tenant(owner: Account, tenant_name: str) -> Tenant:
            join = (
                session.query(TenantAccountJoin)
                .filter(
                    TenantAccountJoin.account_id == owner.id,
                    TenantAccountJoin.role == TenantAccountRole.OWNER.value,
                )
                .first()
            )
            if join:
                tenant = session.get(Tenant, join.tenant_id)
                assert tenant is not None
                return tenant
            # is_setup=True: this harness stands up brand-new instances with
            # no prior operator setup step, so the normal "someone must
            # complete /console/api/setup first" gate does not apply here.
            TenantService.create_owner_tenant_if_not_exist(owner, tenant_name, is_setup=True, session=session)
            session.refresh(owner)
            join = (
                session.query(TenantAccountJoin)
                .filter(
                    TenantAccountJoin.account_id == owner.id,
                    TenantAccountJoin.role == TenantAccountRole.OWNER.value,
                )
                .first()
            )
            assert join is not None
            tenant = session.get(Tenant, join.tenant_id)
            assert tenant is not None
            return tenant

        def ensure_member(tenant: Tenant, member: Account) -> None:
            TenantService.create_tenant_member(tenant, member, session, role=TenantAccountRole.NORMAL.value)
            member.set_current_tenant_with_session(tenant, session=session)
            session.commit()

        def ensure_app(tenant: Tenant, creator: Account, name: str) -> App:
            existing = session.query(App).filter(App.tenant_id == tenant.id, App.name == name).first()
            if existing:
                return existing
            params = CreateAppParams(name=name, mode="workflow", description="Niro pentest fixture app")
            fixture_app = AppService().create_app(str(tenant.id), params, creator, session=session)
            session.commit()
            return fixture_app

        def ensure_dataset(tenant: Tenant, creator: Account, name: str) -> Dataset:
            existing = session.query(Dataset).filter(Dataset.tenant_id == tenant.id, Dataset.name == name).first()
            if existing:
                return existing
            fixture_dataset = DatasetService.create_empty_dataset(
                tenant_id=str(tenant.id),
                name=name,
                description="Niro pentest fixture knowledge base",
                indexing_technique="economy",
                account=creator,
                session=session,
            )
            session.commit()
            return fixture_dataset

        orgs = []
        for org_key, org_label in (("a", "A"), ("b", "B")):
            owner_email = f"owner-org-{org_key}@niro-dify.test"
            member_email = f"member-org-{org_key}@niro-dify.test"
            owner_password = gen_password()
            member_password = gen_password()

            owner = ensure_account(owner_email, f"Org {org_label} Owner", owner_password)
            tenant = ensure_owner_tenant(owner, f"Niro Org {org_label}")

            member = ensure_account(member_email, f"Org {org_label} Member", member_password)
            ensure_member(tenant, member)

            app_name = f"niro-fixture-app-org-{org_key}"
            dataset_name = f"niro-fixture-kb-org-{org_key}"
            fixture_app = ensure_app(tenant, member, app_name)
            fixture_dataset = ensure_dataset(tenant, member, dataset_name)

            orgs.append(
                {
                    "org": org_label,
                    "tenant_id": str(tenant.id),
                    "tenant_name": tenant.name,
                    "owner_email": owner_email,
                    "owner_password": owner_password,
                    "member_email": member_email,
                    "member_password": member_password,
                    "app_id": str(fixture_app.id),
                    "app_name": fixture_app.name,
                    "dataset_id": str(fixture_dataset.id),
                    "dataset_name": fixture_dataset.name,
                }
            )

        print(MARKER_START)
        print(json.dumps({"orgs": orgs}))
        print(MARKER_END)
        sys.stdout.flush()


if __name__ == "__main__":
    main()

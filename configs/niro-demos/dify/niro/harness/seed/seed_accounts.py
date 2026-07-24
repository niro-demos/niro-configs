"""Idempotently create/reconcile Dify accounts, tenants, and roles for the
Niro harness.

Runs INSIDE the api container (it needs the Flask app + DB session). Must be
invoked with its own directory as /app/api (e.g. copied to
/app/api/niro_seed_accounts.py) -- a plain `python /some/other/dir/script.py`
puts that other directory at the front of sys.path instead of /app/api,
breaking the `from app_factory import ...` style imports below:

    docker compose cp seed_accounts.py api:/app/api/niro_seed_accounts.py
    docker compose exec -T api env NIRO_SPEC_PATH=/tmp/spec.json \
      python /app/api/niro_seed_accounts.py

Reads a JSON array from the file at $NIRO_SPEC_PATH (default
/tmp/niro-accounts-spec.json), one object per account:

    {
      "email": "owner-a@niro.test",
      "name": "Owner A",
      "password": "...",
      "role": "owner" | "admin" | "editor" | "normal" | "dataset_operator",
      "language": "en-US",
      "join_tenant_of": null | "<email of an existing tenant owner>",
      "tenant_name": "Org A"        # only used when join_tenant_of is null
    }

Every account's password is (re)set to the given value on every run so
credentials.yaml always matches the database, whether the account is being
created for the first time or already exists from a prior seed/reset.
"""

import base64
import json
import os
import secrets

from app_factory import create_app
from extensions.ext_database import db
from libs.password import hash_password, valid_password
from services.account_service import AccountService, RegisterService, TenantService


def set_password(account, password: str, session) -> None:
    valid_password(password)
    salt = secrets.token_bytes(16)
    b64_salt = base64.b64encode(salt).decode()
    hashed = hash_password(password, salt)
    b64_hashed = base64.b64encode(hashed).decode()
    account = session.merge(account)
    account.password = b64_hashed
    account.password_salt = b64_salt
    session.commit()
    AccountService.reset_login_error_rate_limit(account.email)


def main() -> None:
    spec_path = os.environ.get("NIRO_SPEC_PATH", "/tmp/niro-accounts-spec.json")
    with open(spec_path) as f:
        spec = json.load(f)
    _, app = create_app()
    with app.app_context():
        session = db.session()
        for entry in spec:
            email = entry["email"].strip().lower()
            name = entry["name"]
            password = entry["password"]
            role = entry.get("role", "owner")
            language = entry.get("language", "en-US")
            join_tenant_of = entry.get("join_tenant_of")
            tenant_name = entry.get("tenant_name")

            account = AccountService.get_account_by_email_with_case_fallback(email, session=session)
            if account is None:
                account = RegisterService.register(
                    email=email,
                    name=name,
                    password=password,
                    language=language,
                    create_workspace_required=False,
                    is_setup=True,
                    session=session,
                )
                session.commit()
                print(f"CREATED_ACCOUNT {email}")
            else:
                print(f"EXISTING_ACCOUNT {email}")

            set_password(account, password, session=session)

            if join_tenant_of:
                owner_account = AccountService.get_account_by_email_with_case_fallback(
                    join_tenant_of.strip().lower(), session=session
                )
                if not owner_account:
                    raise SystemExit(f"tenant owner not found: {join_tenant_of}")
                owner_tenants = TenantService.get_join_tenants(owner_account, session=session)
                if not owner_tenants:
                    raise SystemExit(f"tenant owner {join_tenant_of} has no tenant")
                tenant = owner_tenants[0]
                TenantService.create_tenant_member(tenant, account, session=session, role=role)
            else:
                own_tenants = TenantService.get_join_tenants(account, session=session)
                if own_tenants:
                    tenant = own_tenants[0]
                else:
                    TenantService.create_owner_tenant_if_not_exist(
                        account, tenant_name, is_setup=True, session=session
                    )
                    own_tenants = TenantService.get_join_tenants(account, session=session)
                    tenant = own_tenants[0]

            print(f"TENANT email={email} tenant_id={tenant.id} tenant_name={tenant.name} role={role}")

    print("SEED_ACCOUNTS_OK")


if __name__ == "__main__":
    main()

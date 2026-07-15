#!/usr/bin/env node
/*
 * Generator for ../credentials.yaml and ../fixtures.yaml.
 *
 * Both output files are gitignored; this generator is the committed
 * source of truth (see niro/credentials.yaml.example and
 * niro/fixtures.yaml.example for the format contract this must follow).
 *
 * Juice Shop's baseline is fully static and deterministic: every server
 * start runs `sequelize.sync({ force: true })` followed by
 * `data/datacreator.ts`, which recreates the same seed users, products,
 * challenges, etc. from data/static/*.yml every time (see server.ts
 * `start()`). So the values below are read straight from that seed data
 * (data/static/users.yml, config/default.yml) rather than queried from a
 * live DB — they are identical on every boot.
 */
'use strict'

const fs = require('fs')
const path = require('path')
const yaml = require('js-yaml')

const REPO_ROOT = path.resolve(__dirname, '..', '..')
const NIRO_DIR = path.join(REPO_ROOT, 'niro')

const users = yaml.load(fs.readFileSync(path.join(REPO_ROOT, 'data', 'static', 'users.yml'), 'utf8'))
const defaultConfig = yaml.load(fs.readFileSync(path.join(REPO_ROOT, 'config', 'default.yml'), 'utf8'))
const domain = defaultConfig.application.domain

function byKey (key) {
  const u = users.find((u) => u.key === key)
  if (!u) throw new Error(`seed user with key "${key}" not found in data/static/users.yml`)
  return u
}

function completeEmail (u) {
  return u.customDomain ? u.email : `${u.email}@${domain}`
}

// userId is the sequential id sqlite/sequelize assigns on a fresh
// `force: true` sync, which follows array order in users.yml (verified
// empirically: element 0 -> id 1, element 1 -> id 2, ...).
function userId (key) {
  return users.findIndex((u) => u.key === key) + 1
}

const jim = byKey('jim')
const bender = byKey('bender')
const admin = byKey('admin')
const ciso = byKey('ciso')
const accountant = byKey('accountant')
const chrisPike = byKey('chris') // soft-deleted seed user

const LOGIN_SHAPE = 'Login: POST /rest/user/login with JSON body {email, password} -> ' +
  '200 {authentication:{token,bid,umail}} on success. token is a JWT; send it as ' +
  '`Authorization: Bearer <token>` on subsequent requests.'

const credentials = {
  credentials: [
    {
      credential_id: 'CUSTOMER_JIM',
      description: `Standard customer (role=customer, user id ${userId('jim')}). Owns 2 addresses ` +
        '("Room 3F 121"/"Deck 5" and "Deneva Colony"), 1 payment card, and a wallet balance of 100. ' +
        'Posted a 4-star product review. ' + LOGIN_SHAPE + ' Pair with CUSTOMER_BENDER for ' +
        'horizontal-escalation tests: authenticate as Jim, then attempt to read or modify Bender’s ' +
        'basket, orders, addresses, or cards by guessing/incrementing numeric ids (e.g. GET /rest/user/whoami, ' +
        '/api/Addresses, /api/Cards, /rest/basket/:id) — expect 403/404, never another user’s data.',
      type: 'username_password',
      identifier: completeEmail(jim),
      secret: jim.password
    },
    {
      credential_id: 'CUSTOMER_BENDER',
      description: `Standard customer (role=customer, user id ${userId('bender')}). Owns a different ` +
        'address ("Robot Arms Apts 42"), a different payment card, and no wallet balance (0) — a ' +
        'deliberately different resource set from CUSTOMER_JIM so cross-user access attempts have ' +
        'something distinct to fail at. Posted a 1-star product review. Same login shape as CUSTOMER_JIM.',
      type: 'username_password',
      identifier: completeEmail(bender),
      secret: bender.password
    },
    {
      credential_id: 'GLOBAL_ADMIN',
      description: `Global admin (role=admin, user id ${userId('admin')}). This app has no org/tenant ` +
        'scoping — one admin covers every admin surface, so a single admin credential is sufficient. ' +
        LOGIN_SHAPE + ' CUSTOMER_JIM, CUSTOMER_BENDER, and ACCOUNTING_USER must NOT reach admin-only ' +
        'surfaces: the /#/administration frontend route, GET /rest/admin/application-configuration, ' +
        'GET /api/Users (lists every user, including password hashes and other users’ emails), and any ' +
        'other /rest/admin/* route. Owns 2 payment cards and a 5-star review.',
      type: 'username_password',
      identifier: completeEmail(admin),
      secret: admin.password
    },
    {
      credential_id: 'DELUXE_USER',
      description: `Deluxe-tier customer (role=deluxe, user id ${userId('ciso')}), seeded directly at ` +
        'this role rather than upgraded at runtime. Holds a deluxeToken (HMAC-SHA256 of email + ' +
        '"deluxe", see lib/insecurity.ts deluxeToken()) that the server re-derives and compares on ' +
        'deluxe-gated routes. ' + LOGIN_SHAPE + ' Use to confirm deluxe-only surfaces (premium/exclusive ' +
        'products, POST /rest/deluxe-membership upgrade flow at 49 currency units via wallet or card) ' +
        'reject CUSTOMER_JIM/CUSTOMER_BENDER, and that a plain customer cannot forge or replay a ' +
        'deluxeToken to reach the same surfaces without actually upgrading.',
      type: 'username_password',
      identifier: completeEmail(ciso),
      secret: ciso.password
    },
    {
      credential_id: 'ACCOUNTING_USER',
      description: `Accounting role (role=accounting, user id ${userId('accountant')}) — a narrow, ` +
        'non-admin elevated role, distinct from both "admin" and "deluxe". lib/insecurity.ts ' +
        'isAccounting() gates: GET /rest/order-history/orders (every user’s order history), PUT ' +
        '/rest/order-history/:id/delivery-status, and /api/Quantitys/:id (which ALSO carries an IP ' +
        'allow-list restricted to 123.456.789 — see the accounting_ip_allowlist fixture). This ' +
        'account’s seeded lastLoginIp (123.456.789) already matches that allow-list. ' + LOGIN_SHAPE +
        ' Use to test the accounting/admin boundary in both directions: ACCOUNTING_USER must reach its ' +
        'own gated routes but must still be rejected by GLOBAL_ADMIN-only surfaces (neither role subsumes ' +
        'the other), and CUSTOMER_JIM/CUSTOMER_BENDER must be rejected by accounting-gated routes.',
      type: 'username_password',
      identifier: completeEmail(accountant),
      secret: accountant.password
    }
  ]
}

const fixtures = {
  fixtures: [
    {
      name: 'base_url',
      description: 'Base URL of the running Juice Shop instance started by niro/harness/start.sh.',
      value: `http://127.0.0.1:${process.env.NIRO_JUICESHOP_PORT || 3000}`
    },
    {
      name: 'login_endpoint',
      description: 'Username/password login call shape shared by every username_password credential in credentials.yaml.',
      value: {
        method: 'POST',
        path: '/rest/user/login',
        body: { email: 'string', password: 'string' },
        success_response: { authentication: { token: 'jwt', bid: 'number (basket id)', umail: 'string' } }
      }
    },
    {
      name: 'application_domain',
      description: 'Email domain suffix baked into seeded non-custom-domain users at boot (config/default.yml application.domain). All credentials.yaml identifiers already include it.',
      value: domain
    },
    {
      name: 'seeded_user_ids',
      description: 'Deterministic numeric user ids (fresh force:true sync assigns ids in data/static/users.yml array order) for the accounts in credentials.yaml. Use for direct /api/Users/:id, /api/Addresses?UserId=, /api/Cards?UserId=, /rest/basket/:id style horizontal-escalation probes.',
      value: {
        CUSTOMER_JIM: userId('jim'),
        CUSTOMER_BENDER: userId('bender'),
        GLOBAL_ADMIN: userId('admin'),
        DELUXE_USER: userId('ciso'),
        ACCOUNTING_USER: userId('accountant')
      }
    },
    {
      name: 'admin_gated_routes',
      description: 'Representative /rest/admin/* and equivalent admin-only surfaces to probe for vertical-escalation from every non-admin credential.',
      value: [
        'GET /rest/admin/application-configuration',
        'GET /rest/admin/application-version',
        'GET /api/Users',
        'GET /#/administration (frontend route, client-side gated only)'
      ]
    },
    {
      name: 'accounting_ip_allowlist',
      description: 'server.ts gates /api/Quantitys/:id with security.isAccounting() AND an IpFilter allow-listing only source IP 123.456.789 (a non-routable placeholder). ACCOUNTING_USER’s seeded lastLoginIp matches it. This is a known intentional Juice Shop challenge surface (IP allow-list bypass via a spoofable header e.g. X-Forwarded-For) — a coverage/finding candidate, not a harness limitation.',
      value: {
        route: '/api/Quantitys/:id',
        required_ip: '123.456.789'
      }
    },
    {
      name: 'soft_deleted_user',
      description: 'chris.pike@' + domain + ' is seeded with deletedFlag (Sequelize paranoid soft-delete: deletedAt set, row retained). routes/login.ts’s login query explicitly filters `deletedAt IS NULL`, so this account must NOT be able to log in with password "uss enterprise" even though the row still exists — useful to confirm soft-delete is enforced everywhere reads happen, not just at login.',
      value: {
        email: completeEmail(chrisPike),
        password_if_not_deleted: chrisPike.password,
        expected_login_result: 'rejected (401/403) despite the row existing'
      }
    },
    {
      name: 'product_search_endpoint',
      description: 'Unauthenticated product catalog search, useful as a baseline non-admin GET surface and for injection testing (challenge-documented SQL injection surface).',
      value: '/rest/products/search?q='
    }
  ]
}

const HEADER = `# Generated by niro/harness/generate-manifests.cjs — DO NOT EDIT BY HAND.
# Regenerate with: node niro/harness/generate-manifests.cjs
# Source of truth: data/static/users.yml + config/default.yml (application.domain).
`

fs.writeFileSync(
  path.join(NIRO_DIR, 'credentials.yaml'),
  HEADER + yaml.dump(credentials, { lineWidth: 100, noRefs: true })
)
fs.writeFileSync(
  path.join(NIRO_DIR, 'fixtures.yaml'),
  HEADER + yaml.dump(fixtures, { lineWidth: 100, noRefs: true })
)

console.error('[juice-shop-harness] wrote niro/credentials.yaml and niro/fixtures.yaml')

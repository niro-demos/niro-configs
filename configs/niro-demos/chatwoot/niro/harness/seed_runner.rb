require 'yaml'
require 'fileutils'

NIRO_ROOT = Rails.root.join('niro')
PASSWORD = 'NiroPass1!.'.freeze

def confirmed_user!(email:, name:, super_admin: false)
  user = User.find_or_initialize_by(email: email)
  user.name = name
  user.password = PASSWORD
  user.type = super_admin ? 'SuperAdmin' : nil
  user.skip_confirmation!
  user.save!
  user.access_token || user.create_access_token
  user
end

def account!(name:, domain:)
  account = Account.find_or_initialize_by(domain: domain)
  account.name = name
  account.status = :active if account.respond_to?(:status=)
  account.save!
  account
end

def membership!(account:, user:, role:)
  account_user = AccountUser.find_or_initialize_by(account: account, user: user)
  account_user.role = role
  account_user.save!
  account_user
end

def web_inbox!(account:, name:, url:)
  channel = account.web_widgets.first_or_create!(website_url: url)
  channel.update!(website_url: url, hmac_mandatory: false, pre_chat_form_enabled: true)
  inbox = account.inboxes.find_or_initialize_by(channel: channel)
  inbox.name = name
  inbox.save!
  inbox
end

def contact_with_conversation!(account:, inbox:, assignee:, slug:)
  contact = account.contacts.find_or_initialize_by(email: "#{slug}@contacts.niro.local")
  contact.name = "Niro #{slug.tr('-', ' ').split.map(&:capitalize).join(' ')}"
  contact.identifier = "niro-#{slug}"
  contact.phone_number = "+1555#{format('%07d', slug.each_byte.sum)}"[0, 12]
  contact.save!

  contact_inbox = inbox.contact_inboxes.find_or_create_by!(contact: contact, source_id: "niro-#{slug}")
  conversation = contact_inbox.conversations.first_or_initialize(account: account, contact: contact, inbox: inbox)
  conversation.assignee = assignee
  conversation.status = :open
  conversation.priority = :medium
  conversation.save!

  if conversation.messages.none?
    conversation.messages.create!(
      account: account,
      inbox: inbox,
      sender: contact,
      message_type: :incoming,
      content: "Seeded Niro conversation owned by #{assignee.email}"
    )
    conversation.messages.create!(
      account: account,
      inbox: inbox,
      sender: assignee,
      message_type: :outgoing,
      content: 'Seeded agent reply for authorization and workflow testing.'
    )
  end

  conversation
end

def fixture_for_account(account:, inbox:, users:, conversations:)
  {
    'account' => {
      'id' => account.id,
      'name' => account.name,
      'domain' => account.domain
    },
    'inbox' => {
      'id' => inbox.id,
      'name' => inbox.name,
      'channel_type' => inbox.channel_type,
      'website_token' => inbox.channel.website_token,
      'widget_url' => "#{ENV.fetch('FRONTEND_URL')}/widget?website_token=#{inbox.channel.website_token}"
    },
    'users' => users.map do |user|
      account_user = AccountUser.find_by!(account: account, user: user)
      {
        'id' => user.id,
        'email' => user.email,
        'role' => account_user.role,
        'super_admin' => user.is_a?(SuperAdmin)
      }
    end,
    'conversations' => conversations.map do |conversation|
      {
        'id' => conversation.id,
        'display_id' => conversation.display_id,
        'uuid' => conversation.uuid,
        'assignee_email' => conversation.assignee.email,
        'contact_id' => conversation.contact_id,
        'contact_inbox_id' => conversation.contact_inbox_id
      }
    end
  }
end

GlobalConfig.clear_cache
ConfigLoader.new.process

alpha = account!(name: 'Niro Alpha Support', domain: 'niro-alpha.local')
beta = account!(name: 'Niro Beta Support', domain: 'niro-beta.local')

[alpha, beta].each do |account|
  account.conversations.destroy_all
  account.inboxes.destroy_all
  account.contacts.destroy_all
  account.teams.destroy_all
  account.labels.destroy_all
  account.canned_responses.destroy_all
end

admin_a = confirmed_user!(email: 'niro-admin-a@niro.local', name: 'Niro Admin A', super_admin: true)
admin_b = confirmed_user!(email: 'niro-admin-b@niro.local', name: 'Niro Admin B')
agent_a = confirmed_user!(email: 'niro-agent-a@niro.local', name: 'Niro Agent A')
agent_peer = confirmed_user!(email: 'niro-agent-peer@niro.local', name: 'Niro Agent Peer')
agent_b = confirmed_user!(email: 'niro-agent-b@niro.local', name: 'Niro Agent B')

membership!(account: alpha, user: admin_a, role: :administrator)
membership!(account: alpha, user: agent_a, role: :agent)
membership!(account: alpha, user: agent_peer, role: :agent)
membership!(account: beta, user: admin_b, role: :administrator)
membership!(account: beta, user: agent_b, role: :agent)

alpha_inbox = web_inbox!(account: alpha, name: 'Niro Alpha Web', url: 'https://alpha.niro.local')
beta_inbox = web_inbox!(account: beta, name: 'Niro Beta Web', url: 'https://beta.niro.local')
[admin_a, agent_a, agent_peer].each { |user| InboxMember.find_or_create_by!(inbox: alpha_inbox, user: user) }
[admin_b, agent_b].each { |user| InboxMember.find_or_create_by!(inbox: beta_inbox, user: user) }

alpha_team = alpha.teams.find_or_create_by!(name: 'Niro Alpha Escalations')
[agent_a, agent_peer].each { |user| TeamMember.find_or_create_by!(team: alpha_team, user: user) }
beta.teams.find_or_create_by!(name: 'Niro Beta Escalations')
alpha.labels.find_or_create_by!(title: 'niro-alpha', color: '#1f93ff')
beta.labels.find_or_create_by!(title: 'niro-beta', color: '#16a34a')
alpha.canned_responses.find_or_create_by!(short_code: 'niro_alpha') { |record| record.content = 'Niro alpha canned response.' }
beta.canned_responses.find_or_create_by!(short_code: 'niro_beta') { |record| record.content = 'Niro beta canned response.' }

alpha_conversations = [
  contact_with_conversation!(account: alpha, inbox: alpha_inbox, assignee: agent_a, slug: 'alpha-agent-a-owned'),
  contact_with_conversation!(account: alpha, inbox: alpha_inbox, assignee: agent_peer, slug: 'alpha-peer-owned')
]
beta_conversations = [
  contact_with_conversation!(account: beta, inbox: beta_inbox, assignee: agent_b, slug: 'beta-agent-owned')
]

credentials = {
  'credentials' => [
    {
      'credential_id' => 'NIRO_ADMIN_A',
      'description' => 'SuperAdmin user and administrator in Niro Alpha Support only. Login: POST /auth/sign_in with email and password. Use for super_admin and Alpha account-admin surfaces; should not own Beta account data.',
      'type' => 'username_password',
      'identifier' => admin_a.email,
      'secret' => PASSWORD
    },
    {
      'credential_id' => 'NIRO_ADMIN_B',
      'description' => 'Administrator in Niro Beta Support only, not a SuperAdmin. Login: POST /auth/sign_in with email and password. Pair with NIRO_ADMIN_A for cross-account admin isolation tests.',
      'type' => 'username_password',
      'identifier' => admin_b.email,
      'secret' => PASSWORD
    },
    {
      'credential_id' => 'NIRO_AGENT_A',
      'description' => 'Standard agent in Niro Alpha Support. Owns the alpha-agent-a-owned conversation and belongs to the Alpha web inbox and team. Login: POST /auth/sign_in with email and password.',
      'type' => 'username_password',
      'identifier' => agent_a.email,
      'secret' => PASSWORD
    },
    {
      'credential_id' => 'NIRO_AGENT_PEER',
      'description' => 'Standard peer agent in Niro Alpha Support. Owns a different Alpha conversation from NIRO_AGENT_A for same-account horizontal authorization checks.',
      'type' => 'username_password',
      'identifier' => agent_peer.email,
      'secret' => PASSWORD
    },
    {
      'credential_id' => 'NIRO_AGENT_B',
      'description' => 'Standard agent in Niro Beta Support. Owns Beta-only resources; pair with Alpha users for cross-account isolation checks.',
      'type' => 'username_password',
      'identifier' => agent_b.email,
      'secret' => PASSWORD
    }
  ]
}

fixtures = {
  'fixtures' => [
    {
      'name' => 'target',
      'description' => 'Checkout-local Chatwoot runtime owned by the Niro harness.',
      'value' => {
        'base_url' => ENV.fetch('FRONTEND_URL'),
        'health_url' => "#{ENV.fetch('FRONTEND_URL')}/health",
        'login_path' => '/auth/sign_in',
        'auth_headers_from_login' => ['access-token', 'client', 'uid']
      }
    },
    {
      'name' => 'niro_alpha_account',
      'description' => 'Primary tenant with two standard agents and distinct owned conversations.',
      'value' => fixture_for_account(account: alpha, inbox: alpha_inbox, users: [admin_a, agent_a, agent_peer],
                                     conversations: alpha_conversations)
    },
    {
      'name' => 'niro_beta_account',
      'description' => 'Secondary tenant for cross-account authorization tests.',
      'value' => fixture_for_account(account: beta, inbox: beta_inbox, users: [admin_b, agent_b], conversations: beta_conversations)
    }
  ]
}

FileUtils.mkdir_p(NIRO_ROOT)
File.write(NIRO_ROOT.join('credentials.yaml'), "#{credentials.to_yaml.sub(/^---\n/, '')}\n")
File.write(NIRO_ROOT.join('fixtures.yaml'), "#{fixtures.to_yaml.sub(/^---\n/, '')}\n")

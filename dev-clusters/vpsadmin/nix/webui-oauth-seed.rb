# Run only by vpsadmin-devcluster-webui-seed after runtime credentials are loaded.
origin = ENV.fetch('DEVCLUSTER_WEBUI_ORIGIN')
raise 'invalid React WebUI origin' unless origin.match?(%r{\Ahttps://[a-z0-9.-]+\z})

directory = ENV.fetch('CREDENTIALS_DIRECTORY')
client_id = File.read(File.join(directory, 'oauth-client-id')).strip
secret = File.read(File.join(directory, 'oauth-client-secret')).strip
raise 'invalid React WebUI credentials' unless client_id.match?(/\A[0-9a-f]{64}\z/) && secret.match?(/\A[0-9a-f]{64}\z/)

Oauth2Client.transaction do
  name = 'vpsAdmin React development WebUI'
  if Oauth2Client.where(name: name).where.not(client_id: client_id).exists?
    raise 'React WebUI client name belongs to a different client ID'
  end
  client = Oauth2Client.find_by(client_id: client_id)
  if client && (client.name != name || client.is_default?)
    raise 'React WebUI client ID belongs to a different OAuth client'
  end
  client ||= Oauth2Client.new(client_id: client_id)
  client.assign_attributes(
    name: name,
    redirect_uri: "#{origin}/oauth/callback",
    authorization_start_uri: "#{origin}/oauth/login",
    authorization_start_requires_user_action: false,
    allow_single_sign_on: true,
    access_token_lifetime: :fixed,
    access_token_seconds: 1200,
    issue_refresh_token: true,
    refresh_token_seconds: 2_592_000,
    is_default: false
  )
  client.set_secret(secret) unless client.persisted? && client.check_secret(secret)
  client.save!
end

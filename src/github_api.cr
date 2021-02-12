require "log"

require "halite"
require "memory_cache"
require "jwt"
require "tasker"

require "./cache_util"

alias InstallationId = Int64

abstract struct Token
  def to_s
    "token #{@token}"
  end
end

struct AppToken < Token
  def initialize(@token : String)
  end

  def to_s
    "Bearer #{@token}"
  end
end

struct UserToken < Token
  def initialize(@token : String)
  end
end

struct InstallationToken < Token
  include JSON::Serializable
  getter token : String
  property installation_id : InstallationId?

  def initialize(@token : String)
  end

  def to_s
    if (installation_id = @installation_id)
      Log.info { "Using token for ##{installation_id}" }
    end
    super
  end
end

struct OAuthToken < Token
  def initialize(@token : String)
  end
end

class GitHubAppAuth
  def initialize(@app_id : Int32, @pem_filename : String?)
  end

  def jwt : AppToken
    if !(pem_filename = @pem_filename)
      Log.error { "pem_filename not specified!" }
      return AppToken.new("")
    end
    @@jwt.fetch(@app_id, expires_in: 9.minutes) do
      AppToken.new(
        JWT.encode({
          iat: Time.utc.to_unix,                # issued at time
          exp: (Time.utc + 10.minutes).to_unix, # JWT expiration time (10 minute maximum)
          iss: @app_id,                         # GitHub App's identifier
        }, File.read(pem_filename), JWT::Algorithm::RS256)
      )
    end
  end

  private def new_token(installation_id : InstallationId) : InstallationToken
    Tasker.in(TOKEN_EXPIRATION * 0.98) do
      if (old_token = @@token.read(installation_id))
        old_token.installation_id = nil # Suppress logging.
        Log.info { "Token for ##{installation_id} had #{RateLimits.for_token(old_token)}" }
      end
    end
    # https://docs.github.com/en/rest/reference/apps#create-an-installation-access-token-for-an-app
    resp = GitHub.post(
      "/app/installations/#{installation_id}/access_tokens",
      json: {permissions: {actions: "read"}},
      headers: {Authorization: jwt}
    )
    resp.raise_for_status
    tok = InstallationToken.from_json(resp.body)
    tok.installation_id = installation_id
    tok
  end

  TOKEN_EXPIRATION = 55.minutes

  def token(installation_id : InstallationId, *, new : Bool = false) : InstallationToken
    if new
      @@token.write(installation_id, new_token(installation_id), expires_in: TOKEN_EXPIRATION)
    else
      @@token.fetch(installation_id, expires_in: TOKEN_EXPIRATION) do
        new_token(installation_id)
      end
    end
  end

  @@jwt = MemoryCache(Int32, AppToken).new
  @@token = CleanedMemoryCache(InstallationId, InstallationToken).new
end

GitHub = Halite::Client.new do
  endpoint("https://api.github.com/")
  logging(skip_request_body: true, skip_response_body: true)
end

macro get_json_list(t, url, params = NamedTuple.new, max_items = 1000, **kwargs)
  %url : String? = {{url}}
  %max_items : Int32 = {{max_items}}
  %params = {per_page: %max_items}.merge({{params}})
  %n = 0
  while %url
    %resp = GitHub.get(%url, params: %params, {{**kwargs}})
    %resp.raise_for_status
    %result = {{t}}.from_json(%resp.body).tap { |r| Log.debug { r.to_json } }
    %url = %resp.links.try(&.["next"]?).try(&.target)
    %params = {per_page: %max_items}
    %result {% if t.is_a?(Path) %}.{{t.id.underscore}}{% end %}.each do |x|
      yield x
      %n += 1
      break if %n >= %max_items
    end
    break if %n >= %max_items
  end
end

struct Installations
  include JSON::Serializable
  property installations : Array(Installation)

  def self.for_user(token : UserToken, & : Installation ->)
    # https://docs.github.com/v3/apps#list-app-installations-accessible-to-the-user-access-token
    get_json_list(
      Installations, "user/installations",
      headers: {Authorization: token}, max_items: 10
    )
  end

  def self.for_app(token : AppToken, since : Time? = nil, & : Installation ->)
    # https://docs.github.com/v3/apps#list-installations-for-the-authenticated-app
    params = {since: since && (since + 1.millisecond).to_rfc3339(fraction_digits: 3)}
    get_json_list(
      Array(Installation), "app/installations", params: params,
      headers: {Authorization: token}, max_items: 100000
    )
  end
end

module RFC3339Converter
  def self.from_json(json : JSON::PullParser) : Time
    Time.parse_rfc3339(json.read_string)
  end

  def self.to_json(value : Time, json : JSON::Builder) : Nil
    json.string(value.to_rfc3339)
  end
end

struct Installation
  include JSON::Serializable
  property id : InstallationId
  property account : Account
  @[JSON::Field(converter: RFC3339Converter)]
  property updated_at : Time

  def self.for_id(id : InstallationId, token : AppToken) : Installation
    # https://docs.github.com/v3/apps#get-an-installation-for-the-authenticated-app
    resp = GitHub.get("app/installations/#{id}", headers: {Authorization: token})
    resp.raise_for_status
    Installation.from_json(resp.body).tap { |r| Log.debug { r.to_json } }
  end
end

struct Account
  include JSON::Serializable
  property login : String

  def self.for_oauth(token : OAuthToken) : Account
    # https://docs.github.com/v3/users#get-the-authenticated-user
    resp = GitHub.get("user", headers: {Authorization: token})
    resp.raise_for_status
    Account.from_json(resp.body).tap { |r| Log.debug { r.to_json } }
  end
end

struct Repositories
  include JSON::Serializable
  property repositories : Array(Repository)

  cached_array def self.for_installation(installation_id : InstallationId, token : UserToken, & : Repository ->)
    # https://docs.github.com/v3/apps#list-repositories-accessible-to-the-user-access-token
    get_json_list(
      Repositories, "user/installations/#{installation_id}/repositories",
      headers: {Authorization: token}, max_items: 300
    )
  end

  cached_array def self.for_installation(token : InstallationToken, & : Repository ->)
    # https://docs.github.com/v3/apps#list-repositories-accessible-to-the-app-installation
    get_json_list(
      Repositories, "installation/repositories",
      headers: {Authorization: token}, max_items: 300
    )
  end
end

struct Repository
  include JSON::Serializable
  property full_name : String
  property? private : Bool = false
  property? fork : Bool = false

  def initialize(@full_name)
  end

  def owner : String
    full_name.partition('/').first
  end

  def name : String
    full_name.partition('/').last
  end
end

struct WorkflowRuns
  include JSON::Serializable
  property workflow_runs : Array(WorkflowRun)

  cached_array def self.for_workflow(repo_owner : DowncaseString, repo_name : DowncaseString, workflow : String, branch : String, event : String, token : InstallationToken | UserToken, max_items : Int32, & : WorkflowRun ->)
    # https://docs.github.com/v3/actions#list-workflow-runs
    get_json_list(
      WorkflowRuns, "repos/#{repo_owner}/#{repo_name}/actions/workflows/#{workflow}/runs",
      params: {branch: branch, event: event, status: "success"},
      headers: {Authorization: token}, max_items: max_items
    )
  end
end

struct WorkflowRun
  include JSON::Serializable
  property id : Int64
  property event : String
  property workflow_id : Int64
  property check_suite_url : String
  @[JSON::Field(converter: RFC3339Converter)]
  property updated_at : Time
  property repository : Repository
end

struct Artifacts
  include JSON::Serializable
  property artifacts : Array(Artifact)

  cached_array def self.for_run(repo_owner : DowncaseString, repo_name : DowncaseString, run_id : Int64, token : InstallationToken | UserToken, & : Artifact ->)
    # https://docs.github.com/v3/actions#list-workflow-run-artifacts
    get_json_list(
      Artifacts, "repos/#{repo_owner}/#{repo_name}/actions/runs/#{run_id}/artifacts",
      headers: {Authorization: token}, max_items: 100
    )
  end
end

class GitHubArtifactDownloadError < Halite::ServerError
end

struct Artifact
  include JSON::Serializable
  property id : Int64
  property name : String
  property url : String

  def repository : Repository
    if url =~ %r(^https://[^/]+/repos/([^/]+/[^/]+)/)
      Repository.new($1)
    else
      raise ArgumentError.new(url)
    end
  end

  @@cache_zip_by_id = CleanedMemoryCache({String, String, Int64}, String).new

  def self.zip_by_id(repo_owner : String, repo_name : String, artifact_id : Int64, token : InstallationToken | UserToken) : String
    repo_owner = repo_owner.downcase
    repo_name = repo_name.downcase
    @@cache_zip_by_id.fetch({repo_owner, repo_name, artifact_id}, expires_in: 50.seconds) do
      # https://docs.github.com/en/rest/reference/actions#download-an-artifact
      resp = GitHub.get(
        "repos/#{repo_owner}/#{repo_name}/actions/artifacts/#{artifact_id}/zip",
        headers: {Authorization: token}
      )
      if resp.status_code == 410 || (resp.status_code == 500 && resp.body.includes?("Failed to generate URL to download artifact"))
        raise GitHubArtifactDownloadError.new(status_code: resp.status_code, uri: resp.uri)
      end
      resp.raise_for_status
      resp.headers["location"]
    end
  end
end

struct Logs
  @@cache_raw_by_id = CleanedMemoryCache({String, String, Int64}, String).new

  def self.raw_by_id(repo_owner : String, repo_name : String, job_id : Int64, token : InstallationToken | UserToken) : String
    repo_owner = repo_owner.downcase
    repo_name = repo_name.downcase
    @@cache_raw_by_id.fetch({repo_owner, repo_name, job_id}, expires_in: 50.seconds) do
      # https://docs.github.com/en/rest/reference/actions#download-job-logs-for-a-workflow-run
      resp = GitHub.get(
        "repos/#{repo_owner}/#{repo_name}/actions/jobs/#{job_id}/logs",
        headers: {Authorization: token}
      )
      if resp.status_code == 410
        raise GitHubArtifactDownloadError.new(status_code: resp.status_code, uri: resp.uri)
      end
      resp.raise_for_status
      resp.headers["location"]
    end
  end
end

struct RateLimits
  include JSON::Serializable

  property core : Rate

  def self.for_token(token : Token) : RateLimits
    resp = Halite.get("https://api.github.com/rate_limit", headers: {Authorization: token})
    resp.raise_for_status
    RateLimits.from_json(resp.body, root: "resources").tap { |r| Log.debug { r.to_json } }
  end
end

struct Rate
  include JSON::Serializable

  property limit : Int32
  property remaining : Int32
  @[JSON::Field(converter: Time::EpochConverter)]
  property reset : Time
end

require "http"
require "ecr"

require "cache"
require "halite"
require "athena"
require "jwt"
require "sqlite3"

require "./athena_util"
require "./string_util"

GITHUB_APP_NAME      = ENV["GITHUB_APP_NAME"]
GITHUB_APP_ID        = ENV["GITHUB_APP_ID"].to_i
GITHUB_CLIENT_ID     = ENV["GITHUB_CLIENT_ID"]
GITHUB_CLIENT_SECRET = ENV["GITHUB_CLIENT_SECRET"]
GITHUB_PEM_FILENAME  = ENV["GITHUB_PEM_FILENAME"]
APP_SECRET           = ENV["APP_SECRET"]
FALLBACK_INSTALL_ID  = ENV["FALLBACK_INSTALLATION_ID"].to_i64

alias InstallationId = Int64

struct AppToken
  def initialize(@token : String)
  end

  def to_s
    "Bearer #{@token}"
  end
end

struct UserToken
  def initialize(@token : String)
  end

  def to_s
    "token #{@token}"
  end
end

struct InstallationToken
  include JSON::Serializable
  getter token : String

  def initialize(@token : String)
  end

  def to_s
    "token #{@token}"
  end
end

class AppAuth
  def initialize(@app_id : Int32, @pem_filename : String)
  end

  def jwt : AppToken
    AppToken.new(@@jwt.fetch("#{@app_id}") do
      JWT.encode({
        iat: Time.utc.to_unix,                # issued at time
        exp: (Time.utc + 10.minutes).to_unix, # JWT expiration time (10 minute maximum)
        iss: @app_id,                         # GitHub App's identifier
      }, File.read(@pem_filename), JWT::Algorithm::RS256)
    end)
  end

  private def new_token(installation_id : InstallationId) : InstallationToken
    result = nil
    Client.post(
      "/app/installations/#{installation_id}/access_tokens",
      json: {permissions: {actions: "read"}},
      headers: {authorization: jwt}
    ) do |resp|
      resp.raise_for_status
      result = InstallationToken.from_json(resp.body_io)
    end
    result.not_nil!
  end

  def token(installation_id : InstallationId, *, new : Bool = false) : InstallationToken
    if new
      tok = new_token(installation_id)
      @@token.write("#{installation_id}", tok.token)
      tok
    else
      tok = @@token.fetch("#{installation_id}") do
        new_token(installation_id).token
      end
      InstallationToken.new(tok)
    end
  end

  @@jwt = Cache::MemoryStore(String, String).new(expires_in: 9.minutes, compress: false)
  @@token = Cache::MemoryStore(String, String).new(expires_in: 9.minutes, compress: false)
end

AppClient = AppAuth.new(
  app_id: GITHUB_APP_ID,
  pem_filename: GITHUB_PEM_FILENAME,
)

Client = Halite::Client.new do
  endpoint("https://api.github.com/")
  logging(skip_request_body: true, skip_response_body: true)
end

macro get_json_list(t, url, params = NamedTuple.new, max_items = 1000, **kwargs)
  %url : String? = {{url}}
  %max_items : Int32 = {{max_items}}
  %params = {per_page: %max_items}.merge({{params}})
  n = 0
  while %url
    %result = nil
    Client.get(%url, params: %params, {{**kwargs}}) do |resp|
      resp.raise_for_status
      %result = {{t}}.from_json(resp.body_io)
      %url = resp.links.try(&.["next"]?).try(&.target)
      %params = {per_page: %max_items}
    end
    %result.not_nil!{% if t.is_a?(Path) %}.{{t.id.underscore}}{% end %}.each do |x|
      yield x
      n += 1
      break if n >= %max_items
    end
    break if n >= %max_items
  end
end

struct Installations
  include JSON::Serializable
  property installations : Array(Installation)

  def self.for_user(token : UserToken, & : Installation ->)
    # https://docs.github.com/v3/apps#list-app-installations-accessible-to-the-user-access-token
    get_json_list(
      Installations, "user/installations",
      headers: {authorization: token}, max_items: 10
    )
  end

  def self.for_app(token : AppToken, since : Time? = nil, & : Installation ->)
    # https://docs.github.com/v3/apps#list-installations-for-the-authenticated-app

    params = {since: since && (since + 1.millisecond).to_rfc3339(fraction_digits: 3)}
    get_json_list(
      Array(Installation), "app/installations", params: params,
      headers: {authorization: token}, max_items: 100000
    )
  end
end

module RFC3339Converter
  def self.from_json(value : JSON::PullParser) : Time
    Time.parse_rfc3339(value.read_string)
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
    result = nil
    Client.get("app/installations/#{id}", headers: {authorization: token}) do |resp|
      resp.raise_for_status
      result = Installation.from_json(resp.body_io)
    end
    result.not_nil!
  end
end

struct Account
  include JSON::Serializable
  property login : String

  def self.for_oauth(token : OAuthToken) : Account
    # https://docs.github.com/v3/users#get-the-authenticated-user
    result = nil
    Client.get("user", headers: {authorization: token}) do |resp|
      resp.raise_for_status
      result = Account.from_json(resp.body_io)
    end
    result.not_nil!
  end
end

struct Repositories
  include JSON::Serializable
  property repositories : Array(Repository)

  def self.for_installation(installation_id : InstallationId, token : UserToken, & : Repository ->)
    # https://docs.github.com/v3/apps#list-repositories-accessible-to-the-user-access-token
    get_json_list(
      Repositories, "user/installations/#{installation_id}/repositories",
      headers: {authorization: token}, max_items: 300
    )
  end

  def self.for_installation(installation_id : InstallationId, token : InstallationToken? = nil, & : Repository ->)
    for_installation(token || AppClient.token(installation_id)) do |repo|
      yield repo
    end
  end

  def self.for_installation(token : InstallationToken, & : Repository ->)
    # https://docs.github.com/v3/apps#list-repositories-accessible-to-the-app-installation
    get_json_list(
      Repositories, "installation/repositories",
      headers: {authorization: token}, max_items: 300
    )
  end
end

struct Repository
  include JSON::Serializable
  property full_name : String
  property? private : Bool
  property? fork : Bool
end

struct Workflows
  include JSON::Serializable
  property workflows : Array(Workflow)

  def self.for_repo(repo_owner : String, repo_name : String, token : InstallationToken | UserToken, & : Workflow ->)
    get_json_list(
      Workflows, "/repos/#{repo_owner}/#{repo_name}/actions/workflows",
      headers: {authorization: token}, max_items: 100
    )
  end
end

struct Workflow
  include JSON::Serializable
  property id : Int64
  property name : String
  property path : String
end

struct WorkflowRuns
  include JSON::Serializable
  property workflow_runs : Array(WorkflowRun)

  def self.for_repo(repo_owner : String, repo_name : String, token : InstallationToken | UserToken, max_items : Int32, & : WorkflowRun ->)
    get_json_list(
      WorkflowRuns, "repos/#{repo_owner}/#{repo_name}/actions/runs",
      params: {event: "push", status: "success"},
      headers: {authorization: token}, max_items: max_items
    )
  end

  def self.for_workflow(repo_owner : String, repo_name : String, workflow : String, branch : String, token : InstallationToken | UserToken, max_items : Int32, & : WorkflowRun ->)
    get_json_list(
      WorkflowRuns, "repos/#{repo_owner}/#{repo_name}/actions/workflows/#{workflow}/runs",
      params: {branch: branch, event: "push", status: "success"},
      headers: {authorization: token}, max_items: max_items
    )
  end
end

struct WorkflowRun
  include JSON::Serializable
  property id : Int64
  property head_branch : String
  property workflow_id : Int64
  property check_suite_url : String
end

struct Artifacts
  include JSON::Serializable
  property artifacts : Array(Artifact)

  def self.for_run(repo_owner : String, repo_name : String, run_id : Int64, token : InstallationToken | UserToken, & : Artifact ->)
    get_json_list(
      Artifacts, "repos/#{repo_owner}/#{repo_name}/actions/runs/#{run_id}/artifacts",
      headers: {authorization: token}, max_items: 100
    )
  end
end

struct Artifact
  include JSON::Serializable
  property id : Int64
  property name : String

  def self.zip_by_id(repo_owner : String, repo_name : String, artifact_id : Int64, token : InstallationToken | UserToken) : String
    Client.get(
      "repos/#{repo_owner}/#{repo_name}/actions/artifacts/#{artifact_id}/zip",
      headers: {authorization: token}
    ).tap(&.raise_for_status).headers["location"]
  end
end

D = DB.open("sqlite3:./db.sqlite")
D.exec(%(
  CREATE TABLE IF NOT EXISTS installations (
    repo_owner TEXT NOT NULL, installation_id INTEGER NOT NULL, public_repos TEXT NOT NULL, private_repos TEXT NOT NULL,
    UNIQUE(repo_owner)
  )
))

record RepoInstallation,
  repo_owner : String,
  installation_id : InstallationId,
  public_repos : DelimitedString,
  private_repos : DelimitedString do
  def write : Nil
    D.exec(%(
      REPLACE INTO installations (repo_owner, installation_id, public_repos, private_repos) VALUES(?, ?, ?, ?)
    ), @repo_owner, @installation_id, @public_repos.to_s, @private_repos.to_s)
  end

  def self.read(*, repo_owner : String) : RepoInstallation?
    D.query(%(
      SELECT installation_id, public_repos, private_repos FROM installations WHERE repo_owner = ? LIMIT 1
    ), repo_owner) do |rs|
      rs.each do
        return new(
          repo_owner, rs.read(InstallationId),
          DelimitedString.new(rs.read(String)), DelimitedString.new(rs.read(String))
        )
      end
    end
  end

  def self.delete(repo_owner : String) : Nil
    D.exec(%(
      DELETE FROM installations WHERE repo_owner = ?
    ), repo_owner)
  end

  def self.refresh(installation : Installation, token = nil) : RepoInstallation
    public_repos = DelimitedString::Builder.new
    private_repos = DelimitedString::Builder.new
    Repositories.for_installation(installation.id, token: token) do |repo|
      if (repo_name = repo.full_name.lchop?("#{installation.account.login}/"))
        (repo.private? ? private_repos : public_repos) << repo_name
      end
    end
    inst = RepoInstallation.new(
      installation.account.login, installation.id,
      public_repos.build, private_repos.build
    )
    inst.write
    inst
  end

  def password(repo_name : String) : String
    hash = OpenSSL::Digest.new("SHA256")
    hash.update("#{installation_id}\n#{repo_owner}\n#{repo_name}\n#{APP_SECRET}")
    hash.final.hexstring[...40]
  end

  def verify(*, repo_name : String, h : String?) : String?
    result = nil
    unless public_repos.includes?(repo_name) ||
           h && private_repos.includes?(repo_name) && h == (result = password(repo_name))
      raise ART::Exceptions::NotFound.new("Not found: #{repo_owner}/#{repo_name}")
    end
    result
  end

  def self.token(repo_owner : String, repo_name : String, *, h : String?) : InstallationToken
    if (inst = RepoInstallation.read(repo_owner: repo_owner))
      h = inst.verify(repo_name: repo_name, h: h)
      AppClient.token(inst.installation_id)
    else
      AppClient.token(FALLBACK_INSTALL_ID)
    end
  end
end

struct OAuthToken
  def initialize(@token : String)
  end

  def to_s
    "token #{@token}"
  end
end

class DashboardController < ART::Controller
  RECONFIGURE_URL = "https://github.com/apps/#{GITHUB_APP_NAME}/installations/new"
  AUTH_URL        = "https://github.com/login/oauth/authorize?" + HTTP::Params.encode({
    client_id: GITHUB_CLIENT_ID, scope: "",
  })

  WORKFLOW_EXAMPLES = [
    "https://github.com/actions/upload-artifact/blob/main/.github/workflows/test.yml",
    "https://github.com/crystal-lang/crystal/blob/master/.github/workflows/win.yml",
    "https://github.com/quassel/quassel/blob/master/.github/workflows/main.yml",
  ]

  def workflow_pattern(repo : String? = nil) : Regex
    return %r(^https?://github.com/(#{repo})/(blob|tree|raw|blame|commits)/([^/]+)/\.github/workflows/([^/]+)\.ya?ml$) if repo
    return %r(^https?://github.com/([^/]+/[^/]+)/(blob|tree|raw|blame|commits)/([^/]+)/\.github/workflows/([^/]+)\.ya?ml$)
  end

  def workflow_placeholder(repo = "$user/$repo") : String
    "https://github.com/#{repo}/blob/$branch/.github/workflows/$workflow.yml"
  end

  @[ART::Get("/")]
  def index : ART::Response
    messages = Tuple.new
    toplevel = true
    url = h = nil
    ART::Response.new(headers: HTML_HEADERS) do |io|
      io << "<title>nightly.link</title>"
      ECR.embed("head.html", io)
      ECR.embed("README.html", io)
    end
  end

  @[ART::Post("/")]
  def index(request : HTTP::Request) : ART::Response
    if (body = request.body)
      data = HTTP::Params.parse(body.gets_to_end)
      url = data["url"]?
      h = data["h"]?
    end

    messages = [] of String
    if url.presence
      if url =~ workflow_pattern
        repo, branch, workflow = $1, $3, $4
        if branch =~ /^[0-9a-fA-F]{32,}$/
          messages.unshift("Make sure you're on a branch (such as 'master'), not a commit (which '#{$0}' seems to be).")
        else
          link = "/#{repo}/workflows/#{workflow}/#{branch}"
          link += "?h=#{h}" if h
          return ART::RedirectResponse.new(link)
        end
      end
      messages.unshift("Did not detect a link to a GitHub workflow file.")
    end

    toplevel = true
    ART::Response.new(headers: HTML_HEADERS) do |io|
      io << "<title>nightly.link</title>"
      ECR.embed("head.html", io)
      ECR.embed("README.html", io)
    end
  end

  @[ART::QueryParam("code")]
  @[ART::Get("/dashboard")]
  def do_auth(code : String? = nil) : ART::Response
    if !code
      return ART::RedirectResponse.new(AUTH_URL)
    end

    resp = Client.post("https://github.com/login/oauth/access_token", form: {
      "client_id"     => GITHUB_CLIENT_ID,
      "client_secret" => GITHUB_CLIENT_SECRET,
      "code"          => code,
    }).tap(&.raise_for_status)
    resp = HTTP::Params.parse(resp.body)
    begin
      token = UserToken.new(resp["access_token"])
    rescue e
      if resp["error"]? == "bad_verification_code"
        return ART::RedirectResponse.new("/dashboard")
      end
      raise e
    end

    installations = [] of RepoInstallation

    Installations.for_user(token: token) do |iinst|
      installations << RepoInstallation.refresh(iinst, token)
    end

    return ART::Response.new(headers: HTML_HEADERS) do |io|
      ECR.embed("head.html", io)
      ECR.embed("dashboard.html", io)
    end
  end

  @[ART::QueryParam("installation_id")]
  @[ART::Get("/setup")]
  def do_setup(installation_id : InstallationId) : ART::Response
    inst = Installation.for_id(installation_id, AppClient.jwt)
    RepoInstallation.refresh(inst)
    ART::RedirectResponse.new("/")
  end

  record Link, url : String, title : String

  @[ART::QueryParam("h")]
  @[ART::Get("/:repo_owner/:repo_name/workflows/:workflow/:branch")]
  def by_branch(repo_owner : String, repo_name : String, workflow : String, branch : String, h : String?) : ART::Response
    token = RepoInstallation.token(repo_owner, repo_name, h: h)
    workflow += ".yml" unless workflow.to_i? || workflow.ends_with?(".yml")
    links = [] of Link
    begin
      WorkflowRuns.for_workflow(repo_owner, repo_name, workflow, branch, token, max_items: 1) do |run|
        Artifacts.for_run(repo_owner, repo_name, run.id, token) do |art|
          links << Link.new("/#{repo_owner}/#{repo_name}/workflows/#{workflow.rchop(".yml")}/#{branch}/#{art.name}#{"?h=#{h}" if h}", art.name)
        end
      end
    rescue e : Halite::Exception::ClientError
      if e.status_code.in?(401, 404)
        raise ART::Exceptions::NotFound.new("")
      else
        raise e
      end
    end
    title = "Repository #{repo_owner}/#{repo_name} | Workflow #{workflow} | Branch #{branch}"
    return ART::Response.new(headers: HTML_HEADERS) do |io|
      ECR.embed("head.html", io)
      ECR.embed("artifact_list.html", io)
    end
  end
end

class ArtifactsController < ART::Controller
  record Link, url : String, title : String? = nil, ext : Bool = false

  struct Result
    property links = Array(Link).new
    property title : String = ""
  end

  @[ART::QueryParam("h")]
  @[ART::Get("/:repo_owner/:repo_name/workflows/:workflow/:branch/:artifact")]
  def by_branch(repo_owner : String, repo_name : String, workflow : String, branch : String, artifact : String, h : String?) : ArtifactsController::Result
    token = RepoInstallation.token(repo_owner, repo_name, h: h)
    workflow += ".yml" unless workflow.to_i? || workflow.ends_with?(".yml")
    begin
      WorkflowRuns.for_workflow(repo_owner, repo_name, workflow, branch, token, max_items: 1) do |run|
        result = by_run(repo_owner, repo_name, run.id, artifact, run.check_suite_url.rpartition("/").last.to_i64?, h)
        result.title = "Repository #{repo_owner}/#{repo_name} | Workflow #{workflow} | Branch #{branch} | Artifact #{artifact}"
        result.links << Link.new("/#{repo_owner}/#{repo_name}/workflows/#{workflow.rchop(".yml")}/#{branch}/#{artifact}#{"?h=#{h}" if h}")
        result.links << Link.new("https://github.com/#{repo_owner}/#{repo_name}/actions?" + HTTP::Params.encode({
          query: "event:push is:success workflow:#{workflow} branch:#{branch}",
        }), "GitHub: browse runs for workflow '#{workflow}' on branch '#{branch}'", ext: true)
        return result
      end
    rescue e : Halite::Exception::ClientError
      if e.status_code.in?(401, 404)
        raise ART::Exceptions::NotFound.new("")
      else
        raise e
      end
    end
    raise ART::Exceptions::NotFound.new("No artifacts found for workflow and branch")
  end

  @[ART::QueryParam("h")]
  @[ART::Get("/:repo_owner/:repo_name/actions/runs/:run_id/:artifact")]
  def by_run(repo_owner : String, repo_name : String, run_id : Int64, artifact : String, check_suite_id : Int64?, h : String?) : ArtifactsController::Result
    token = RepoInstallation.token(repo_owner, repo_name, h: h)
    Artifacts.for_run(repo_owner, repo_name, run_id, token) do |art|
      if art.name == artifact
        result = by_artifact(repo_owner, repo_name, art.id, check_suite_id, h)
        result.title = "Repository #{repo_owner}/#{repo_name} | Run ##{run_id} | Artifact #{artifact}"
        result.links << Link.new("/#{repo_owner}/#{repo_name}/actions/runs/#{run_id}/#{artifact}#{"?h=#{h}" if h}")
        result.links << Link.new(
          "https://github.com/#{repo_owner}/#{repo_name}/actions/runs/#{run_id}",
          "GitHub: view run ##{run_id}", ext: true
        )
        return result
      end
    end
    raise ART::Exceptions::NotFound.new("No artifacts found for run ##{run_id}")
  end

  @[ART::QueryParam("h")]
  @[ART::Get("/:repo_owner/:repo_name/actions/artifacts/:artifact_id")]
  def by_artifact(repo_owner : String, repo_name : String, artifact_id : Int64, check_suite_id : Int64?, h : String?) : ArtifactsController::Result
    token = RepoInstallation.token(repo_owner, repo_name, h: h)
    tmp_link = Artifact.zip_by_id(repo_owner, repo_name, artifact_id, token: token)
    result = Result.new
    result.title = "Repository #{repo_owner}/#{repo_name} | Artifact ##{artifact_id}"
    result.links << Link.new(tmp_link, "Ephemeral direct download link (expires in <1 minute)")
    result.links << Link.new("/#{repo_owner}/#{repo_name}/actions/artifacts/#{artifact_id}#{"?h=#{h}" if h}")
    result.links << Link.new(
      "https://github.com/#{repo_owner}/#{repo_name}/suites/#{check_suite_id}/artifacts/#{artifact_id}",
      "GitHub: direct download of artifact ##{artifact_id} (requires GitHub login)", ext: true
    ) if check_suite_id
    return result
  end

  view Result do
    title = result.title
    links = result.links.reverse!
    ART::Response.new(headers: HTML_HEADERS) do |io|
      ECR.embed("head.html", io)
      ECR.embed("artifact.html", io)
    end
  end
end

ART.run

require "http"
require "ecr"

require "cache"
require "halite"
require "athena"
require "jwt"
require "sqlite3"

require "./util"

GITHUB_APP_NAME      = ENV["GITHUB_APP_NAME"]
GITHUB_APP_ID        = ENV["GITHUB_APP_ID"]
GITHUB_CLIENT_ID     = ENV["GITHUB_CLIENT_ID"]
GITHUB_CLIENT_SECRET = ENV["GITHUB_CLIENT_SECRET"]
GITHUB_PEM_FILENAME  = ENV["GITHUB_PEM_FILENAME"]

class AppAuth < Halite::Client
  def initialize(@app_id : Int32, @pem_filename : String)
    super()
  end

  def jwt
    @@jwt.fetch(@app_id.to_s) do
      "Bearer " + JWT.encode({
        iat: Time.utc.to_unix,                # issued at time
        exp: (Time.utc + 10.minutes).to_unix, # JWT expiration time (10 minute maximum)
        iss: @app_id,                         # GitHub App's identifier
      }, File.read(@pem_filename), JWT::Algorithm::RS256)
    end
  end

  @@jwt = Cache::MemoryStore(String, String).new(expires_in: 9.minutes, compress: false)

  def request(*args, **kwargs)
    options.headers["Authorization"] = jwt
    super
  end
end

# GitHub = AppAuth.new(
#   app_id: GITHUB_APP_ID,
#   pem_filename: GITHUB_PEM_FILENAME,
# )

Client = Halite::Client.new do
  endpoint("https://api.github.com/")
  logging(skip_request_body: true)
end

macro get_json_list(t, url, params = NamedTuple.new, max_items = 1000, **kwargs)
  %url : String? = {{url}}
  %max_items : Int32 = {{max_items}}
  %params = {per_page: %max_items}.merge({{params}})
  n = 0
  while %url
    result = nil
    Client.get(%url, params: %params, {{**kwargs}}) do |resp|
      resp.raise_for_status
      result = {{t}}.from_json(resp.body_io)
      %url = resp.links.try(&.["next"]?).try(&.target)
      %params = nil
    end
    result.not_nil!.{{t.id.underscore}}.each do |x|
      yield x
      n += 1
    end
    break if n > %max_items
  end
end

struct Installations
  include JSON::Serializable
  property installations : Array(Installation)

  def self.for_user(*, token : String, & : Installation ->)
    # https://docs.github.com/en/free-pro-team@latest/rest/reference/apps#list-app-installations-accessible-to-the-user-access-token
    get_json_list(
      Installations, "user/installations",
      headers: {authorization: token}, max_items: 10
    )
  end
end

struct Installation
  include JSON::Serializable
  property id : Int64
  property account : Account
end

struct Account
  include JSON::Serializable
  property login : String
end

struct Repositories
  include JSON::Serializable
  property repositories : Array(Repository)

  def self.for_installation(installation_id : Int, *, token : String, & : Repository ->)
    # https://docs.github.com/en/free-pro-team@latest/rest/reference/apps#list-repositories-accessible-to-the-user-access-token
    get_json_list(
      Repositories, "user/installations/#{installation_id}/repositories",
      headers: {authorization: token}, max_items: 200
    )
  end
end

struct Repository
  include JSON::Serializable
  property full_name : String
end

struct WorkflowRuns
  include JSON::Serializable
  property workflow_runs : Array(WorkflowRun)

  def self.for_workflow(repo_owner : String, repo_name : String, workflow : String, branch : String, *, token : String, max_items : Int32, & : WorkflowRun ->)
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
  property check_suite_url : String
end

struct Artifacts
  include JSON::Serializable
  property artifacts : Array(Artifact)

  def self.for_run(repo_owner : String, repo_name : String, run_id : Int64, *, token : String, & : Artifact ->)
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

  def self.zip_by_id(repo_owner : String, repo_name : String, artifact_id : Int64, *, token : String) : String
    Client.get(
      "repos/#{repo_owner}/#{repo_name}/actions/artifacts/#{artifact_id}/zip",
      headers: {authorization: token}
    ).tap(&.raise_for_status).headers["location"]
  end
end

D = DB.open("sqlite3:./db.sqlite")
D.exec(%(
  CREATE TABLE IF NOT EXISTS repo_tokens (
    repo_owner TEXT NOT NULL, repo_name TEXT NOT NULL, user_token TEXT NOT NULL,
    UNIQUE(repo_owner, repo_name)
  )
))

module RepoTokens
  @@cache = Cache::MemoryStore(String, String).new(expires_in: 1.day, compress: false)

  def self.write(repo_owner : String, repo_name : String, user_token : String) : Nil
    D.exec(%(
      REPLACE INTO repo_tokens (repo_owner, repo_name, user_token) VALUES(?, ?, ?)
    ), repo_owner, repo_name, user_token)
    @@cache.write("#{repo_owner}/#{repo_name}", user_token)
  end

  def self.read(repo_owner : String, repo_name : String) : String?
    @@cache.fetch("#{repo_owner}/#{repo_name}") do
      D.query_one(%(
        SELECT user_token FROM repo_tokens WHERE repo_owner = ? AND repo_name = ? LIMIT 1
      ), repo_owner, repo_name, &.read(String))
    end
  end

  def self.delete(repo_owner : String, repo_name : String) : Nil
    D.exec(%(
      DELETE FROM repo_tokens WHERE repo_owner = ? AND repo_name = ?
    ), repo_owner, repo_name)
    @@cache.delete("#{repo_owner}/#{repo_name}")
  end
end

class AuthController < ART::Controller
  RECONFIGURE_URL = "https://github.com/apps/#{GITHUB_APP_NAME}/installations/new"

  @[ART::QueryParam("code")]
  @[ART::Get("/auth")]
  def do_auth(code : String? = nil) : ART::Response
    if !code
      return ART::RedirectResponse.new("https://github.com/login/oauth/authorize?client_id=#{GITHUB_CLIENT_ID}")
    end

    resp = Client.post("https://github.com/login/oauth/access_token", form: {
      "client_id"     => GITHUB_CLIENT_ID,
      "client_secret" => GITHUB_CLIENT_SECRET,
      "code"          => code,
    }).tap(&.raise_for_status)
    resp = HTTP::Params.parse(resp.body)
    begin
      token = "token " + resp["access_token"]
    rescue e
      if resp["error"]? == "bad_verification_code"
        return ART::RedirectResponse.new("/auth")
      end
      raise e
    end

    repos = [] of {String, String}

    Installations.for_user(token: token) do |inst|
      Repositories.for_installation(inst.id, token: token) do |repo|
        repo_owner, _, repo_name = repo.full_name.partition("/")
        RepoTokens.write(repo_owner, repo_name, token)
        repo = "#{repo_owner}/#{repo_name}"
        repos << {repo, "/#{repo}"}
      end
    end

    ART::Response.new(headers: HTML_HEADERS) do |io|
      ECR.embed("head.html", io)
      ECR.embed("dashboard.html", io)
    end
  end
end

class ArtifactsController < ART::Controller
  record Link, url : String, title : String? = nil, ext : Bool = false

  struct Result
    property links = Array(Link).new
    property title : String = ""
  end

  @[ART::Get("/:repo_owner/:repo_name/artifact/:artifact_id")]
  def by_artifact(repo_owner : String, repo_name : String, artifact_id : Int64, check_suite_id : Int64? = nil) : ArtifactsController::Result
    token = RepoTokens.read(repo_owner, repo_name)
    tmp_link = Artifact.zip_by_id(repo_owner, repo_name, artifact_id, token: token)
    result = Result.new
    result.title = "Repository #{repo_owner}/#{repo_name} | Artifact ##{artifact_id}"
    result.links << Link.new(tmp_link, "Ephemeral direct download link (expires in <1 minute)")
    result.links << Link.new("/#{repo_owner}/#{repo_name}/artifact/#{artifact_id}")
    result.links << Link.new(
      "https://github.com/#{repo_owner}/#{repo_name}/suites/#{check_suite_id}/artifacts/#{artifact_id}",
      "GitHub: direct download of artifact ##{artifact_id} (requires GitHub login)", ext: true
    ) if check_suite_id
    return result
  end

  @[ART::Get("/:repo_owner/:repo_name/run/:run_id/:artifact")]
  def by_run(repo_owner : String, repo_name : String, run_id : Int64, artifact : String, check_suite_id : Int64? = nil) : ArtifactsController::Result
    token = RepoTokens.read(repo_owner, repo_name)
    Artifacts.for_run(repo_owner, repo_name, run_id, token: token) do |art|
      if art.name == artifact
        result = by_artifact(repo_owner, repo_name, art.id, check_suite_id)
        result.title = "Repository #{repo_owner}/#{repo_name} | Run ##{run_id} | Artifact #{artifact}"
        result.links << Link.new("/#{repo_owner}/#{repo_name}/run/#{run_id}/#{artifact}")
        result.links << Link.new(
          "https://github.com/#{repo_owner}/#{repo_name}/actions/runs/#{run_id}",
          "GitHub: view run ##{run_id}", ext: true
        )
        return result
      end
    end
    raise ART::Exceptions::NotFound.new("No artifacts found for this run")
  end

  @[ART::Get("/:repo_owner/:repo_name/:workflow/:branch/:artifact")]
  def by_branch(repo_owner : String, repo_name : String, workflow : String, branch : String, artifact : String) : ArtifactsController::Result
    token = RepoTokens.read(repo_owner, repo_name)
    workflow += ".yml" unless workflow.to_i? || workflow.ends_with?(".yml")
    WorkflowRuns.for_workflow(repo_owner, repo_name, workflow, branch, token: token, max_items: 1) do |run|
      result = by_run(repo_owner, repo_name, run.id, artifact, run.check_suite_url.rpartition("/").last.to_i64?)
      result.title = "Repository #{repo_owner}/#{repo_name} | Workflow #{workflow} | Branch #{branch} | Artifact #{artifact}"
      result.links << Link.new("/#{repo_owner}/#{repo_name}/#{workflow.rchop(".yml")}/#{branch}/#{artifact}")
      result.links << Link.new("https://github.com/#{repo_owner}/#{repo_name}/actions?" + HTTP::Params.encode({
        query: "event:push is:success workflow:#{workflow} branch:#{branch}",
      }), "GitHub: browse runs for workflow '#{workflow}' on branch '#{branch}'", ext: true)
      return result
    end
    raise ART::Exceptions::NotFound.new("No artifacts found for workflow and branch")
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

class FormController < ART::Controller
  @[ART::Get("/")]
  def index : ART::Response
    ART::Response.new(headers: HTML_HEADERS) do |io|
      ECR.embed("head.html", io)
      ECR.embed("README.html", io)
    end
  end

  @[ART::Post("/")]
  def to_artifact_page(request : HTTP::Request) : ART::RedirectResponse
    data = HTTP::Params.parse(request.body.not_nil!.gets_to_end)
    ART::RedirectResponse.new(
      "/#{data["repo_owner"]}/#{data["repo_name"]}/#{data["workflow"]}/#{data["branch"]}/#{data["artifact"]}"
    )
  end
end

ART.run

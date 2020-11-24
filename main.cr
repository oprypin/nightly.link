require "http"
require "cache"
require "halite"
require "athena"
require "jwt"
require "sqlite3"

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
  endpoint "https://api.github.com/"
end

def get_json(t, *args, **kwargs)
  r = nil
  Client.get(*args, **kwargs) do |resp|
    resp.raise_for_status
    r = t.from_json(resp.body_io)
  end
  r.not_nil!
end

struct Installations
  include JSON::Serializable
  property installations : Array(Installation)

  def self.for_user(*, token : String, & : Installation ->)
    get_json(
      Installations,
      "user/installations",
      headers: {authorization: token}
    ).installations.each do |inst|
      yield inst
    end
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
    get_json(
      Repositories,
      "user/installations/#{installation_id}/repositories",
      headers: {authorization: token}
    ).repositories.each do |repo|
      yield repo
    end
  end
end

struct Repository
  include JSON::Serializable
  property full_name : String
end

struct WorkflowRuns
  include JSON::Serializable
  property workflow_runs : Array(WorkflowRun)

  def self.for_workflow(repo_owner : String, repo_name : String, workflow : String, branch : String, *, token : String, per_page : Int32, & : WorkflowRun ->)
    get_json(
      WorkflowRuns,
      "repos/#{repo_owner}/#{repo_name}/actions/workflows/#{workflow}/runs",
      params: {branch: branch, event: "push", status: "success", per_page: per_page},
      headers: {authorization: token}
    ).workflow_runs.each do |run|
      yield run
    end
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
    get_json(
      Artifacts,
      "repos/#{repo_owner}/#{repo_name}/actions/runs/#{run_id}/artifacts",
      headers: {authorization: token}
    ).artifacts.each do |run|
      yield run
    end
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
  @[ART::QueryParam("code")]
  @[ART::Get("/auth")]
  def do_auth(code : String? = nil) : ART::RedirectResponse?
    if !code
      return ART::RedirectResponse.new("https://github.com/login/oauth/authorize?client_id=#{GITHUB_CLIENT_ID}")
    end

    resp = Client.post("https://github.com/login/oauth/access_token", form: {
      "client_id"     => GITHUB_CLIENT_ID,
      "client_secret" => GITHUB_CLIENT_SECRET,
      "code"          => code,
    }).tap(&.raise_for_status).body
    token = "token " + HTTP::Params.parse(resp)["access_token"]

    Installations.for_user(token: token) do |inst|
      Repositories.for_installation(inst.id, token: token) do |repo|
        repo_owner, _, repo_name = repo.full_name.partition("/")
        RepoTokens.write(repo_owner, repo_name, token)
      end
    end
    nil
  end
end

class ArtifactsController < ART::Controller
  struct Result
    property links : Array(String)

    def initialize(@links)
    end
  end

  @[ART::Get("/:repo_owner/:repo_name/:workflow/:branch/:artifact")]
  def by_branch(repo_owner : String, repo_name : String, workflow : String, branch : String, artifact : String) : ArtifactsController::Result
    token = RepoTokens.read(repo_owner, repo_name)
    workflow += ".yml" unless workflow.to_i? || workflow.ends_with?(".yml")
    WorkflowRuns.for_workflow(repo_owner, repo_name, workflow, branch, token: token, per_page: 1) do |run|
      return Result.new([
        "/#{repo_owner}/#{repo_name}/#{workflow}/#{branch}/#{artifact}",
      ] + by_run(repo_owner, repo_name, run.id, artifact, run.check_suite_url.rpartition("/").last.to_i64?).links)
    end
    raise ART::Exceptions::NotFound.new("No artifacts found for workflow and branch")
  end

  @[ART::Get("/:repo_owner/:repo_name/:run_id/:artifact")]
  def by_run(repo_owner : String, repo_name : String, run_id : Int64, artifact : String, check_suite_id : Int64? = nil) : ArtifactsController::Result
    token = RepoTokens.read(repo_owner, repo_name)
    Artifacts.for_run(repo_owner, repo_name, run_id, token: token) do |art|
      if art.name == artifact
        return Result.new([
          "/#{repo_owner}/#{repo_name}/#{run_id}/#{artifact}",
        ] + by_artifact(repo_owner, repo_name, art.id, check_suite_id).links)
      end
    end
    raise ART::Exceptions::NotFound.new("No artifacts found for this run")
  end

  @[ART::Get("/:repo_owner/:repo_name/:artifact_id")]
  def by_artifact(repo_owner : String, repo_name : String, artifact_id : Int64, check_suite_id : Int64? = nil) : ArtifactsController::Result
    token = RepoTokens.read(repo_owner, repo_name)
    Result.new([
      "/#{repo_owner}/#{repo_name}/#{artifact_id}",
      Artifact.zip_by_id(repo_owner, repo_name, artifact_id, token: token),
    ])
  end

  @[ADI::Register]
  struct Listener
    include AED::EventListenerInterface

    def self.subscribed_events : AED::SubscribedEvents
      AED::SubscribedEvents{ART::Events::View => 100}
    end

    def call(event : ART::Events::View, dispatcher : AED::EventDispatcherInterface) : Nil
      if (result = event.action_result.as?(Result))
        links = result.links.join("\n") do |url|
          %(<li><a href="#{url}">#{url}</a></li>)
        end
        event.response = html_response(%(
          <p>You can access this artifact by one of the following links, in the order from least to most direct</p><ul>
            #{links}
          </ul>
        ))
      end
    end
  end
end

def html_response(html : String)
  ART::Response.new(html, headers: HTTP::Headers{"content-type" => MIME.from_extension(".html")})
end

class FormController < ART::Controller
  @[ART::Get("/")]
  def index : ART::Response
    html_response(%(
      <form method="POST"><ul>
        <li><label>Username: <input name="repo_owner" placeholder="crystal-lang" required></label>
        <li><label>Repository: <input name="repo_name" placeholder="crystal" required></label>
        <li><label>Workflow: <input name="workflow" placeholder="win.yml" required></label>
        <li><label>Branch: <input name="branch" placeholder="master" required></label>
        <li><label>Artifact: <input name="artifact" placeholder="crystal" required></label>
      </ul><input type="submit"></form>
    ))
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

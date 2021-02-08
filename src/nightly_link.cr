require "http"
require "ecr"
require "log"

require "halite"
require "retour/http"
require "sqlite3"
require "future"

require "./string_util"
require "./github_api"

GITHUB_APP_NAME      = ENV["GITHUB_APP_NAME"]
GITHUB_APP_ID        = ENV["GITHUB_APP_ID"].to_i
GITHUB_CLIENT_ID     = ENV["GITHUB_CLIENT_ID"]
GITHUB_CLIENT_SECRET = ENV["GITHUB_CLIENT_SECRET"]
GITHUB_PEM_FILENAME  = ENV["GITHUB_PEM_FILENAME"]?
APP_SECRET           = ENV["APP_SECRET"]
FALLBACK_INSTALL_ID  = ENV["FALLBACK_INSTALLATION_ID"].to_i64
PORT                 = ENV["PORT"]?.try(&.to_i)
URL                  = ENV["URL"]? || "https://nightly.link/"
DATABASE_FILE        = ENV["DATABASE_FILE"]? || "./db.sqlite"

Log.setup_from_env

def abs_url(path : String) : String
  Path.posix(URL).join(path).to_s
end

GitHubApp = GitHubAppAuth.new(
  app_id: GITHUB_APP_ID,
  pem_filename: GITHUB_PEM_FILENAME,
)

record RepoInstallation,
  repo_owner : String,
  installation_id : InstallationId,
  public_repos : DelimitedString,
  private_repos : DelimitedString do
  def self.init_db(db : DB::Database)
    db.exec(%(
      CREATE TABLE IF NOT EXISTS installations (
        repo_owner TEXT NOT NULL, installation_id INTEGER NOT NULL, public_repos TEXT NOT NULL, private_repos TEXT NOT NULL,
        UNIQUE(repo_owner)
      )
    ))
  end

  def write(db : DB::Database) : Nil
    db.exec(%(
      REPLACE INTO installations (repo_owner, installation_id, public_repos, private_repos) VALUES(?, ?, ?, ?)
    ), @repo_owner, @installation_id, @public_repos.to_s, @private_repos.to_s)
  end

  def self.read(db : DB::Database, *, repo_owner : String) : RepoInstallation?
    db.query(%(
      SELECT installation_id, public_repos, private_repos FROM installations WHERE repo_owner = ? COLLATE NOCASE LIMIT 1
    ), repo_owner) do |rs|
      rs.each do
        return new(
          repo_owner, rs.read(InstallationId),
          DelimitedString.new(rs.read(String)), DelimitedString.new(rs.read(String))
        )
      end
    end
  end

  def self.delete(db : DB::Database, *, repo_owner : String) : Nil
    db.exec(%(
      DELETE FROM installations WHERE repo_owner = ?
    ), repo_owner)
  end

  {% for tok in [true, false] %}
    def self.refresh(db : DB::Database, installation : Installation{% if tok %}, token : UserToken{% end %}) : RepoInstallation
      public_repos = DelimitedString::Builder.new
      private_repos = DelimitedString::Builder.new
      {% if tok %}
        args = {installation.id, token}
      {% else %}
        args = {GitHubApp.token(installation.id)}
      {% end %}
      Repositories.for_installation(*args) do |repo|
        if repo.owner == installation.account.login
          (repo.private? ? private_repos : public_repos) << repo.name
        end
      end
      inst = RepoInstallation.new(
        installation.account.login, installation.id,
        public_repos.build, private_repos.build
      )
      inst.write(db)
      inst
    end
  {% end %}

  def password(repo_name : String) : String
    hash = OpenSSL::Digest.new("SHA256")
    hash.update("#{installation_id}\n#{repo_owner}\n#{repo_name}\n#{APP_SECRET}")
    hash.final.hexstring[...40]
  end

  def verify(*, repo_name : String, h : String?) : String?
    result = nil
    unless public_repos.any? { |r| r.downcase == repo_name.downcase } ||
           h && private_repos.includes?(repo_name) && h == (result = password(repo_name))
      raise HTTPException.new(:NotFound,
        "Repository not found: <https://github.com/#{repo_owner}/#{repo_name}>\n" +
        "If this is your private repository, access it by authorizing from the home page."
      )
    end
    result
  end

  def self.verified_token(db : DB::Database, repo_owner : String, repo_name : String, *, h : String?) : {InstallationToken, String?}
    if (inst = RepoInstallation.read(db, repo_owner: repo_owner))
      h = inst.verify(repo_name: repo_name, h: h)
      {GitHubApp.token(inst.installation_id), h}
    else
      {GitHubApp.token(FALLBACK_INSTALL_ID), nil}
    end
  end
end

private def github_run_link(repo_owner : String, repo_name : String, run_id : Int64) : String
  "https://github.com/#{repo_owner}/#{repo_name}/actions/runs/#{run_id}#artifacts"
end

private def github_actions_link(repo_owner : String, repo_name : String, *, event : String, branch : String) : String
  "https://github.com/#{repo_owner}/#{repo_name}/actions?" + HTTP::Params.encode({
    query: "event:#{event} is:success branch:#{branch}",
  })
end

class NightlyLink
  include Retour::HTTPRouter

  def initialize(@db : DB::Database = DB.open("sqlite3:#{DATABASE_FILE}"))
    RepoInstallation.init_db(db)
  end

  RECONFIGURE_URL = "https://github.com/apps/#{GITHUB_APP_NAME}/installations/new"
  AUTH_URL        = "https://github.com/login/oauth/authorize?" + HTTP::Params.encode({
    client_id: GITHUB_CLIENT_ID, scope: "", redirect_uri: abs_url(NightlyLink.gen_dashboard),
  })

  WORKFLOW_EXAMPLES = {
    "https://github.com/oprypin/nightly.link/blob/master/.github/workflows/upload-test.yml" => {
      repo_owner: "oprypin", repo_name: "nightly.link", workflow: "upload-test", branch: "master", artifact: "some-artifact",
    },
    "https://github.com/crystal-lang/crystal/blob/master/.github/workflows/win.yml" => {
      repo_owner: "crystal-lang", repo_name: "crystal", workflow: "win", branch: "master", artifact: "crystal",
    },
    "https://github.com/quassel/quassel/blob/master/.github/workflows/main.yml" => {
      repo_owner: "quassel", repo_name: "quassel", workflow: "main", branch: "master", artifact: "Windows",
    },
  }.to_a

  def workflow_pattern(repo_owner : String, repo_name : String) : Regex
    %r(^https?://github.com/(#{repo_owner})/(#{repo_name})/(blob|tree|raw|blame|commits)/([^/]+)/\.github/workflows/([^/]+\.ya?ml)(#.*)?$)
  end

  def workflow_pattern : Regex
    %r(^https?://github.com/([^/]+)/([^/]+)/(blob|tree|raw|blame|commits)/([^/]+)/\.github/workflows/([^/]+\.ya?ml)(#.*)?$)
  end

  def workflow_placeholder(repo_owner = "$user", repo_name = "$repo") : String
    "https://github.com/#{repo_owner}/#{repo_name}/blob/$branch/.github/workflows/$workflow.yml"
  end

  @[Retour::Get("/")]
  def index(ctx)
    url = ctx.request.query_params["url"]?.presence
    h = ctx.request.query_params["h"]?.presence

    messages = [] of String
    if url
      if url =~ workflow_pattern
        repo_owner, repo_name, branch, workflow = $1, $2, $4, $5
        if branch =~ /^[0-9a-fA-F]{32,}$/
          messages.unshift("Make sure you're on a branch (such as 'master'), not a commit (which '#{$0}' seems to be).")
        else
          link = abs_url(NightlyLink.gen_dash_by_branch(repo_owner: repo_owner, repo_name: repo_name, workflow: workflow.rchop(".yml"), branch: branch))
          link += "?h=#{h}" if h
          raise HTTPException.redirect(link)
        end
      end
      messages.unshift("Did not detect a link to a GitHub workflow file.")
    end

    canonical = abs_url(NightlyLink.gen_index)
    example_workflow, example_args = WORKFLOW_EXAMPLES.sample
    example_art = example_args[:artifact]
    example_dest = abs_url(NightlyLink.gen_by_branch(**example_args))

    ctx.response.content_type = "text/html"
    ECR.embed("templates/head.html", ctx.response)
    ctx.response << "<title>nightly.link</title>"
    ECR.embed("README.html", ctx.response)
  end

  @[Retour::Get("/dashboard")]
  def dashboard(ctx)
    code = ctx.request.query_params["code"]?
    if !code
      raise HTTPException.redirect(AUTH_URL, headers: HTTP::Headers{
        "X-Robots-Tag" => "noindex",
      })
    end

    resp = GitHub.post("https://github.com/login/oauth/access_token", form: {
      "client_id"     => GITHUB_CLIENT_ID,
      "client_secret" => GITHUB_CLIENT_SECRET,
      "code"          => code,
    }).tap(&.raise_for_status)
    resp = HTTP::Params.parse(resp.body)
    begin
      token = UserToken.new(resp["access_token"])
    rescue e
      if resp["error"]? == "bad_verification_code"
        raise HTTPException.redirect("/dashboard")
      end
      raise e
    end

    ch = Channel(RepoInstallation).new
    futures = [] of Future::Compute(RepoInstallation)
    Installations.for_user(token: token) do |inst|
      futures << future { RepoInstallation.refresh(@db, inst, token) }
    end
    installations = futures.map(&.get)

    ctx.response.content_type = "text/html"
    ctx.response.headers["X-Robots-Tag"] = "noindex"

    canonical = abs_url(NightlyLink.gen_dashboard)
    ECR.embed("templates/head.html", ctx.response)
    ECR.embed("templates/dashboard.html", ctx.response)
  end

  @[Retour::Get("/setup")]
  def do_setup(ctx)
    installation_id = ctx.request.query_params["installation_id"].to_i64 rescue raise HTTPException.new(:BadRequest)
    spawn do
      inst = Installation.for_id(installation_id, GitHubApp.jwt)
      RepoInstallation.refresh(@db, inst)
    end
    raise HTTPException.redirect("/")
  end

  record Link, url : String, title : String

  @[Retour::Get("/{repo_owner}/{repo_name}/workflows/{workflow}/{branch}")]
  def dash_by_branch(ctx, repo_owner : String, repo_name : String, workflow : String, branch : String)
    h = ctx.request.query_params["h"]?
    token, h = RepoInstallation.verified_token(@db, repo_owner, repo_name, h: h)
    unless workflow.to_i64?(whitespace: false) || workflow.ends_with?(".yml") || workflow.ends_with?(".yaml")
      workflow += ".yml"
    end

    run = get_latest_run(repo_owner, repo_name, workflow, branch, token)
    repo_owner, repo_name = run.repository.owner, run.repository.name
    if run.updated_at < 90.days.ago
      message = "Warning: the latest successful run is older than 90 days, and its artifacts likely expired."
    end

    artifacts = begin
      Artifacts.for_run(repo_owner, repo_name, run.id, token, expires_in: 3.hours)
    rescue e : Halite::Exception::ClientError
      raise e unless e.status_code.in?(401, 404)
    end
    if !artifacts || artifacts.empty?
      gh_link = github_run_link(repo_owner, repo_name, run.id)
      raise HTTPException.new(:NotFound,
        "No artifacts found for workflow '#{workflow}' and branch '#{branch}'.\n" +
        "Check on GitHub: <#{gh_link}>"
      )
    end

    title = {"Repository #{repo_owner}/#{repo_name}", "Workflow #{workflow} | Branch #{branch}"}
    links = artifacts.map do |art|
      link = abs_url(NightlyLink.gen_by_branch(repo_owner: repo_owner, repo_name: repo_name, workflow: workflow.rchop(".yml"), branch: branch, artifact: art.name))
      link += "?h=#{h}" if h
      Link.new(link, art.name)
    end
    canonical = abs_url(NightlyLink.gen_dash_by_branch(repo_owner: repo_owner, repo_name: repo_name, workflow: workflow.rchop(".yml"), branch: branch))
    canonical += "?h=#{h}" if h

    ctx.response.content_type = "text/html"
    ECR.embed("templates/head.html", ctx.response)
    ECR.embed("templates/artifact_list.html", ctx.response)
  end

  private def get_latest_run(repo_owner : String, repo_name : String, workflow : String, branch : String, token : InstallationToken)
    futures = [{"push", 5.minutes}, {"schedule", 1.hour}].map do |(event, expires_in)|
      future do
        begin
          WorkflowRuns.for_workflow(repo_owner, repo_name, workflow, branch: branch, event: event, token: token, max_items: 1, expires_in: expires_in)
        rescue e : Halite::Exception::ClientError
          if e.status_code.in?(401, 404)
            gh_link = "https://github.com/#{repo_owner}/#{repo_name}/tree/#{branch}/.github/workflows"
            raise HTTPException.new(:NotFound,
              "Repository '#{repo_owner}/#{repo_name}' or workflow '#{workflow}' not found.\n" +
              "Check on GitHub: <#{gh_link}>"
            )
          end
          raise e
        end
      end
    end
    runs = futures.map(&.get.first?).compact
    if runs.empty?
      gh_link = github_actions_link(repo_owner, repo_name, event: "push", branch: branch)
      raise HTTPException.new(:NotFound,
        "No successful runs found for workflow '#{workflow}' and branch '#{branch}'.\n" +
        "Check on GitHub: <#{gh_link}>"
      )
    end
    runs.max_by &.updated_at
  end

  record ArtifactLink, url : String, title : String? = nil, ext : Bool = false, zip : String? = nil

  struct Result
    property links = Array(ArtifactLink).new
    property title : {String, String} = {"", ""}
  end

  @[Retour::Get("/{repo_owner}/{repo_name}/workflows/{workflow}/{branch}/{artifact}{zip:\\.zip}")]
  @[Retour::Get("/{repo_owner}/{repo_name}/workflows/{workflow}/{branch}/{artifact}")]
  def by_branch(ctx, repo_owner : String, repo_name : String, workflow : String, branch : String, artifact : String, h : String? = nil, zip : String? = nil)
    h = ctx.request.query_params["h"]? if ctx
    token, h = RepoInstallation.verified_token(@db, repo_owner, repo_name, h: h)
    unless workflow.to_i64?(whitespace: false) || workflow.ends_with?(".yml") || workflow.ends_with?(".yaml")
      workflow += ".yml"
    end
    run = get_latest_run(repo_owner, repo_name, workflow, branch, token)
    repo_owner, repo_name = run.repository.owner, run.repository.name

    result = by_run(nil, repo_owner, repo_name, run.id, artifact, run.check_suite_url.rpartition("/").last.to_i64?, h)
    result.title = {"Repository #{repo_owner}/#{repo_name}", "Workflow #{workflow} | Branch #{branch} | Artifact #{artifact}"}
    result.links << ArtifactLink.new(
      github_actions_link(repo_owner, repo_name, event: run.event, branch: branch),
      "Browse workflow runs on branch '#{branch}'", ext: true
    )
    link = abs_url(NightlyLink.gen_by_branch(repo_owner: repo_owner, repo_name: repo_name, workflow: workflow.rchop(".yml"), branch: branch, artifact: artifact))
    result.links << ArtifactLink.new("#{link}#{"?h=#{h}" if h}", result.title[1], zip: "#{link}.zip#{"?h=#{h}" if h}")

    return artifact_page(ctx, result, !!zip) if ctx
    return result
  end

  @[Retour::Get("/{repo_owner}/{repo_name}/actions/runs/{run_id:[0-9]+}/{artifact}{zip:\\.zip}")]
  @[Retour::Get("/{repo_owner}/{repo_name}/actions/runs/{run_id:[0-9]+}/{artifact}")]
  def by_run(ctx, repo_owner : String, repo_name : String, run_id : Int64 | String, artifact : String, check_suite_id : Int64? | String = nil, h : String? = nil, zip : String? = nil)
    run_id = run_id.to_i64 rescue raise HTTPException.new(:NotFound)
    check_suite_id = check_suite_id && check_suite_id.to_i64 rescue raise HTTPException.new(:NotFound)
    h = ctx.request.query_params["h"]? if ctx
    token, h = RepoInstallation.verified_token(@db, repo_owner, repo_name, h: h)

    gh_link = github_run_link(repo_owner, repo_name, run_id)
    artifacts = begin
      Artifacts.for_run(repo_owner, repo_name, run_id, token, expires_in: 3.hours)
    rescue e : Halite::Exception::ClientError
      if e.status_code.in?(401, 404)
        raise HTTPException.new(:NotFound,
          "No artifacts found for run ##{run_id}.\nCheck on GitHub: <#{gh_link}>"
        )
      end
      raise e
    end
    art = artifacts.find { |a| a.name == artifact } || artifacts.find { |a| a.name == "#{artifact}.zip" }
    raise HTTPException.new(:NotFound,
      "Artifact '#{artifact}' not found for run ##{run_id}.\nCheck on GitHub: <#{gh_link}>"
    ) if !art
    repo_owner, repo_name = art.repository.owner, art.repository.name

    result = by_artifact(nil, repo_owner, repo_name, art.id, check_suite_id, h)
    result.title = {"Repository #{repo_owner}/#{repo_name}", "Run ##{run_id} | Artifact #{artifact}"}
    result.links << ArtifactLink.new(
      github_run_link(repo_owner, repo_name, run_id), "View run ##{run_id}", ext: true
    )
    link = abs_url(NightlyLink.gen_by_run(repo_owner: repo_owner, repo_name: repo_name, run_id: run_id, artifact: artifact))
    result.links << ArtifactLink.new("#{link}#{"?h=#{h}" if h}", result.title[1], zip: "#{link}.zip#{"?h=#{h}" if h}")
    return artifact_page(ctx, result, !!zip) if ctx
    return result
  end

  @[Retour::Get("/{repo_owner}/{repo_name}/suites/{check_suite_id:[0-9]+}/artifacts/{artifact_id:[0-9]+}{zip:}")]
  @[Retour::Get("/{repo_owner}/{repo_name}/actions/artifacts/{artifact_id:[0-9]+}{zip:\\.zip}")]
  @[Retour::Get("/{repo_owner}/{repo_name}/actions/artifacts/{artifact_id:[0-9]+}")]
  def by_artifact(ctx, repo_owner : String, repo_name : String, artifact_id : String | Int64, check_suite_id : String | Int64? = nil, h : String? = nil, zip : String? = nil)
    artifact_id = artifact_id.to_i64 rescue raise HTTPException.new(:NotFound)
    if check_suite_id
      check_suite_id = check_suite_id.to_i64 rescue raise HTTPException.new(:NotFound)
    end
    h = ctx.request.query_params["h"]? if ctx
    token, h = RepoInstallation.verified_token(@db, repo_owner, repo_name, h: h)

    artifact_gh_link = "https://github.com/#{repo_owner}/#{repo_name}/suites/#{check_suite_id}/artifacts/#{artifact_id}" if check_suite_id
    gh_link = artifact_gh_link || "https://api.github.com/repos/#{repo_owner}/#{repo_name}/actions/artifacts/#{artifact_id}"
    tmp_link = begin
      Artifact.zip_by_id(repo_owner, repo_name, artifact_id, token: token)
    rescue e : GitHubArtifactDownloadError
      raise HTTPException.new(:NotFound,
        "GitHub produced an error for the download of artifact ##{artifact_id}.\n" +
        "Usually this means that the artifact has expired (>90 days).\n" +
        "Check on GitHub: <#{gh_link}>"
      )
    rescue e : Halite::Exception::ClientError
      if e.status_code.in?(401, 404)
        raise HTTPException.new(:NotFound,
          "Artifact ##{artifact_id} not found.\nCheck on GitHub: <#{gh_link}>"
        )
      end
      raise e
    end
    result = Result.new
    result.title = {"Repository #{repo_owner}/#{repo_name}", "Artifact ##{artifact_id}"}
    result.links << ArtifactLink.new(tmp_link, "Ephemeral direct download link (expires in <1 minute)")
    result.links << ArtifactLink.new(
      artifact_gh_link, "Direct download of artifact ##{artifact_id} (requires GitHub login)", ext: true
    ) if artifact_gh_link
    link = abs_url(NightlyLink.gen_by_artifact(repo_owner: repo_owner, repo_name: repo_name, artifact_id: artifact_id))
    result.links << ArtifactLink.new("#{link}#{"?h=#{h}" if h}", result.title[1], zip: "#{link}.zip#{"?h=#{h}" if h}")

    return artifact_page(ctx, result, !!zip) if ctx
    return result
  end

  def artifact_page(ctx, result : Result, zip : Bool)
    if zip
      raise HTTPException.redirect(result.links.first.url)
    else
      title = result.title
      links = result.links.reverse!
      canonical = links.first.url

      ctx.response.content_type = "text/html"
      ECR.embed("templates/head.html", ctx.response)
      ECR.embed("templates/artifact.html", ctx.response)
    end
  end

  {% for path, i in ["github-markdown.min.css", "logo.svg"] %}
    {% ext = path.split(".")[-1] %}
    {% headers = "#{ext.upcase.id}_HEADERS".id %}
    {{headers}} = HTTP::Headers{
      "Content-Type"  => MIME.from_extension({{"." + ext}}),
      "Cache-Control" => "max-age=#{100.days.total_seconds}",
    }

    @[Retour::Get({{"/#{path.id}"}})]
    def static{{i}}(ctx)
      ctx.response.headers.merge!({{headers}})
      ctx.response << {{read_file(path.id)}}
    end
  {% end %}

  def serve_request(ctx, reraise = false)
    call(ctx, ctx)
  rescue exception
    if exception.is_a?(Retour::NotFound)
      exception = HTTPException.new(:NotFound, exception.to_s)
    elsif !exception.is_a?(HTTPException)
      raise exception if reraise
      Log.error(exception: exception) { }
      exception = HTTPException.new(:InternalServerError)
    end
    ctx.response.content_type = "text/html"
    ctx.response.status = status = exception.status
    ctx.response.headers.merge!(exception.headers)
    return if status.redirection?
    canonical = nil
    ECR.embed("templates/head.html", ctx.response)
    ECR.embed("templates/error.html", ctx.response)
  end
end

class HTTPException < Exception
  getter status : HTTP::Status
  property headers : HTTP::Headers

  def initialize(@status : HTTP::Status, message : String = "", @headers : HTTP::Headers = HTTP::Headers.new)
    super(message)
  end

  def self.redirect(location : String, status : HTTP::Status = :Found, headers : HTTP::Headers = HTTP::Headers.new)
    headers["Location"] = location
    HTTPException.new(status, headers: headers)
  end
end

if (port = PORT)
  app = NightlyLink.new
  server = HTTP::Server.new([
    HTTP::LogHandler.new,
  ]) do |ctx|
    app.serve_request(ctx)
  end
  server.bind_tcp("127.0.0.1", port)
  server.listen
end

ENV["GITHUB_APP_NAME"] = "github_app_name"
ENV["GITHUB_APP_ID"] = "12345"
ENV["GITHUB_CLIENT_ID"] = "github_client_id"
ENV["GITHUB_CLIENT_SECRET"] = "1" * 40
ENV["APP_SECRET"] = "1" * 32
ENV["FALLBACK_INSTALLATION_ID"] = INSTALLATION_F.to_s

INSTALLATION_F =    4433221
INSTALLATION_1 =    7654321
WORKFLOW_1     =     654321
CHECK_SUITE_1  = 1987654321
WORKFLOW_RUN_1 =  987654321
WORKFLOW_RUN_2 =  987654324
ARTIFACT_1     =   87654321

require "http"
require "spec_assert"
require "webmock"
require "../src/nightly_link"

Spec.before_each do
  WebMock.reset
  WebMock.stub(:post, "https://api.github.com/app/installations/#{INSTALLATION_F}/access_tokens").to_return(
    body: %({"token": "v1.1f699f1069f60xxx"}))
  WebMock.stub(:post, "https://api.github.com/app/installations/#{INSTALLATION_1}/access_tokens").to_return(
    body: %({"token": "v1.1f69921069f60zzz"}))
end

describe "index" do
  test "page" do
    resp, body = serve("/")
    assert resp.headers["Content-Type"] == "text/html"
    assert resp.status == HTTP::Status::OK
    assert body.includes?("select your repositories")
  end

  test "redirect" do
    resp, body = serve("/?url=https://github.com/oprypin/nightly.link/blob/master/.github/workflows/upload-test.yml")
    assert resp.status == HTTP::Status::FOUND
    assert resp.headers["Location"] == "/oprypin/nightly.link/workflows/upload-test/master"
  end

  test "bad url" do
    resp, body = serve("/?url=https://hmm")
    assert resp.status == HTTP::Status::OK
    assert body.includes?("select your repositories")
    assert body.includes?("not detect a link")
  end
end

describe "dashboard" do
  before_each do
    WebMock.stub(:get, "https://api.github.com/user/installations?per_page=10").to_return(
      body: %({"installations":[
                {"id":#{INSTALLATION_1},"account":{"login":"oprypin"},"updated_at":"2020-12-15T01:00:00Z"}]}))
    WebMock.stub(:get, "https://api.github.com/user/installations/#{INSTALLATION_1}/repositories?per_page=300").to_return(
      body: %({"repositories":[
                {"full_name":"oprypin/nightly.link","private":false,"fork":true},
                {"full_name":"oprypin/test-private-repo","private":true,"fork":false}]}))
  end

  test "redirect" do
    resp, body = serve("/dashboard")
    assert resp.status == HTTP::Status::FOUND
    assert resp.headers["Location"] == "https://github.com/login/oauth/authorize?client_id=github_client_id&scope=&redirect_uri=https%3A%2F%2Fnightly.link%2Fdashboard"
  end

  test "with code" do
    WebMock.stub(:post, "https://github.com/login/oauth/access_token").to_return(
      body: "access_token=tokentokentoken")
    resp, body = serve("/dashboard?code=codecodecode")
    assert resp.status == HTTP::Status::OK
  end

  test "redirect with bad code" do
    WebMock.stub(:post, "https://github.com/login/oauth/access_token").to_return(
      body: "error=bad_verification_code")
    resp, body = serve("/dashboard?code=codecodecode")
    assert resp.status == HTTP::Status::FOUND
    assert resp.headers["Location"] == "/dashboard"
  end
end

describe "dash_by_branch" do
  before_each do
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/workflows/SomeWorkflow.yml/runs?per_page=1&branch=SomeBranch&event=push&status=success").to_return(
      body: %({"workflow_runs":[
                {"id":#{WORKFLOW_RUN_1},"event":"push","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/UserName/RepoName/check-suites/#{CHECK_SUITE_1}","updated_at":"2020-12-19T22:22:22Z","repository":{"full_name":"UserName/RepoName","private":false,"fork":false}}]}))
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/workflows/SomeWorkflow.yml/runs?per_page=1&branch=SomeBranch&event=schedule&status=success").to_return(
      body: %({"workflow_runs":[
                {"id":#{WORKFLOW_RUN_2},"event":"schedule","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/UserName/RepoName/check-suites/#{CHECK_SUITE_1}","updated_at":"2021-02-07T07:15:00Z","repository":{"full_name":"UserName/RepoName","private":false,"fork":false}}]}))
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/runs/#{WORKFLOW_RUN_2}/artifacts?per_page=100").to_return(
      body: %({"artifacts":[{"id":#{ARTIFACT_1},"name":"SomeArtifact","url":"https://api.github.com/repos/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}"}]}))
  end
  test do
    resp, body = serve("/UserName/RepoName/workflows/SomeWorkflow/SomeBranch")
    assert resp.status == HTTP::Status::OK
  end
end

describe "by_branch" do
  before_each do
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/workflows/SomeWorkflow.yml/runs?per_page=1&branch=SomeBranch&event=push&status=success").to_return(
      body: %({"workflow_runs":[
                  {"id":#{WORKFLOW_RUN_1},"event":"push","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/UserName/RepoName/check-suites/#{CHECK_SUITE_1}","updated_at":"2020-12-19T22:22:22Z","repository":{"full_name":"UserName/RepoName","private":false,"fork":false}}]}))
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/workflows/SomeWorkflow.yml/runs?per_page=1&branch=SomeBranch&event=schedule&status=success").to_return(
      body: %({"workflow_runs":[
                  {"id":#{WORKFLOW_RUN_2},"event":"schedule","workflow_id":#{WORKFLOW_1},"check_suite_url":"https://api.github.com/repos/UserName/RepoName/check-suites/#{CHECK_SUITE_1}","updated_at":"2021-02-07T07:15:00Z","repository":{"full_name":"UserName/RepoName","private":false,"fork":false}}]}))
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/runs/#{WORKFLOW_RUN_2}/artifacts?per_page=100").to_return(
      body: %({"artifacts":[{"id":#{ARTIFACT_1},"name":"SomeArtifact","url":"https://api.github.com/repos/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}"}]}))
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/artifacts/#{ARTIFACT_1}/zip").to_return(
      headers: HTTP::Headers{"location" => "http://example.org/download1"})
  end

  test do
    resp, body = serve("/UserName/RepoName/workflows/SomeWorkflow/SomeBranch/SomeArtifact")
    assert resp.status == HTTP::Status::OK
    links = [
      "https://nightly.link/UserName/RepoName/workflows/SomeWorkflow/SomeBranch/SomeArtifact.zip",
      "https://nightly.link/UserName/RepoName/actions/runs/#{WORKFLOW_RUN_2}/SomeArtifact.zip",
      "https://nightly.link/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}.zip",
      "http://example.org/download1",
      "https://github.com/UserName/RepoName/actions?query=event%3Aschedule+is%3Asuccess+branch%3ASomeBranch",
      "https://github.com/UserName/RepoName/actions/runs/#{WORKFLOW_RUN_2}#artifacts",
      "https://github.com/UserName/RepoName/suites/#{CHECK_SUITE_1}/artifacts/#{ARTIFACT_1}",
    ].map { |s| body.index(s) }
    assert links.compact.sort == links

    resp, body = serve("/UserName/RepoName/workflows/SomeWorkflow/SomeBranch/SomeArtifact.zip")
    assert resp.status == HTTP::Status::FOUND
    assert resp.headers["Location"] == "http://example.org/download1"
  end
end

describe "by_run" do
  before_each do
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/runs/#{WORKFLOW_RUN_2}/artifacts?per_page=100").to_return(
      body: %({"artifacts":[{"id":#{ARTIFACT_1},"name":"SomeArtifact","url":"https://api.github.com/repos/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}"}]}))
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/artifacts/#{ARTIFACT_1}/zip").to_return(
      headers: HTTP::Headers{"location" => "http://example.org/download1"})
  end

  test do
    resp, body = serve("/UserName/RepoName/actions/runs/#{WORKFLOW_RUN_2}/SomeArtifact")
    assert resp.status == HTTP::Status::OK
    links = [
      "https://nightly.link/UserName/RepoName/actions/runs/#{WORKFLOW_RUN_2}/SomeArtifact.zip",
      "https://nightly.link/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}.zip",
      "http://example.org/download1",
      "https://github.com/UserName/RepoName/actions/runs/#{WORKFLOW_RUN_2}#artifacts",
    ].map { |s| body.index(s) }
    assert links.compact.sort == links

    resp, body = serve("/UserName/RepoName/actions/runs/#{WORKFLOW_RUN_2}/SomeArtifact.zip")
    assert resp.status == HTTP::Status::FOUND
    assert resp.headers["Location"] == "http://example.org/download1"
  end
end

describe "by_artifact" do
  before_each do
    WebMock.stub(:get, "https://api.github.com/repos/username/reponame/actions/artifacts/#{ARTIFACT_1}/zip").to_return(
      headers: HTTP::Headers{"location" => "http://example.org/download1"})
  end

  test "page" do
    resp, body = serve("/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}")
    assert resp.status == HTTP::Status::OK
    links = [
      "https://nightly.link/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}.zip",
      "http://example.org/download1",
    ].map { |s| body.index(s) }
    assert links.compact.sort == links
  end

  test "zip" do
    resp, body = serve("/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}.zip")
    assert resp.status == HTTP::Status::FOUND
    assert resp.headers["Location"] == "http://example.org/download1"
  end

  test "zip2" do
    resp, body = serve("/UserName/RepoName/suites/#{CHECK_SUITE_1}/artifacts/#{ARTIFACT_1}")
    assert resp.status == HTTP::Status::FOUND
    assert resp.headers["Location"] == "/UserName/RepoName/actions/artifacts/87654321.zip"
  end

  test "no double zip" do
    resp, body = serve("/UserName/RepoName/suites/#{CHECK_SUITE_1}/artifacts/#{ARTIFACT_1}.zip")
    assert resp.status == HTTP::Status::NOT_FOUND

    resp, body = serve("/UserName/RepoName/actions/artifacts/#{ARTIFACT_1}.zip.zip")
    assert resp.status == HTTP::Status::NOT_FOUND
  end
end

describe "static" do
  test "logo" do
    ["/logo.svg", NightlyLink.gen_logo].each do |path|
      resp, body = serve(path)
      assert resp.status == HTTP::Status::OK
      assert resp.headers["Content-Type"] == "image/svg+xml"
    end
  end
end

APP = NightlyLink.new(db: DB.open("sqlite3::memory:"))

def serve(method : String, path : String)
  io = IO::Memory.new
  yield request = HTTP::Request.new(method, path)
  response = HTTP::Server::Response.new(io)
  ctx = HTTP::Server::Context.new(request, response)
  APP.serve_request(ctx, reraise: true)
  Fiber.yield
  response.flush
  {response, io.to_s}
end

def serve(method : String, path : String)
  serve(method, path) { }
end

def serve(path : String)
  serve("GET", path) { }
end

def serve(path : String)
  serve("GET", path)
end

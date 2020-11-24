import threading
import urllib.parse

import cachetools
import flask
import requests

app = flask.Blueprint('artifact_dl', __name__)

ses = requests.Session()
ses.headers['Authorization'] = 'token ' + os.environ['GITHUB_TOKEN']


def github(url, *args, method='GET', **kwargs):
    resp = ses.request(method, urllib.parse.urljoin('https://api.github.com/', url), *args, **kwargs)
    resp.raise_for_status()
    return resp


def renderer(f):
    def decorated(*args, **kwargs):
        urls = list(f(*args, **kwargs))
        if flask.request.path != urls[0]:
            return flask.redirect(urls[0])
        return '<p>You can access this artifact by one of the following links, in the order from least to most direct</p><ul>' + ''.join([
            f'<li><a href="{url}">{url}</a></li>' for url in urls
        ]) + '</ul>'
    return decorated

def redirector(f):
    def decorated(*args, **kwargs):
        urls = f(*args, **kwargs)
        for url in urls:
            pass
        return flask.redirect(url)
    return decorated


@cachetools.cached(cachetools.TTLCache(100, ttl=5*60), lock=threading.Lock())
def get_workflow_run(user, repo, workflow, branch):
    resp = github(f'/repos/{user}/{repo}/actions/workflows/{workflow}/runs',
                  params={'branch': branch, 'event': 'push', 'status': 'success', 'per_page': 1})
    return resp.json()['workflow_runs'][0]


def by_branch(user, repo, workflow, branch, artifact):
    yield flask.url_for('.by_branch', user=user, repo=repo, workflow=workflow, branch=branch, artifact=artifact)
    yield flask.url_for('.by_branch_zip', user=user, repo=repo, workflow=workflow, branch=branch, artifact=artifact)

    if not workflow.isdigit() and not workflow.endswith('.yml'):
        workflow += '.yml'

    workflow_run = get_workflow_run(user, repo, workflow, branch)
    run_id = workflow_run['id']
    check_suite_id = workflow_run['check_suite_url'].split('/')[-1]

    yield from by_run(user, repo, run_id, artifact, check_suite_id=check_suite_id)

app.add_url_rule('/<user>/<repo>/<workflow>/<branch>/<artifact>', 'by_branch', renderer(by_branch))
app.add_url_rule('/<user>/<repo>/<workflow>/<branch>/<artifact>.zip', 'by_branch_zip', redirector(by_branch))

@cachetools.cached(cachetools.TTLCache(1000, ttl=5*60), lock=threading.Lock())
def get_artifacts(user, repo, run_id):
    resp = github(f'/repos/{user}/{repo}/actions/runs/{run_id}/artifacts')
    return resp.json()['artifacts']

def by_run(user, repo, run_id, artifact, *, check_suite_id=None):
    yield flask.url_for('.by_run', user=user, repo=repo, run_id=run_id, artifact=artifact)
    yield flask.url_for('.by_run_zip', user=user, repo=repo, run_id=run_id, artifact=artifact)

    artifacts = get_artifacts(user, repo, run_id)
    artifact = next(art for art in artifacts if art['name'] == artifact)

    yield from by_artifact(user, repo, artifact['id'], check_suite_id=check_suite_id)

app.add_url_rule('/<user>/<repo>/<run_id>/<artifact>', 'by_run', renderer(by_run))
app.add_url_rule('/<user>/<repo>/<run_id>/<artifact>.zip', 'by_run_zip', redirector(by_run))

@cachetools.cached(cachetools.TTLCache(1000, ttl=50), lock=threading.Lock())
def get_artifact_zip(user, repo, artifact_id):
    resp = github(f'/repos/{user}/{repo}/actions/artifacts/{artifact_id}/zip', allow_redirects=False)
    return resp.headers['location']

def by_artifact(user, repo, artifact_id, check_suite_id=None):
    if check_suite_id:
        yield f'https://github.com/{user}/{repo}/suites/{check_suite_id}/artifacts/{artifact_id}'
    yield flask.url_for('.by_artifact', user=user, repo=repo, artifact_id=artifact_id)
    yield flask.url_for('.by_artifact_zip', user=user, repo=repo, artifact_id=artifact_id)

    yield get_artifact_zip(user, repo, artifact_id)

app.add_url_rule('/<user>/<repo>/<artifact_id>', 'by_artifact', renderer(by_artifact))
app.add_url_rule('/<user>/<repo>/<artifact_id>.zip', 'by_artifact_zip', redirector(by_artifact))

@app.route('/')
def index():
    try:
        return renderer(by_branch)(**flask.request.args)
    except TypeError:
        return '''
<form><ul>
<li><label>Username: <input name="user" placeholder="crystal-lang" required></label>
<li><label>Repository: <input name="repo" placeholder="crystal" required></label>
<li><label>Workflow: <input name="workflow" placeholder="win.yml" required></label>
<li><label>Branch: <input name="branch" placeholder="master" required></label>
<li><label>Artifact: <input name="artifact" placeholder="crystal" required></label>
</ul><input type="submit"></form>
'''

@app.route('/', methods=['POST'])
def by_branch_redirect():
    return

if __name__ == '__main__':
    the_app = flask.Flask(__name__)
    the_app.register_blueprint(app, url_prefix='/github_artifact')
    the_app.run()

# nightly.link for GitHub

This service lets you get a shareable link to download a build artifact from the latest successful GitHub Actions build of a repository.

Only an admin of a repository can make its artifacts accessible here. When authorizing, you are encouraged to limit the selection of repositories. The selection can be changed TODO

<form action="/dashboard">
  <input type="submit" value="Authorize to add repositories">
</form>

## The issue

GitHub has no direct way to directly link to the *latest* build from GitHub actions of a given repository.

Even if you do have a link to an artifact, using it requires the visitor to be logged into the GitHub website.

The discussion originates at [actions/upload-artifact "Artifact download URL only work for registered users"](https://github.com/actions/upload-artifact/issues/51).

## Authorization

Because GitHub doesn't provide any permanent and public links to an artifact, this service redirects to time-limited links that GitHub can give to the application -- only on behalf of an authenticated user that has access to the repository. So, whenever someone downloads an artifact from a repository that you had added, this service uses a token that GitHub had given when you authorized.

You can uninstall this at <https://github.com/settings/installations>

### GitHub permissions that this service requests

#### Repository permissions

This GitHub application is configured to request this:

> * **Actions**: Workflows, workflow runs and artifacts.
>     * Access: **Read-only**
> * **Metadata** [mandatory]: Search repositories, list collaborators, and access repository metadata.
>     * Access: **Read-only**

## Privacy policy

An exhaustive list of what this service stores:

* Server-side:
    * Full repository names that you gave access to, and a token for accessing them on your behalf.
* Client-side: nothing.

This page will be updated if that changes.

## Pricing

No paid features are currently planned.

## Author

This service is developed and run by [Oleh Prypin](http://pryp.in/).

It has no affiliation with my employer.

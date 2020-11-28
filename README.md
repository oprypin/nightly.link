# nightly.link for GitHub

This service lets you get a shareable link to download a build artifact from the latest successful GitHub Actions build of a repository.

Any public repository is accessible by default.

If you'll be publishing a link to your own repository's artifacts, please install [the GitHub App][app] anyway, so that downloads for your repositories don't share the global API rate limit. The throttling could potentially become very bad over time.

[app]: https://github.com/apps/nightly-link

<include controls>

## The issue

GitHub has no direct way to directly link to the *latest* build from GitHub actions of a given repository.

Even if you *do* have a link to an artifact, using it requires the visitor to be logged into the GitHub website.

The discussion originates at [actions/upload-artifact "Artifact download URL only work for registered users"](https://github.com/actions/upload-artifact/issues/51).

So, this service is a solution to this omission.

## Authorization

Because GitHub doesn't provide any permanent and public links to an artifact, this service redirects to time-limited links that GitHub can give to the application -- only on behalf of an authenticated user that has access to the repository. So, whenever someone downloads an artifact from a repository that you had added, this service uses a token that GitHub had given when you authorized.

### [nightly.link][app] as an [Installed GitHub App][installations]

This GitHub App requests these permissions:

> * **Actions**: Workflows, workflow runs and artifacts.
>     * Access: **Read-only**
> * **Metadata** [mandatory]: Search repositories, list collaborators, and access repository metadata.
>     * Access: **Read-only**

[installations]: https://github.com/settings/installations

### [nightly.link][app] as an [Authorized GitHub App][authorizations]

Interestingly, the prompt that GitHub presents to you when authenticating the service says something quite a bit scarier, don't know why they wrote it like his:

> **nightly.link by [Oleh Prypin](https://github.com/oprypin) would like permission to:**
>
> * Verify your GitHub identity (*$username*)
> * Know which resources you can access
> * Act on your behalf

This is needed to verify your identity, so it's possible to 

Feel free to [revoke][authorizations] this part anytime.

[authorizations]: https://github.com/settings/apps/authorizations

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

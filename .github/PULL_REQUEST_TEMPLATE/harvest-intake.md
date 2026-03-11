Title convention:\
`harvest-intake: <org>.<repo> <run-id>`

Body template:

* Source org/repo:
* Source branch:
* Source commit SHA:
* Run ID:
* Generated at (UTC):
* Readiness status (`draft|reviewed|approved`):
* Blocker gaps open:
* Notes/Caveats:

Checklist:

* `harvest.manifest.yaml` included
* All required `knowledge-harvest/*` files included
* Target path is `migration/harvest-inputs/<org>.<repo>/<run-id>/`
* Manifest metadata matches source commit and run-id
* No secrets or credentials included

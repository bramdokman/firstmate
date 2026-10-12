
In this definition of done, "complete when committed" names the implementation stage only: committing is not delivering, and the task is delivered only when a PR exists for your branch.
**Neither half of the delivery report - the done line that names a PR - may be inferred from the absence of a failure.**
1. A PR must exist and you must have its real URL. A commit, or even a pushed branch, is not a delivered PR - never claim delivery without one: if the report should name a PR and none exists, append `blocked [at=<epoch>]: {what is actually true}` instead.
2. `checks green` may describe only checks that actually ran and passed. The status of the PR head commit (`tea api --repo <owner>/<repo> /repos/{owner}/{repo}/commits/<sha>/status`, where <sha> is the PR head commit) listing no statuses, or only pending ones, is NOT green - a workflow awaiting approval runs nothing. If nothing ran, never write `checks green`: report what you actually see and let firstmate decide.

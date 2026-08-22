# Objective

Implement Beadwork task {{issue.id}} from {{demand.source}}: {{demand.title}}

Authoritative demand URL: {{demand.url}}
Authoritative demand node ID: {{demand.node_id}}
Authoritative demand update time: {{demand.updated_at}}
Authoritative demand SHA-256: {{demand.content_sha256}}

{{demand.body}}

# Required process

- Read and follow `AGENTS.md`.
- Work only in the supplied worktree.
- Treat the demand snapshot above as authoritative for this run. GitHub remains
  the source of truth for mapped demands. Do not try to load the GitHub issue.
- Make the required code changes and tests.
- Do not commit, merge, close the issue, or run `bw sync`.

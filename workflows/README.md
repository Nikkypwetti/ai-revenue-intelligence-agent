# Workflows

Only **sanitized** n8n workflow exports should be published here.

Before committing an export, verify that it contains no:

- API keys or tokens
- passwords
- webhook secrets
- credential payloads
- authentication headers with secret values
- internal-only URLs that should not be public
- local secret-file contents

Credential references by name should also be reviewed before publication.

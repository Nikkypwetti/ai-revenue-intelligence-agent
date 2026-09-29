# Governed Gmail Report Delivery

Workflow: `REVINT-V2-EMAIL-01 | Governed Email Report Delivery`

This is an internal-only email delivery subworkflow. It receives an already-governed report artifact, authorizes delivery by tenant/principal role, resolves one trusted recipient from PostgreSQL governance, builds bounded escaped HTML, sends through Gmail, and records bounded audit metadata.

Dedicated n8n credential:
- ID: `REVINTGMAILREPORT001`
- Name: `REVINT | Gmail Reports`
- Type: `gmailOAuth2`

Do not reuse a Business OS Gmail credential automatically.

Repository defaults are disabled. The recipient is stored server-side and cannot be supplied by AI or an external caller.

Important: the adapter is importable now, but Agent Core should not be patched to call it until the local uncommitted Agent Core changes are reconciled. That avoids overwriting another workstream.

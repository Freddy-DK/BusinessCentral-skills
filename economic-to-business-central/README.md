---
layout: default
title: e-conomic → Business Central migration
permalink: /skills/economic-to-business-central/
---

# e-conomic → Business Central migration skill

A [Claude](https://claude.ai) skill that migrates a Danish **e-conomic** bookkeeping into a
**Microsoft Dynamics 365 Business Central** company through the
[Origo Cloud Events](https://origo.365.dk) MCP connector, plus two PowerShell helpers for the
bilag (receipt) side.

It was written after completing the migration it describes. That run reconciled to the source
**exactly — zero difference on every account with movement**, for both the full period and the
fiscal-year cut-off. Most of the skill is not the happy path; it is the twelve specific things
that went wrong on the way there, written down so the next person does not repeat them.

---

## What it does

Claude drives the migration interactively. It:

1. Checks the Origo connector is available, discovers your tenants, environments and
   companies, and lets you pick the target.
2. Refuses to run against a company that already has posted entries, and warns loudly on a
   production environment.
3. Detects a company created from the CRONUS/standard template and makes you decide what to
   do about it, rather than layering your chart on top of it.
4. Asks what you want migrated — entities, how much history, whether sales invoices should be
   posted as real invoices or booked as journal lines, how opening balances are handled, and
   whether to do a capped trial run first.
5. Analyses the export locally and builds the expected trial balance **before** writing
   anything.
6. Builds the foundation (accounts, posting setup, VAT, customers, items) in dependency
   order, then posts transactions, then invoices.
7. Reconciles every account against the source and reports the differences.
8. Optionally splits and uploads the bilag PDFs and verifies each one landed on the right
   transaction.

## What it deliberately does not do

- It does not migrate into a company that has already been posted to.
- It does not decide for you whether to post the source's opening-balance entries. That
  choice can double every balance-sheet account, so it is always yours.
- It does not run Close Income Statement — there is no API for a closing-date entry, so that
  stays a manual step in the BC UI.
- It does not create bank account cards. G/L accounts alone give you no bank reconciliation.

---

## Requirements

| | |
|---|---|
| Claude | Claude Code, or Claude's Cowork mode |
| Connector | Origo Cloud Events MCP, connected and authenticated to your BC tenant |
| BC | A company with **no posted entries**. Sandbox first, always. |
| e-conomic | A data export (CSV) and, for receipts, a bilag export (PDF) |
| Receipts only | PowerShell 7+, and an Entra ID app registration for the BC REST API |

**The Origo ChangeLog Write Guard must be opened before you start.** When it is set to
"Via force" with an empty exception list it blocks every write, and its configuration lives in
connector-internal tables that the API refuses to read or write. Only you can change it, in
the Business Central UI. Remember to put it back afterwards.

---

## Install

Drop the skill into your skills directory:

```bash
git clone https://github.com/<you>/economic-to-business-central.git
mkdir -p ~/.claude/skills
cp -r economic-to-business-central ~/.claude/skills/
```

Claude picks it up from `~/.claude/skills/economic-to-business-central/SKILL.md`. Then just
describe what you want:

> Migrate my e-conomic export into Business Central, sandbox environment, company Contoso ApS.

The skill triggers on mentions of an e-conomic migration, an e-conomic export, `Postering.csv`,
or bilag PDFs alongside Business Central.

---

## Repository layout

```
economic-to-business-central/
├── README.md                        this file
├── SKILL.md                         the skill itself
└── scripts/
    ├── Split-EconomicBilag.ps1      splits e-conomic bilag batch PDFs into one file per voucher
    └── Upload-BilagToBC.ps1         attaches each PDF to its posted G/L entry via the BC API
```

### `Split-EconomicBilag.ps1`

e-conomic stamps every exported bilag page with
`Regnskabsår: 2025/2026   Bilagsnummer: 62   Side: 41/144`. The script reads that stamp,
groups the pages belonging to each voucher, and writes one PDF per voucher. Pages are copied
object-for-object, so scanned images are never re-encoded — verified byte-identical image
streams against the source.

```powershell
.\Split-EconomicBilag.ps1 .\Bilag*.pdf -OutDir .\receipts -Postering .\Postering.csv
```

Output is `receipts\2025-2026\bilag-062_2025-10-10_Dropbox.pdf` and a `bilag_index.csv`
manifest. Pass `-Postering` to get the posting date and entry text into the file names, which
makes the result far easier to check by eye. `-Flat` writes everything into one folder.

PDF handling uses [PdfPig](https://github.com/UglyToad/PdfPig) (Apache-2.0), downloaded from
nuget.org into a local `lib\` folder on first run; after that it works offline, and
`-PdfPigPath` points at a copy you supply. Requires PowerShell 7.

### `Upload-BilagToBC.ps1`

Attaches each split PDF to the posted G/L entry whose `Document No.` matches the voucher
number in the file name.

```powershell
.\Upload-BilagToBC.ps1 -Folder .\receipts -TenantId <guid> -ClientId <guid> `
    -ClientSecret $env:BC_SECRET -Environment <env> -CompanyName '<company>' -First 1
```

Run it with `-First 1` first and look at the result in BC. There is no undo: each upload
creates an Incoming Document in a live company.

It is safe to re-run. For each file it lists what is already attached to that entry, removes
duplicate copies of the same file name, and uploads only what is missing. It retries HTTP 409
(record lock), 429 (throttling) and 5xx with exponential backoff, and reports failures at the
end instead of stopping.

**Setting up the Entra app** — once per tenant, plus a registration per BC environment:

1. Entra admin center → App registrations → New registration. Single tenant, no redirect URI.
   Copy the **Application (client) ID**.
2. Certificates & secrets → New client secret → copy the **Value** immediately.
3. API permissions → Microsoft APIs → **Dynamics 365 Business Central** →
   **Application permissions** → **API.ReadWrite.All**.
4. **Grant admin consent.** Without it the token is issued and BC rejects it.
5. In Business Central → *Microsoft Entra Applications* → New → paste the Client ID →
   State = **Enabled**.
6. Assign a permission set. Apps cannot have SUPER; **D365 BUS FULL ACCESS** is what
   attachments need. D365 AUTOMATION alone does not cover G/L entries.

Keep the secret in an environment variable. Never put it in the script.

---

## Things worth knowing before you start

A few findings from the reference migration that are hard to discover on your own:

- **`Gen. Jnl.-Check Line` reports `Ready` on a batch that is badly out of balance in LCY.**
  It reported no errors on one that was 683,970 out. Gate every post on `totalAmountLCY = 0`.
  This is the most valuable line in the whole skill.
- **A customer's `Currency Code` silently stamps itself onto journal lines** you intended as
  local currency, inflating Amount (LCY) with no error anywhere. Send `"CurrencyCode": ""`
  explicitly.
- **Migrating a reversed payment as Document Type = Refund gives a correct ledger and a wrong
  customer list.** `Payments (LCY)` sums only Document Type = Payment, so it counts both the
  erroneous payment and its replacement. Use `ReverseTransaction` on the original instead.
  Unwinding this cost sixteen junk G/L entries.
- **`Data.Records.Set` overwrites a Sales Line's `Description`** when it validates the item
  `No.`, regardless of key order. Restore descriptions in a separate pass before posting;
  lines cannot be edited afterwards.
- **`Sales.Document.Post` returns Success and posts nothing** unless `Ship` and `Invoice` are
  set on the header first.
- **There is no delete.** Wrong rows can only be blanked, and posted entries are not writable
  at all. This is why the skill front-loads so much analysis.
- **Attaching a file to a G/L entry creates an Incoming Document**, not a Document Attachment.
  The `Document Attachment` table stays empty. The attachment content URL is single-key —
  the documented `attachments(parentId=…,id=…)` form is rejected.
- **e-conomic exports are Latin-1**, not UTF-8.

The full list, with the surrounding context, is in `SKILL.md`.

---

## Scope and limitations

Written against Business Central 28.x and Origo Cloud Events 28.x. It is **Danish-only** by
nature: e-conomic is a Danish-only bookkeeping system, so there is no such thing as a
non-Danish e-conomic migration. The reference source was a single-currency (DKK, 25% VAT)
bookkeeping with foreign-currency customer invoices.

It handles customers, items and sales invoices. Vendor documents and purchase invoices were
not exercised — the reference source posted all purchases as journal entries.

If the source carries purchase VAT on explicit lines, the skill posts journal lines with blank
posting groups so BC does not calculate VAT twice. The ledger then matches exactly, but you
get no purchase VAT entries in BC. That is a deliberate trade-off, not an oversight.

---

## Contributing

This skill migrates from **e-conomic, which is a Danish-only bookkeeping system**, so the
skill is Danish-only too — there is no non-Danish e-conomic to migrate from. Corrections and
additions within that Danish scope are welcome, particularly for vendor/purchase flows. If you
hit a BC or Origo behaviour that cost you time, that is exactly the kind of thing this skill
exists to record — open a PR against `SKILL.md`.

## License

MIT. PdfPig is Apache-2.0 and is downloaded at runtime, not vendored.

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

Written after the migration it describes, which reconciled to the source **exactly — zero
difference on every account with movement**. Most of the skill documents the twelve things
that went wrong, so you don't repeat them.

---

## What it does

Claude drives the migration interactively:

1. Checks the Origo connector, discovers your tenants/environments/companies, and lets you
   pick the target.
2. Refuses to run against a company with posted entries; warns loudly on production.
3. Detects a CRONUS/standard-template company and makes you decide what to do, rather than
   layering your chart on top.
4. Asks what to migrate — entities, history depth, invoices as real invoices or journal
   lines, opening-balance handling, and whether to do a capped trial run.
5. Builds the expected trial balance locally **before** writing anything.
6. Builds the foundation (accounts, posting setup, VAT, customers, items), then posts
   transactions, then invoices.
7. Reconciles every account against the source and reports differences.
8. Optionally splits and uploads the bilag PDFs, verifying each landed on the right entry.

## What it does not do

- Migrate into a company that already has posted entries.
- Decide whether to post the source's opening-balance entries — that choice can double every
  balance-sheet account, so it stays yours.
- Run Close Income Statement — no API for a closing-date entry, so it's a manual BC step.
- Create bank account cards.

---

## Requirements

| | |
|---|---|
| Claude | Claude Code, or Cowork mode |
| Connector | Origo Cloud Events MCP, authenticated to your BC tenant |
| BC | A company with **no posted entries**. Sandbox first. |
| e-conomic | A data export (CSV) and, for receipts, a bilag export (PDF) |
| Receipts only | PowerShell 7+, and an Entra ID app registration for the BC REST API |

**Open the Origo ChangeLog Write Guard before you start.** Set to "Via force" with an empty
exception list, it blocks every write, and only you can change it in the BC UI. Restore it
afterwards.

---

## Install

```bash
git clone https://github.com/<you>/economic-to-business-central.git
mkdir -p ~/.claude/skills
cp -r economic-to-business-central ~/.claude/skills/
```

Then describe what you want:

> Migrate my e-conomic export into Business Central, sandbox environment, company Contoso ApS.

It triggers on mentions of an e-conomic migration, an e-conomic export, `Postering.csv`, or
bilag PDFs alongside Business Central.

---

## Repository layout

```
economic-to-business-central/
├── README.md                        this file
├── SKILL.md                         the skill itself
└── scripts/
    ├── Split-EconomicBilag.ps1      splits bilag batch PDFs into one file per voucher
    └── Upload-BilagToBC.ps1         attaches each PDF to its posted G/L entry via the BC API
```

### `Split-EconomicBilag.ps1`

Reads the stamp e-conomic prints on every bilag page
(`Regnskabsår: 2025/2026   Bilagsnummer: 62   Side: 41/144`), groups the pages per voucher,
and writes one PDF each. Pages are copied object-for-object — scanned images are never
re-encoded.

```powershell
.\Split-EconomicBilag.ps1 .\Bilag*.pdf -OutDir .\receipts -Postering .\Postering.csv
```

Output: `receipts\2025-2026\bilag-062_2025-10-10_Dropbox.pdf` plus a `bilag_index.csv`
manifest. `-Postering` adds the posting date and text to file names; `-Flat` writes one
folder. Uses [PdfPig](https://github.com/UglyToad/PdfPig) (Apache-2.0), fetched from nuget.org
into a local `lib\` on first run (offline after that; `-PdfPigPath` supplies your own).
Requires PowerShell 7.

### `Upload-BilagToBC.ps1`

Attaches each split PDF to the posted G/L entry whose `Document No.` matches the voucher
number in the file name.

```powershell
.\Upload-BilagToBC.ps1 -Folder .\receipts -TenantId <guid> -ClientId <guid> `
    -ClientSecret $env:BC_SECRET -Environment <env> -CompanyName '<company>' -First 1
```

Run `-First 1` first and check BC — there is no undo; each upload creates an Incoming Document
in a live company. Safe to re-run: it skips what's already attached, removes duplicate
filenames, and retries HTTP 409/429/5xx with backoff.

**Entra app setup** — once per tenant, plus a registration per BC environment:

1. Entra admin center → App registrations → New. Single tenant, no redirect URI. Copy the
   **Application (client) ID**.
2. Certificates & secrets → New client secret → copy the **Value** now.
3. API permissions → **Dynamics 365 Business Central** → **Application permissions** →
   **API.ReadWrite.All**.
4. **Grant admin consent** — without it BC rejects the token.
5. BC → *Microsoft Entra Applications* → New → paste the Client ID → State = **Enabled**.
6. Assign **D365 BUS FULL ACCESS** (D365 AUTOMATION doesn't cover G/L entries; apps can't
   have SUPER).

Keep the secret in an environment variable, never in the script.

---

## Things worth knowing

- **`Gen. Jnl.-Check Line` reports `Ready` on a batch badly out of balance in LCY** — it
  passed one that was 683,970 out. Gate every post on `totalAmountLCY = 0`.
- **A customer's `Currency Code` stamps itself onto journal lines** meant as LCY, inflating
  Amount (LCY) with no error. Send `"CurrencyCode": ""` explicitly.
- **A reversed payment migrated as Document Type = Refund gives a wrong customer list** —
  `Payments (LCY)` sums only Document Type = Payment. Use `ReverseTransaction` on the original.
- **`Data.Records.Set` overwrites a Sales Line's `Description`** when it validates the item
  `No.`. Restore descriptions in a separate pass before posting.
- **`Sales.Document.Post` returns Success and posts nothing** unless `Ship` and `Invoice` are
  set on the header first.
- **There is no delete.** Wrong rows can only be blanked; posted entries aren't writable.
- **Attaching a file to a G/L entry creates an Incoming Document**, not a Document Attachment.
  The attachment content URL is single-key.
- **e-conomic exports are Latin-1**, not UTF-8.

Full context is in `SKILL.md`.

---

## Scope and limitations

Written against Business Central 28.x and Origo Cloud Events 28.x. **Danish-only** by nature:
e-conomic is a Danish-only bookkeeping system, so there is no non-Danish e-conomic to migrate
from. The reference source was single-currency (DKK, 25% VAT) with foreign-currency customer
invoices.

Handles customers, items and sales invoices. Vendor/purchase documents weren't exercised — the
reference posted all purchases as journal entries. Purchase VAT on explicit source lines is
posted with blank posting groups so BC doesn't double-count it: the ledger matches, but you get
no purchase VAT entries in BC (a deliberate trade-off).

---

## Contributing

The skill is Danish-only because e-conomic is. Corrections within that scope are welcome,
especially vendor/purchase flows. Hit a BC or Origo behaviour that cost you time? Open a PR
against `SKILL.md`.

## License

MIT. PdfPig is Apache-2.0 and is downloaded at runtime, not vendored.

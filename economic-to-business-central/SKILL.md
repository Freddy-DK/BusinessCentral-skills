---
name: economic-to-business-central
description: Migrate financial data from an e-conomic export into Microsoft Dynamics 365 Business Central through the Origo Cloud Events connector - chart of accounts, posting setup, customers, items, transactions, sales invoices and bilag receipts. Use when someone asks to migrate, move or import e-conomic data into Business Central, or mentions an e-conomic export, Postering.csv or bilag PDFs alongside BC.
---

# e-conomic → Business Central migration

Migrates a Danish e-conomic bookkeeping into a Business Central company using the
Origo Cloud Events connector. Built from a completed migration that reconciled to the
source **exactly — zero difference on every account with movement**. The procedure below
is ordered so that each step's prerequisites exist before it runs; changing the order is
the most common way to fail.

Never start writing until Step 0 and Step 1 are both done.

---

## Step 0 — Preflight

Check these in order and stop at the first failure. Do not work around a failure silently.

1. **Is the Origo connector present?** Look for `Data.Records.Set` / `mcp__Origo__*` tools
   in the tool list (they may be deferred — load them with ToolSearch). If Origo is absent,
   say so plainly and stop: this skill has no other way to write to BC.
2. **Discover the context.** `Context.Companies.List` with no argument lists tenants;
   pass a `tenant_id` to expand it into environments and companies.
3. **Select the target.** `Context.Company.Switch(tenant_id, environment, company_id)`.
   Never guess — always pick from what discovery returned, and confirm the choice with the
   user before switching.
4. **If `environment_type` is `production`, stop and confirm explicitly.** Say the
   environment and company name back and get a yes. A migration into the wrong live company
   cannot be undone: there is no `Data.Records.Delete` message type.
5. **Is the target empty?** Count `G/L Entry`, `G/L Account`, `Customer`, `Item`,
   `Accounting Period`, `General Posting Setup`, `VAT Posting Setup`.
   - Entries > 0 → stop. This skill migrates into a company that has never been posted to.
   - Entries = 0 but accounts ≈ 250–350 → the company was created from a **standard/CRONUS
     template**. Report the counts and make the user choose: strip the standard data, create
     a fresh company, or map the source onto the standard chart (much more work). Do not
     layer an imported chart on top of a standard one.
6. **Write access.** Origo's ChangeLog Write Guard blocks every write when set to
   "Via force" with an empty exception list, and its configuration lives in
   connector-internal tables the API refuses to read or write. **Only the user can change
   it, in the BC UI.** Probe with one harmless write early; if it is blocked, tell the user
   exactly what to change and wait. Remind them to restore it at the end.

---

## Step 1 — Scope interview

Use AskUserQuestion. These answers change the whole shape of the work, so ask before
reading a single CSV. Batch them into one or two calls.

| Question | Options | What it changes |
|---|---|---|
| **Which entities?** (multi-select) | Chart of accounts · Posting setup & VAT · Customers & contacts · Vendors · Items · Transactions · Sales invoices · Receipts/bilag | Which of Steps 3–8 run at all |
| **How much history?** | Everything in the export · Current fiscal year plus opening balances · A date range the user names | Full detail means every journal line; opening balances means one dated journal per account |
| **Sales invoices** | Post as real sales invoices (customer ledger, VAT entries, document history) · Book as G/L journal lines only | Real invoices need items, posting groups, number series and four passes; journal lines need none of it |
| **Opening balances** | Let BC carry the prior year forward · Post the source's primo entries | See Step 5.1 — getting this wrong doubles every balance sheet account |
| **Trial run?** | Import everything · Import the first N of each entity | A capped run validates the mapping cheaply before committing |

Also confirm: fiscal year start date, LCY, and whether the company already has a number
series the invoices must use.

Echo the choices back as a short plan and get agreement before writing anything.

---

## Step 2 — Inventory the export

e-conomic's data export is a folder of CSV files with GUID-prefixed names. Identify them by
their suffix, not their prefix:

| File | Contents | Needed for |
|---|---|---|
| `*-Postering.csv` | every transaction line — the source of truth | Transactions |
| `*-Konto.csv` | chart of accounts | Foundation |
| `*-Faktura.csv` / `*-FakturaLinje.csv` | invoice headers and lines | Sales invoices |
| `*-Vare.csv` / `*-VareGruppe.csv` | items and item groups | Revenue matrix, items |
| `*-SystemKonto.csv` | FX and year-end system accounts | Transactions |
| `*-Kunde.csv`, `*-Kontaktperson.csv` | customers, contacts | Customers |
| `*-AfgiftsKonto.csv` | VAT accounts | VAT setup |

**Encoding is Latin-1 (ISO-8859-1), not UTF-8.** Read with a strict-UTF-8 attempt and fall
back, or Danish characters become mojibake in account names and customer names. Fields are
comma-separated and quoted; dates are `dd-mm-yyyy`; decimals use a comma.

The bilag receipts are a **separate** export ("Eksporter bilag") producing batch PDFs of
up to ~100 vouchers each, every page stamped
`Regnskabsår: … Bilagsnummer: … Side: n/total`.

---

## Step 3 — Analyse before writing

Do this analysis in a local script, not by eyeballing. It is what makes the result reconcile.

1. **Build the expected trial balance from `Postering.csv`** — per account, for the full
   period and at each fiscal year end. This is the target you will verify against in Step 8.
2. **Derive the revenue matrix.** e-conomic picks the revenue account from
   *item group × VAT zone*. Reproduce it natively as BC **General Posting Setup**
   (Gen. Bus. Posting Group × Gen. Prod. Posting Group → sales account). Walk every invoice
   line in the source and confirm your matrix reproduces the account it actually used.
   Customers that the source treats specially (a foreign customer booked as domestic, say)
   are handled with a **header-level Gen. Bus. Posting Group override** on that invoice,
   not by bending the matrix.
3. **Classify the odd rows in `Postering.csv`** before deciding what to post:
   - `Primopostering` at a fiscal year start — almost always duplicates of the prior year's
     closing balances, which BC carries forward natively. Verify account by account that each
     primo amount equals the computed close, then **exclude them**. Posting them doubles
     every balance sheet account.
   - `Overført primopostering` on the retained earnings account — the source's income
     statement close. **Exclude**; run BC's own Close Income Statement afterwards.
   - VAT roll-forward rows into the VAT settlement account — **real postings**. Include them
     as a dated journal on the first day of the new fiscal year.
4. **Find the currency edge cases.** List every foreign-currency payment whose settlement
   rate differs from its invoice rate, and any two payments on the same date with different
   rates. The second case cannot be expressed in BC's exchange rate table — see Step 6.3.
5. **Find date collisions.** Any payment dated before the invoice it settles will be refused
   on application. Note them for Step 6.5.

---

## Step 4 — Foundation

Build in this order; each step depends on the previous one.

1. Company Information — name, registration number, address, bank details.
2. **Accounting Periods** for every fiscal year in scope, with `New Fiscal Year` on the first
   period of each. ⚠ `Name` is **Code[10]** — "August 2025" is rejected, "Aug 2025" is not.
3. General Ledger Setup — LCY, allowed posting dates, rounding.
4. No. Series, including the sales invoice series. Set `ManualNos_` = true if source
   invoice numbers must be preserved.
5. **Chart of Accounts** — Account Type, Totaling, `Income_Balance`, indentation.
   ⚠ Do **not** set `Gen. Prod. Posting Group` on accounts that will receive plain journal
   lines: BC then demands a Gen. Posting Type on every line hitting them
   ("Posting to Account X must either be of type Purchase or Sale").
   ⚠ But accounts referenced by a **Customer/Vendor Posting Group** *do* need one.
6. Posting groups — Gen. Bus., Gen. Prod., VAT Bus., VAT Prod., Customer, Vendor.
7. **General Posting Setup** — the revenue matrix from Step 3.2.
8. **VAT Posting Setup** — one combination carries the domestic rate and its VAT accounts;
   the rest are 0%.
9. Currencies and exchange rates.
10. Customers, contacts, vendors. ⚠ A `Currency Code` on a customer card will later stamp
    itself onto journal lines — see Step 6.2.
11. Items. ⚠ Setting `Base Unit of Measure` does **not** create the `Item Unit of Measure`
    child record. Create every item/UoM combination explicitly or posting fails with
    "… cannot be found in the related table".
12. Sales & Receivables Setup — reference it by table number **311**; the name contains `&`
    and arrives HTML-escaped.

---

## Step 5 — Field naming and write mechanics

- **Field names are normalised**: `%`, `.`, `"`, `\`, `/`, `'` become `_`, then remaining
  non-alphanumeric characters are stripped. "E-Mail" → `EMail`, "No. Series" → `No_Series`,
  "Qty. per Unit of Measure" → `Qty_perUnitofMeasure`, "EU Country/Region Code" →
  `EUCountry_RegionCode`. When a write is rejected the error lists the valid names — read it
  rather than guessing again.
- Use `Help.Fields.Get` for a table before the first write to it.
- Table names containing `&` arrive HTML-escaped; use the table number.
- There is **no delete**. Wrong rows can only be blanked. Posted entries are not writable at
  all — a wrong `Document Type` on a ledger entry has to be reversed and re-posted.
- Write in batches aligned to vouchers, roughly 100 lines at a time. Never split a voucher
  across batches.

---

## Step 6 — Transactions

### 6.1 The gate

`Gen. Jnl.-Check Line` reports `Ready` with zero errors on batches that are badly out of
balance in LCY. **Before every post, read the batch's `totalAmountLCY` and refuse to post
unless it is 0.** This single check is worth more than every other rule here.

### 6.2 Currency leakage

A customer whose card carries a `Currency Code` silently stamps it onto journal lines meant
as LCY, inflating Amount (LCY) without any error. Send `"CurrencyCode": ""` **explicitly**,
after the account number, on every line intended as local currency.

### 6.3 Foreign currency

When settlement rates differ from invoice rates — and especially when two payments on the
same date used different rates — do **not** try to model it in the exchange rate table.
Set an explicit **per-line `Currency Factor`**, which forces the exact LCY amount
(Amount LCY = Amount ÷ CurrencyFactor). BC then generates the realised gains and losses
itself on application, and they will match the source's FX difference postings to the cent.
Never pre-post the differences yourself.

### 6.4 Payments and reversals — the expensive mistake

When the source shows a payment posted in error and later backed out, migrating the reversal
voucher as a customer entry with **Document Type = Refund** produces a correct ledger and a
visibly wrong customer list: `Payments (LCY)` is a FlowField that sums only Document
Type = Payment, so it counts the wrong payment *and* its replacement while ignoring the
Refund that cancelled one. In BC a Refund also means money actually returned to the
customer, which is not what happened.

**Correct:** post the original payment, then reverse it with
`Finance.GeneralJournal.ReverseTransaction` on its Transaction No. BC's own reversal
produces a positive-amount Payment entry, which a manual journal cannot — the check enforces
"Amount must be negative" for a customer Payment. Register-level reversal is refused when
entries were posted and applied in the same transaction, so reverse per Transaction No.

### 6.5 Application

BC refuses to apply a payment dated earlier than its invoice. Post the payment **unapplied**,
then apply it with `Customer.Application.Post`.

### 6.6 VAT on journals

If the source carries purchase VAT on explicit lines to VAT accounts, post journal lines with
**blank posting groups and blank Gen. Posting Type** so BC does not calculate VAT a second
time. The ledger then matches exactly; the trade-off is no purchase VAT entries in BC. Say
this out loud to the user — it is a real consequence, not a detail.

---

## Step 7 — Sales invoices

Only if the user chose real invoices in Step 1. Four passes, in this order:

1. **Headers.** Force source invoice numbers if wanted (needs `ManualNos_`). Apply any
   header-level Gen. Bus. Posting Group override from Step 3.2.
2. **Lines.**
3. **Descriptions — a separate pass.** ⚠ `Data.Records.Set` **overwrites** the Sales Line
   `Description` whenever it validates the item `No.`, regardless of key order. Restore
   descriptions in their own pass **before** posting; lines cannot be edited afterwards.
4. **Post.** ⚠ `Sales.Document.Post` needs `Ship` **and** `Invoice` set to true on the
   header first. Without them it returns Success and posts nothing.

---

## Step 8 — Reconcile, and do not skip it

Compare against the expected trial balance from Step 3.1:

- every account with movement, for the full period **and** at each fiscal year end
- open customer entries against the receivables control account
- VAT entry count against invoice count
- G/L entry count against what you intended to post

Report the result as a table of differences. If anything is non-zero, find it before moving
on — a difference here never gets smaller later. Consider a subagent for an independent check
of a large batch before it is posted.

---

## Step 9 — Receipts (bilag)

Only if the user asked for them. The files cannot go through the conversation — a few hundred
PDFs is hundreds of megabytes of base64 — so this runs as a script on the user's machine.

1. **Split** the batch PDFs into one file per voucher by reading the page stamp, grouping
   consecutive pages with the same voucher number, and copying pages object-for-object so
   scans are not re-encoded. Name them `bilag-NNN_YYYY-MM-DD_Text.pdf` and write an index CSV.
2. **Check the mapping** on one voucher: the file name's voucher number must equal the
   `Document No.` the transaction was posted with.
3. **Upload** via the BC REST API using an Entra app (client credentials,
   `API.ReadWrite.All`, admin consent, plus a registration in BC's *Microsoft Entra
   Applications* page with a write-capable permission set — per environment).
   POST to `companies({id})/generalLedgerEntries({glId})/attachments` with the file name,
   then PATCH the bytes to `companies({id})/attachments({attachmentId})/attachmentContent`.
   ⚠ The content URL is **single-key**; the documented `attachments(parentId=…,id=…)` form
   is rejected. ⚠ **HTTP 409 is transient** (a record lock, not "already exists"), as is 429
   (throttling, which appears after a few hundred calls) — retry both with backoff.
   Make the script list existing attachments per entry and skip or de-duplicate, so it is
   safe to re-run.
4. **Verify** by reading `Incoming Document Attachment` (Entry No., Name, Document No.,
   Posting Date) and comparing to the index. BC fills Document No. and Posting Date from the
   entry it bound to, so this is BC's own record of the link rather than your mapping echoed
   back.

Note what BC actually does: attaching to a G/L entry creates an **Incoming Document** per
entry with the PDF on it; the `Document Attachment` table stays empty. The receipt appears on
the lowest-numbered G/L entry of each voucher, not on all of them.

---

## Step 10 — Close out

- Run **Close Income Statement** for each closed fiscal year in the BC UI. There is no
  message type for it and a closing-date entry cannot be expressed over the API.
- Create real bank account cards if the user wants bank reconciliation; a G/L account alone
  gives no Bank Account Ledger Entries.
- **Restore the ChangeLog Write Guard** to its original setting.
- Delete any blanked journal lines left behind.
- Write a migration record: what was migrated, the decisions taken, the reconciliation
  result, and what was deliberately left out. Save it where the user will find it later.

---

## Rules of thumb

- Read before you write, verify after you write, and never report success you have not checked.
- A cheap analysis pass in a local script beats a wrong write you cannot delete.
- When a result surprises you, check the source data before assuming BC is wrong — most
  apparent discrepancies turn out to be faithful reproductions of what the source actually did.
- Tell the user about trade-offs as they are taken, not at the end.

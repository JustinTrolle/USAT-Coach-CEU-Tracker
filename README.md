# USA Triathlon Coach CEU Tracker

Internal dashboard for the USA Triathlon coaching education team. It tracks coaches in the
current recertification period, their background check and SafeSport status, and the
Official and Adjunct CEUs they have purchased on Thinkific.

The page is a single static file (`index.html`) hosted on GitHub Pages. All data lives in the
Supabase project **USAT Education** behind row-level security, so nothing is readable
without signing in with an allow-listed staff account.

## Daily use

1. Sign in with your work email.
2. **Coaches** tab: coaches are grouped Level III, then Level II, then Level I.
   - Tick the box next to a coach to select them. **Email sheet** downloads an Excel file of
     the selected coaches; **Copy emails** puts their addresses on the clipboard for Outlook.
   - The checkbox in the *Background check* and *SafeSport* columns is ticked while the
     credential is valid, with days remaining next to it. Red means expired.
   - Click an **Official CEUs** or **Adjunct CEUs** number to see the courses behind it.
   - Click **Notes** (or the coach's name) to open the notes accordion. Notes are shared and
     saved with author and time.
   - The two date pickers set the order window used for CEU totals. Default is
     1 Dec 2024 to today.
3. **Review** tab: two lists that need a human decision.
   - *Possible matches by name*: Thinkific orders under a coach's exact name but a different
     email. Confirm to count them for that coach, Reject to hide.
   - *Products not in the catalog*: things coaches bought that the catalog does not list.
     Give them a CEU value to start counting them.
4. **Catalog** tab: every product and its CEU value/type. Edits save instantly.
5. **Uploads** tab: drop in a new coach list, a new Thinkific orders export, or a new catalog.
   - Coach list: replaces the whole list. Notes are kept by credential number.
   - Orders: matched on Thinkific Order ID, so a cumulative export just adds new orders.
   - Catalog: replaces uploaded rows, keeps rows added manually.

## CEU rules

- Catalog column "CEUs + Adj CEUs": a plain number is Official, a number followed by `a`
  is Adjunct, `0` is none.
- A coach who buys the same product twice in the window is credited once. The second
  purchase is shown in the detail view as a duplicate.
- Orders are matched to coaches by email (case-insensitive), plus any alternate emails
  confirmed on the Review tab.

## Administration

- Allowed sign-ins are the rows in the `allowed_users` table. To add someone, create the
  auth user in Supabase and insert their email into that table.
- Schema: `supabase/schema.sql`.
- Local preview: serve the folder with any static file server. No build step.

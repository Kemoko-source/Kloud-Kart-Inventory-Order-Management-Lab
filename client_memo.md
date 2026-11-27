# Memo to Nana

**From:** Kemoko Foumba Traore
**Date:** 27 November 2026
**Subject:** Overselling is fixed and Adwoa's report takes seconds, but check three things before trusting the numbers

## What I found

Your data has fourteen real problems. Three matter most.

- **The overselling was built in.** Nothing stopped two orders taking the same
  unit, and stock only came off the shelf when an order shipped. Fourteen
  products already show stock below zero.
- **Order status is typed freely** ("Completed", "complete", " completed"), so a
  report asking for "completed" finds only one completed order in five.
- **116 everyday products may be wrongly priced.** Cooking oil, children's
  clothes and a phone cable cost GHS 16,000–22,000, 50 to 235 times similar
  items. They carry 44% of the sales Adwoa's report counts, and every customer
  in her top 100 bought one.

You were told triggers might stop the overselling. I tested that: on their own
they sold **400 units of a 50-unit stock**, and with a safety rule added they
showed 350 customers an error instead of "out of stock".

I deleted nothing: every record I removed or changed is kept, with the reason,
for your auditor.

## What I built

| What you asked for | Status | Evidence |
|---|---|---|
| No overselling | Done | 400 buyers at once for 50 units, tested again and again: exactly 50 sold every time, no errors. A refused buyer is told in a fraction of a millisecond. |
| A fast Monday report | Done | Every customer in about 2 seconds on a laptop, against about 3 hours for the old method on the same data. No bigger server needed. |
| Low stock at a glance | Done | The whole category tree, any number of levels, in a few thousandths of a second; under a third of a second at 50 times today's size. |
| Proof of what happened | Done | Every stock movement is tied to its order and cannot be edited; any deletion is itself recorded. |
| Extra: cancellations | Done | A cancelled order puts its stock back exactly once, even in a flash sale. |

## What I recommend

1. **Check the 116 prices against your price list** before using Adwoa's
   ranking or revenue totals for decisions.
2. **Count 640 shelves first.** Their stock disagreed with their own history,
   and I had to choose one figure; the list is ready.
3. **Decide on 16,007 "pending" orders (GHS 48.5M).** They are as old as
   completed ones: either paid and never sent, or abandoned.
4. **Give the shop its own limited login** that can add stock records but never
   change them. Today, anyone with full access could switch the protections off.
5. **Before the first flash sale,** have the shop keep a few connections to the
   database open and share them, instead of opening one per shopper.

## What I could not stand behind

- **The 116 prices.** Customers paid them, so the data cannot say whether they
  are mistakes. If they are, your revenue is overstated by up to 44%.
- **Stock for those 640 products until counted:** up to 2,553 units may be wrong.
- **"Low stock" means under two weeks of that product's recent sales.** Two weeks
  is my guess; your suppliers' delivery times should set it.
- **533 customers have two or three accounts.** I flagged them rather than merge
  them, so a few of your best customers rank lower than they should.

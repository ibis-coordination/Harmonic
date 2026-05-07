# Decision & Verification UI Polish

UI improvements and general polish for decision show pages and the verification page.

## Items

### 1. Consistent chainlink icon on show page
The audit chain icon on the decision show page currently changes based on decision state. It should always show the chainlink icon regardless of whether the decision is open, closed, or has a beacon drawn.

### 2. Don't highlight top result row before beacon is drawn
When a decision is closed but the beacon hasn't been fetched yet, the results table highlights the top row as if it's the winner. Since random sorting could change the order when the beacon resolves, the top row shouldn't be highlighted until the beacon is drawn and results are final.

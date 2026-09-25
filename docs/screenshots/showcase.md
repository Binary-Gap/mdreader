# Rate limiter design

A **token bucket** per client, refilled on read instead of on a timer. Cheap to store,
trivial to reason about, and it degrades gracefully when the clock skews. See
[RFC 6585](https://www.rfc-editor.org/rfc/rfc6585) for the `429` semantics.

> Rule of thumb: limit on the *identity* you can trust, never on a header the client controls.

## Implementation

```swift
struct TokenBucket {
    let capacity: Double
    let refillRate: Double
    private(set) var tokens: Double
    private var lastRefill = Date()

    mutating func take(_ cost: Double = 1) -> Bool {
        let elapsed = Date().timeIntervalSince(lastRefill)
        tokens = min(capacity, tokens + elapsed * refillRate)
        lastRefill = Date()
        guard tokens >= cost else { return false }
        tokens -= cost
        return true
    }
}
```

## Limits by plan

| Plan | Burst | Refill / s | Notes |
| --- | ---: | ---: | --- |
| Free | 20 | 1 | per API key |
| Pro | 200 | 10 | per API key |
| Enterprise | 2000 | 100 | per org, negotiable |

## Rollout

- [x] Bucket math + unit tests
- [x] Redis-backed store with `EVALSHA`
- [ ] Shadow mode on 5% of traffic
- [ ] Flip enforcement, watch `429` rate
